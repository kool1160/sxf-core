defmodule Sxf.SQLiteProjectRegistryRunner do
  import Sxf.TestFixtures

  alias Sxf.ProjectManifest.Policy
  alias Sxf.ProjectRegistry
  alias Sxf.Repo

  alias Sxf.Tasks.{
    Actor,
    Blocker,
    Budget,
    ExternalActionOutboxReference,
    ExternalEventInboxReference,
    Project,
    RepositoryRegistration,
    RetrySchedule,
    Task,
    TaskAttempt,
    TransitionEvent,
    UsageEntry,
    WorkerLease
  }

  @registered_at ~U[2026-07-28 11:00:00.000000Z]
  @provider "github"
  @external_id "R_isolated_registry"

  def run!(database) do
    {:ok, first_repo} = start_isolated_repo(database)
    Process.unlink(first_repo)

    try do
      migrate!(first_repo)

      contention =
        with_dynamic_repo(first_repo, fn ->
          exercise_contention!(first_repo)
        end)

      first_stopped? = stop_repo!(first_repo)

      {:ok, restarted_repo} = start_isolated_repo(database)
      Process.unlink(restarted_repo)

      try do
        restart =
          with_dynamic_repo(restarted_repo, fn ->
            verify_restart!(contention)
          end)

        contention
        |> Map.merge(restart)
        |> Map.put(:first_repo_stopped?, first_stopped?)
        |> Map.put(:restarted_repo_stopped?, stop_repo!(restarted_repo))
        |> Map.drop([:project_id, :repository_id, :normalized_manifest])
      after
        if Process.alive?(restarted_repo), do: Supervisor.stop(restarted_repo)
      end
    after
      if Process.alive?(first_repo), do: Supervisor.stop(first_repo)
    end
  end

  defp exercise_contention!(isolated_repo) do
    actor =
      %Actor{}
      |> Actor.changeset(%{
        id: uuid(),
        kind: "system",
        external_ref: "isolated-project-registry",
        display_name: "isolated-project-registry"
      })
      |> Repo.insert!()

    assert_equal!(Repo.query!("PRAGMA journal_mode").rows, [["wal"]], "WAL mode")
    assert_equal!(Repo.query!("PRAGMA foreign_keys").rows, [[1]], "foreign keys")

    parent = self()
    release = make_ref()

    callers =
      for offset <- [0, 1] do
        attrs = registration_attrs(actor.id, offset)

        Elixir.Task.async(fn ->
          Repo.put_dynamic_repo(isolated_repo)

          try do
            Repo.checkout(fn ->
              send(parent, {:connection_checked_out, self()})

              receive do
                {:release_registration, ^release} -> :ok
              end

              {:returned, ProjectRegistry.register_repository(attrs)}
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
      send(caller.pid, {:release_registration, release})
    end)

    results = Enum.map(callers, &Elixir.Task.await(&1, 10_000))

    unless Enum.all?(results, &match?({:returned, {:ok, _}}, &1)) do
      raise "registry caller failed instead of returning safely: #{inspect(results)}"
    end

    registrations =
      Enum.map(results, fn {:returned, {:ok, result}} -> result end)

    [first, second] = registrations
    assert_equal!(first.project.id, second.project.id, "project identity")
    assert_equal!(first.repository.id, second.repository.id, "repository identity")
    assert_equal!(first.manifest, second.manifest, "normalized manifest")

    result = %{
      created_count: Enum.count(registrations, &(not &1.idempotent?)),
      replay_count: Enum.count(registrations, & &1.idempotent?),
      project_count: Repo.aggregate(Project, :count),
      repository_count: Repo.aggregate(RepositoryRegistration, :count),
      task_count: Repo.aggregate(Task, :count),
      transition_count: Repo.aggregate(TransitionEvent, :count),
      inbox_count: Repo.aggregate(ExternalEventInboxReference, :count),
      outbox_count: Repo.aggregate(ExternalActionOutboxReference, :count),
      attempt_count: Repo.aggregate(TaskAttempt, :count),
      lease_count: Repo.aggregate(WorkerLease, :count),
      retry_count: Repo.aggregate(RetrySchedule, :count),
      blocker_count: Repo.aggregate(Blocker, :count),
      budget_count: Repo.aggregate(Budget, :count),
      usage_count: Repo.aggregate(UsageEntry, :count),
      project_id: first.project.id,
      repository_id: first.repository.id,
      normalized_manifest: first.manifest
    }

    expected =
      result
      |> Map.merge(%{
        created_count: 1,
        replay_count: 1,
        project_count: 1,
        repository_count: 1,
        task_count: 0,
        transition_count: 0,
        inbox_count: 0,
        outbox_count: 0,
        attempt_count: 0,
        lease_count: 0,
        retry_count: 0,
        blocker_count: 0,
        budget_count: 0,
        usage_count: 0
      })

    assert_equal!(result, expected, "durable registration contention result")
    result
  end

  defp verify_restart!(contention) do
    {:ok, result} = ProjectRegistry.lookup_repository(@provider, @external_id)
    assert_equal!(result.project.id, contention.project_id, "restarted project identity")
    assert_equal!(result.repository.id, contention.repository_id, "restarted repository identity")

    assert_equal!(
      result.manifest,
      contention.normalized_manifest,
      "restarted normalized manifest"
    )

    %{
      restart_lookup?: true,
      restart_project_count: Repo.aggregate(Project, :count),
      restart_repository_count: Repo.aggregate(RepositoryRegistration, :count)
    }
  end

  defp registration_attrs(actor_id, offset) do
    %{
      provider: @provider,
      external_id: @external_id,
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
      actor_id: actor_id,
      registered_at: DateTime.add(@registered_at, offset, :second),
      correlation_id: uuid()
    }
  end

  defp manifest do
    """
    schemaVersion: "0.1"
    project:
      name: SXF M3 Scratch
      description: Synthetic repository for the bounded M3 demonstration.
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

  defp with_dynamic_repo(repo, fun) do
    previous_repo = Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous_repo)
    end
  end

  defp receive_checkout! do
    receive do
      {:connection_checked_out, caller} -> caller
    after
      5_000 -> raise "registry caller did not check out an independent SQLite connection"
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

  defp assert_equal!(actual, expected, label) do
    unless actual == expected do
      raise "#{label} mismatch: expected #{inspect(expected)}, got #{inspect(actual)}"
    end
  end
end
