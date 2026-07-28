defmodule Sxf.SQLiteIntakeContentionRunner do
  import Ecto.Query
  import Sxf.TestFixtures

  alias Sxf.Repo
  alias Sxf.Tasks

  alias Sxf.Tasks.{
    ExternalEventInboxReference,
    Project,
    RepositoryRegistration,
    Task,
    TransitionEvent
  }

  @received_at ~U[2026-07-27 16:00:01.000000Z]

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
    fixture = intake_fixture()

    assert_equal!(Repo.query!("PRAGMA journal_mode").rows, [["wal"]], "WAL mode")
    assert_equal!(Repo.query!("PRAGMA foreign_keys").rows, [[1]], "foreign keys")

    parent = self()
    release = make_ref()

    callers =
      for correlation_id <- [uuid(), uuid()] do
        attrs = intake_attrs(fixture, correlation_id)

        Elixir.Task.async(fn ->
          Repo.put_dynamic_repo(isolated_repo)

          try do
            Repo.checkout(fn ->
              send(parent, {:connection_checked_out, self()})

              receive do
                {:release_intake, ^release} -> :ok
              end

              {:returned, Tasks.normalize_external_issue(attrs)}
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
      send(caller.pid, {:release_intake, release})
    end)

    results = Enum.map(callers, &Elixir.Task.await(&1, 10_000))

    unless Enum.all?(results, &match?({:returned, {:ok, _}}, &1)) do
      raise "intake caller failed instead of returning safely: #{inspect(results)}"
    end

    normalized =
      Enum.map(results, fn {:returned, {:ok, result}} -> result end)

    [first, second] = normalized

    assert_equal!(first.inbox.id, second.inbox.id, "inbox identity")
    assert_equal!(first.task.id, second.task.id, "task identity")
    assert_equal!(first.event.id, second.event.id, "event identity")

    result = %{
      created_count: Enum.count(normalized, &(&1.task_created? and not &1.idempotent?)),
      replay_count: Enum.count(normalized, & &1.idempotent?),
      inbox_count:
        Repo.aggregate(
          from(inbox in ExternalEventInboxReference,
            where: inbox.source == "github"
          ),
          :count
        ),
      task_count:
        Repo.aggregate(
          from(task in Task,
            where:
              task.repository_registration_id == ^fixture.repository.id and
                task.source_ref == ^fixture.issue_external_id
          ),
          :count
        ),
      creation_event_count:
        Repo.aggregate(
          from(event in TransitionEvent,
            where:
              event.task_id == ^first.task.id and event.sequence == 1 and
                event.resulting_state == "DISCOVERED"
          ),
          :count
        ),
      task_state: Repo.get!(Task, first.task.id).state,
      task_transition_sequence: Repo.get!(Task, first.task.id).transition_sequence,
      inbox_status: Repo.get!(ExternalEventInboxReference, first.inbox.id).status
    }

    expected = %{
      created_count: 1,
      replay_count: 1,
      inbox_count: 1,
      task_count: 1,
      creation_event_count: 1,
      task_state: "DISCOVERED",
      task_transition_sequence: 1,
      inbox_status: "processed"
    }

    assert_equal!(result, expected, "durable intake contention result")
    result
  end

  defp intake_fixture do
    project =
      %Project{}
      |> Project.changeset(%{id: uuid(), name: "Isolated intake"})
      |> Repo.insert!()

    repository =
      %RepositoryRegistration{}
      |> RepositoryRegistration.changeset(%{
        id: uuid(),
        project_id: project.id,
        provider: "github",
        external_id: "R_isolated",
        owner: "kool1160",
        name: "sxf-m3-scratch",
        clone_url: "https://github.com/kool1160/sxf-m3-scratch.git"
      })
      |> Repo.insert!()

    %{
      project: project,
      repository: repository,
      actor: actor_fixture("external_system", "isolated-github-intake"),
      issue_external_id: "I_isolated_42"
    }
  end

  defp intake_attrs(fixture, correlation_id) do
    %{
      provider: "github",
      repository_external_id: fixture.repository.external_id,
      issue_external_id: fixture.issue_external_id,
      source_version: "2026-07-27T16:00:00Z",
      payload_sha256: String.duplicate("a", 64),
      title: "Concurrent durable intake",
      body: "Untrusted issue body",
      actor_id: fixture.actor.id,
      received_at: @received_at,
      correlation_id: correlation_id,
      metadata: %{"issue_number" => 42}
    }
  end

  defp receive_checkout! do
    receive do
      {:connection_checked_out, caller} -> caller
    after
      5_000 -> raise "intake caller did not check out an independent SQLite connection"
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

  defp assert_equal!(actual, expected, label) do
    unless actual == expected do
      raise "#{label} mismatch: expected #{inspect(expected)}, got #{inspect(actual)}"
    end
  end
end
