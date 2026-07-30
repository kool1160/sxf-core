defmodule Sxf.SQLiteTaskPreparationRunner do
  import Ecto.Query
  import Sxf.TestFixtures

  alias Sxf.ProjectManifest.Policy
  alias Sxf.ProjectRegistry
  alias Sxf.Repo
  alias Sxf.TaskPreparation
  alias Sxf.Tasks

  alias Sxf.Tasks.{
    Actor,
    Blocker,
    Budget,
    EvidenceReference,
    ExternalActionOutboxReference,
    RetrySchedule,
    Task,
    TaskAttempt,
    TransitionEvent,
    UsageEntry,
    WorkerLease
  }

  alias Sxf.Tasks.TaskPreparation, as: TaskPreparationRecord

  @base_time ~U[2026-07-30 13:00:00.000000Z]

  def run!(database) do
    {:ok, first_repo} = start_isolated_repo(database)
    Process.unlink(first_repo)

    try do
      migrate!(first_repo)

      contention =
        with_dynamic_repo(first_repo, fn ->
          setup_and_contend!(first_repo, database)
        end)

      first_stopped? = stop_repo!(first_repo)
      {:ok, restarted_repo} = start_isolated_repo(database)
      Process.unlink(restarted_repo)

      try do
        restart =
          with_dynamic_repo(restarted_repo, fn ->
            {:ok, lookup} = TaskPreparation.lookup(contention.task_id)

            %{
              restart_lookup?: lookup.preparation.id == contention.preparation_id,
              restart_task_state: lookup.task.state,
              restart_budget_id: lookup.budget.id,
              restart_transition_count:
                Repo.aggregate(
                  from(event in TransitionEvent, where: event.task_id == ^contention.task_id),
                  :count
                )
            }
          end)

        contention
        |> Map.merge(restart)
        |> Map.put(:first_repo_stopped?, first_stopped?)
        |> Map.put(:restarted_repo_stopped?, stop_repo!(restarted_repo))
        |> Map.drop([:task_id, :preparation_id])
      after
        if Process.alive?(restarted_repo), do: Supervisor.stop(restarted_repo)
      end
    after
      if Process.alive?(first_repo), do: Supervisor.stop(first_repo)
    end
  end

  defp setup_and_contend!(isolated_repo, database) do
    system_actor = insert_actor!("system", "isolated-preparer")
    intake_actor = insert_actor!("external_system", "isolated-intake")

    {:ok, registration} =
      ProjectRegistry.register_repository(%{
        provider: "github",
        external_id: "R_isolated_preparation",
        owner: "kool1160",
        name: "sxf-m3-scratch",
        clone_url: "https://github.com/kool1160/sxf-m3-scratch.git",
        default_branch: "main",
        manifest_content: manifest(),
        manifest_format: :yaml,
        platform_policy:
          Policy.new(
            allowed_autonomy: ["createBranches", "openPullRequests"],
            allowed_network_domains: ["github.com"],
            max_cost_microusd: 2_000_000,
            max_runtime_minutes: 15,
            max_agent_turns: 20,
            max_repair_cycles: 0
          ),
        actor_id: system_actor.id,
        registered_at: DateTime.add(@base_time, -60, :second),
        correlation_id: uuid()
      })

    {:ok, intake} =
      Tasks.normalize_external_issue(%{
        provider: "github",
        repository_external_id: registration.repository.external_id,
        issue_external_id: "I_isolated_preparation",
        source_version: "2026-07-30T13:00:00Z",
        payload_sha256: String.duplicate("a", 64),
        title: "Isolated preparation",
        body: "Prepare exactly once.",
        actor_id: intake_actor.id,
        received_at: @base_time,
        correlation_id: uuid(),
        metadata: %{"issue_number" => 31}
      })

    assert_equal!(Repo.query!("PRAGMA journal_mode").rows, [["wal"]], "WAL mode")
    assert_equal!(Repo.query!("PRAGMA foreign_keys").rows, [[1]], "foreign keys")

    parent = self()
    release = make_ref()

    {:ok, second_repo} = start_isolated_repo(database, 1)
    Process.unlink(second_repo)

    results =
      try do
        callers =
          [isolated_repo, second_repo]
          |> Enum.with_index(1)
          |> Enum.map(fn {repo, offset} ->
            Elixir.Task.async(fn ->
              Repo.put_dynamic_repo(repo)
              send(parent, {:caller_ready, self(), repo})

              receive do
                {:release_preparation, ^release} -> :ok
              end

              try do
                {:returned,
                 TaskPreparation.prepare(%{
                   task_id: intake.task.id,
                   actor_id: system_actor.id,
                   prepared_at: DateTime.add(@base_time, offset, :second),
                   correlation_id: uuid(),
                   idempotency_key: "isolated-prepare-#{offset}"
                 })}
              rescue
                error -> {:raised, error, __STACKTRACE__}
              catch
                kind, reason -> {:caught, kind, reason}
              end
            end)
          end)

        ready = [receive_ready!(), receive_ready!()]

        assert_equal!(
          Enum.uniq(Enum.map(ready, &elem(&1, 1))) |> length(),
          2,
          "independent repos"
        )

        Enum.each(callers, fn caller -> send(caller.pid, {:release_preparation, release}) end)
        Enum.map(callers, &Elixir.Task.await(&1, 10_000))
      after
        if Process.alive?(second_repo), do: Supervisor.stop(second_repo)
      end

    unless Enum.all?(results, &match?({:returned, {:ok, _}}, &1)) do
      raise "preparation caller failed instead of returning safely: #{inspect(results)}"
    end

    prepared = Enum.map(results, fn {:returned, {:ok, result}} -> result end)
    [first, second] = prepared
    assert_equal!(first.preparation.id, second.preparation.id, "preparation identity")
    assert_equal!(first.budget.id, second.budget.id, "budget identity")

    result = %{
      task_id: intake.task.id,
      preparation_id: first.preparation.id,
      budget_id: first.budget.id,
      created_count: Enum.count(prepared, &(not &1.idempotent?)),
      replay_count: Enum.count(prepared, & &1.idempotent?),
      preparation_count: Repo.aggregate(TaskPreparationRecord, :count),
      budget_count: Repo.aggregate(Budget, :count),
      transition_count:
        Repo.aggregate(
          from(event in TransitionEvent, where: event.task_id == ^intake.task.id),
          :count
        ),
      task_state: Repo.get!(Task, intake.task.id).state,
      attempt_count: Repo.aggregate(TaskAttempt, :count),
      lease_count: Repo.aggregate(WorkerLease, :count),
      retry_count: Repo.aggregate(RetrySchedule, :count),
      blocker_count: Repo.aggregate(Blocker, :count),
      usage_count: Repo.aggregate(UsageEntry, :count),
      evidence_count: Repo.aggregate(EvidenceReference, :count),
      outbox_count: Repo.aggregate(ExternalActionOutboxReference, :count),
      contention_repo_stopped?: not Process.alive?(second_repo)
    }

    assert_equal!(result.created_count, 1, "created preparation count")
    assert_equal!(result.replay_count, 1, "replayed preparation count")
    assert_equal!(result.preparation_count, 1, "durable preparation count")
    assert_equal!(result.budget_count, 1, "durable budget count")
    assert_equal!(result.transition_count, 4, "durable transition count")
    assert_equal!(result.task_state, "READY", "task state")
    assert_equal!(result.attempt_count, 0, "attempt count")
    assert_equal!(result.lease_count, 0, "lease count")
    assert_equal!(result.retry_count, 0, "retry count")
    assert_equal!(result.blocker_count, 0, "blocker count")
    assert_equal!(result.usage_count, 0, "usage count")
    assert_equal!(result.evidence_count, 0, "evidence count")
    assert_equal!(result.outbox_count, 0, "outbox count")
    result
  end

  defp manifest do
    """
    schemaVersion: "0.1"
    project:
      name: SXF M3 Scratch
      description: Synthetic repository for M3.
      status: existing
    commands:
      install: mix deps.get
      test: mix test
    autonomy:
      createBranches: true
      openPullRequests: true
      mergeToDefault: false
      deployToProduction: false
    verification:
      independent: true
      requireDeterministicChecks: true
    budgets:
      maxCostUsd: 2
      maxRuntimeMinutes: 15
      maxAgentTurns: 20
      maxRepairCycles: 0
    restrictions:
      allowedNetworkDomains:
        - github.com
    """
  end

  defp insert_actor!(kind, external_ref) do
    %Actor{}
    |> Actor.changeset(%{
      id: uuid(),
      kind: kind,
      external_ref: external_ref,
      display_name: external_ref
    })
    |> Repo.insert!()
  end

  defp with_dynamic_repo(repo, fun) do
    previous_repo = Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous_repo)
    end
  end

  defp receive_ready! do
    receive do
      {:caller_ready, caller, repo} -> {caller, repo}
    after
      5_000 -> raise "preparation caller did not reach the synchronization barrier"
    end
  end

  defp stop_repo!(repo) do
    monitor = Process.monitor(repo)
    :ok = Supervisor.stop(repo)

    receive do
      {:DOWN, ^monitor, :process, ^repo, :normal} -> true
    after
      5_000 -> raise "isolated Repo did not stop cleanly"
    end
  end

  defp start_isolated_repo(database, pool_size \\ 2) do
    config =
      :sxf_core
      |> Application.fetch_env!(Repo)
      |> Keyword.merge(
        name: nil,
        database: database,
        pool: DBConnection.ConnectionPool,
        pool_size: pool_size
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

  defp assert_equal!(actual, expected, label) do
    unless actual == expected do
      raise "#{label} mismatch: expected #{inspect(expected)}, got #{inspect(actual)}"
    end
  end
end
