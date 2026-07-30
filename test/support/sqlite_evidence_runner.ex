defmodule Sxf.SQLiteEvidenceRunner do
  import Sxf.TestFixtures

  alias Sxf.Evidence
  alias Sxf.Repo
  alias Sxf.Tasks.EvidenceReference

  def run!(database, evidence_root) do
    Application.put_env(:sxf_core, :evidence_store,
      root: evidence_root,
      max_bytes: 1024 * 1024
    )

    {:ok, first_repo} = start_isolated_repo(database)
    Process.unlink(first_repo)

    try do
      migrate!(first_repo)

      durable =
        with_dynamic_repo(first_repo, fn ->
          fixture = domain_fixture()
          bytes = "restart-durable evidence"

          attrs = %{
            task_id: fixture.task.id,
            producer_actor_id: fixture.system_actor.id,
            kind: "command_output",
            media_type: "text/plain",
            finalized_at: DateTime.add(base_time(), 1, :second),
            correlation_id: uuid(),
            idempotency_key: "restart-durable",
            redacted: true
          }

          results = concurrent_puts!(first_repo, attrs, bytes)
          references = Enum.map(results, fn {:ok, result} -> result.reference end)
          [reference | _] = references

          %{
            evidence_id: reference.id,
            bytes: bytes,
            sha256: reference.sha256,
            reference_count: Repo.aggregate(EvidenceReference, :count),
            created_count: Enum.count(results, fn {:ok, result} -> not result.idempotent? end),
            replay_count: Enum.count(results, fn {:ok, result} -> result.idempotent? end),
            one_reference_identity?: Enum.uniq_by(references, & &1.id) |> length() == 1
          }
        end)

      first_stopped? = stop_repo!(first_repo)
      {:ok, restarted_repo} = start_isolated_repo(database)
      Process.unlink(restarted_repo)

      try do
        restart =
          with_dynamic_repo(restarted_repo, fn ->
            {:ok, %{reference: reference, bytes: bytes, verification: verification}} =
              Evidence.get(durable.evidence_id)

            %{
              restart_reference_count: Repo.aggregate(EvidenceReference, :count),
              restart_bytes_equal?: bytes == durable.bytes,
              restart_sha_equal?: reference.sha256 == durable.sha256,
              restart_verified?: verification.status == :verified
            }
          end)

        durable
        |> Map.drop([:bytes, :sha256, :evidence_id])
        |> Map.merge(restart)
        |> Map.put(:first_repo_stopped?, first_stopped?)
        |> Map.put(:restarted_repo_stopped?, stop_repo!(restarted_repo))
      after
        if Process.alive?(restarted_repo), do: Supervisor.stop(restarted_repo)
      end
    after
      if Process.alive?(first_repo), do: Supervisor.stop(first_repo)
    end
  end

  defp with_dynamic_repo(repo, fun) do
    previous = Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp concurrent_puts!(repo, attrs, bytes) do
    parent = self()
    release = make_ref()

    callers =
      for _ <- 1..2 do
        Elixir.Task.async(fn ->
          Repo.put_dynamic_repo(repo)

          Repo.checkout(fn ->
            send(parent, {:connection_checked_out, self()})

            receive do
              {:release_put, ^release} -> :ok
            end

            Evidence.put(attrs, bytes)
          end)
        end)
      end

    first = receive_checkout!()
    second = receive_checkout!()

    if first == second do
      raise "evidence contention did not use distinct connection callers"
    end

    Enum.each(callers, &send(&1.pid, {:release_put, release}))
    results = Enum.map(callers, &Elixir.Task.await(&1, 10_000))

    unless Enum.all?(results, &match?({:ok, %{reference: %EvidenceReference{}}}, &1)) do
      raise "evidence contention failed instead of replaying safely: #{inspect(results)}"
    end

    results
  end

  defp receive_checkout! do
    receive do
      {:connection_checked_out, caller} -> caller
    after
      5_000 -> raise "evidence caller did not check out an independent SQLite connection"
    end
  end

  defp start_isolated_repo(database) do
    config =
      :sxf_core
      |> Application.fetch_env!(Repo)
      |> Keyword.merge(
        name: nil,
        database: database,
        pool: DBConnection.ConnectionPool,
        pool_size: 2
      )

    Repo.start_link(config)
  end

  defp migrate!(repo) do
    Ecto.Migrator.run(
      Repo,
      Ecto.Migrator.migrations_path(Repo),
      :up,
      all: true,
      dynamic_repo: repo,
      log: false
    )
  end

  defp stop_repo!(repo) do
    monitor = Process.monitor(repo)
    :ok = Supervisor.stop(repo)

    receive do
      {:DOWN, ^monitor, :process, ^repo, :normal} -> true
    after
      5_000 -> raise "isolated evidence Repo did not stop cleanly"
    end
  end
end
