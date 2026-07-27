defmodule Sxf.SQLiteClaimContentionRunner do
  import Ecto.Query
  import Sxf.TestFixtures

  alias Sxf.Execution.Claim
  alias Sxf.Execution.TaskStore.Ecto, as: TaskStore
  alias Sxf.Repo

  alias Sxf.Tasks.{
    Task,
    TaskAttempt,
    TransitionEvent,
    WorkerLease
  }

  @execution_time ~U[2026-07-20 20:00:10.000000Z]

  def run!(database) do
    {:ok, isolated_repo} = start_isolated_repo(database)
    Process.unlink(isolated_repo)

    try do
      migrate!(isolated_repo)
      previous_repo = Repo.put_dynamic_repo(isolated_repo)

      result =
        try do
          exercise_contention!(isolated_repo)
        after
          Repo.put_dynamic_repo(previous_repo)
        end

      Map.put(result, :repo_stopped?, stop_repo!(isolated_repo))
    after
      if Process.alive?(isolated_repo), do: Supervisor.stop(isolated_repo)
    end
  end

  defp exercise_contention!(isolated_repo) do
    fixture = ready_fixture()
    budget_fixture(fixture.task)

    assert_equal!(Repo.query!("PRAGMA journal_mode").rows, [["wal"]], "WAL mode")
    assert_equal!(Repo.query!("PRAGMA foreign_keys").rows, [[1]], "foreign keys")

    parent = self()
    release = make_ref()

    callers =
      for suffix <- ["a", "b"] do
        attrs = claim_attrs(fixture, "independent-#{suffix}")

        Elixir.Task.async(fn ->
          Repo.put_dynamic_repo(isolated_repo)

          try do
            Repo.checkout(fn ->
              send(parent, {:connection_checked_out, self()})

              receive do
                {:release_claim, ^release} -> :ok
              end

              {:returned, TaskStore.claim_next(attrs)}
            end)
          rescue
            error -> {:raised, error, __STACKTRACE__}
          catch
            kind, reason -> {:caught, kind, reason}
          end
        end)
      end

    first_caller = receive_checkout!()
    second_caller = receive_checkout!()
    assert_equal!(first_caller == second_caller, false, "distinct connection callers")

    Enum.each(callers, fn caller ->
      send(caller.pid, {:release_claim, release})
    end)

    results = Enum.map(callers, &Elixir.Task.await(&1, 10_000))

    unless Enum.all?(results, &match?({:returned, _}, &1)) do
      raise "claim caller failed instead of returning safely: #{inspect(results)}"
    end

    returned = Enum.map(results, fn {:returned, result} -> result end)
    claim_count = Enum.count(returned, &match?({:ok, %Claim{}}, &1))
    no_work_count = Enum.count(returned, &match?({:ok, nil}, &1))

    result = %{
      claim_count: claim_count,
      no_work_count: no_work_count,
      running_attempt_count:
        Repo.aggregate(
          from(attempt in TaskAttempt,
            where: attempt.task_id == ^fixture.task.id and attempt.status == "running"
          ),
          :count
        ),
      active_lease_count:
        Repo.aggregate(
          from(lease in WorkerLease,
            where: lease.task_id == ^fixture.task.id and lease.status == "active"
          ),
          :count
        ),
      ready_to_implementing_count:
        Repo.aggregate(
          from(event in TransitionEvent,
            where:
              event.task_id == ^fixture.task.id and event.prior_state == "READY" and
                event.resulting_state == "IMPLEMENTING"
          ),
          :count
        ),
      task_state: Repo.get!(Task, fixture.task.id).state,
      first_attempt_sequence_count:
        Repo.aggregate(
          from(attempt in TaskAttempt,
            where: attempt.task_id == ^fixture.task.id and attempt.sequence == 1
          ),
          :count
        ),
      first_fencing_token_count:
        Repo.aggregate(
          from(lease in WorkerLease,
            where: lease.task_id == ^fixture.task.id and lease.fencing_token == 1
          ),
          :count
        )
    }

    expected = %{
      claim_count: 1,
      no_work_count: 1,
      running_attempt_count: 1,
      active_lease_count: 1,
      ready_to_implementing_count: 1,
      task_state: "IMPLEMENTING",
      first_attempt_sequence_count: 1,
      first_fencing_token_count: 1
    }

    assert_equal!(result, expected, "durable contention result")
    result
  end

  defp receive_checkout! do
    receive do
      {:connection_checked_out, caller} -> caller
    after
      5_000 -> raise "claim caller did not check out an independent SQLite connection"
    end
  end

  defp stop_repo!(isolated_repo) do
    monitor = Process.monitor(isolated_repo)
    :ok = Supervisor.stop(isolated_repo)

    receive do
      {:DOWN, ^monitor, :process, ^isolated_repo, :normal} -> true
    after
      5_000 -> raise "isolated Repo did not stop cleanly"
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

  defp migrate!(isolated_repo) do
    Ecto.Migrator.run(
      Repo,
      Ecto.Migrator.migrations_path(Repo),
      :up,
      all: true,
      dynamic_repo: isolated_repo,
      log: false
    )
  end

  defp ready_fixture do
    fixture = domain_fixture()
    {:ok, %{task: task}} = transition(fixture.task, fixture.system_actor, "SPECIFIED", 1)
    {:ok, %{task: task}} = transition(task, fixture.system_actor, "PLANNED", 2)
    {:ok, %{task: task}} = transition(task, fixture.system_actor, "READY", 3)
    %{fixture | task: task}
  end

  defp claim_attrs(fixture, suffix) do
    %{
      worker_id: "sqlite-contention-#{suffix}",
      actor_id: fixture.system_actor.id,
      backend: "fake",
      occurred_at: @execution_time,
      expires_at: DateTime.add(@execution_time, 60, :second),
      correlation_id: uuid(),
      idempotency_key: "dispatch:sqlite-contention:#{suffix}",
      dispatch_input: %{}
    }
  end

  defp assert_equal!(actual, expected, label) do
    unless actual == expected do
      raise "#{label} mismatch: expected #{inspect(expected)}, got #{inspect(actual)}"
    end
  end
end
