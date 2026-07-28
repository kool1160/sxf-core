defmodule Sxf.SQLiteGitHubPollerRunner do
  import Sxf.TestFixtures

  alias Sxf.GitHub.IssuePoller
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

  @now ~U[2026-07-28 17:00:00.000000Z]
  @repository_id 2_001_002_003
  @installation_id 3_001_002
  @token "isolated-installation-token"

  def run!(database) do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})

    pem =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:RSAPrivateKey, private_key)
      ])

    {:ok, first_repo} = start_isolated_repo(database)
    Process.unlink(first_repo)

    try do
      migrate!(first_repo)

      first =
        with_dynamic_repo(first_repo, fn ->
          fixture = create_registration!()
          {:ok, summary} = IssuePoller.poll_once(poll_opts(fixture, pem))

          assert_equal!(summary.tasks_created, 1, "first tasks created")
          assert_equal!(summary.observations_replayed, 0, "first replay count")

          %{
            actor_id: fixture.actor.id,
            task_id: Repo.one!(Task).id,
            first_task_count: Repo.aggregate(Task, :count),
            first_inbox_count: Repo.aggregate(ExternalEventInboxReference, :count),
            first_transition_count: Repo.aggregate(TransitionEvent, :count)
          }
        end)

      first_stopped? = stop_repo!(first_repo)

      {:ok, restarted_repo} = start_isolated_repo(database)
      Process.unlink(restarted_repo)

      try do
        restart =
          with_dynamic_repo(restarted_repo, fn ->
            actor = Repo.get!(Actor, first.actor_id)
            repository = Repo.get_by!(RepositoryRegistration, external_id: "#{@repository_id}")

            {:ok, summary} =
              IssuePoller.poll_once(poll_opts(%{actor: actor, repository: repository}, pem))

            task = Repo.one!(Task)

            %{
              restart_tasks_created: summary.tasks_created,
              restart_replayed: summary.observations_replayed,
              restart_task_id: task.id,
              restart_task_state: task.state,
              restart_task_count: Repo.aggregate(Task, :count),
              restart_inbox_count: Repo.aggregate(ExternalEventInboxReference, :count),
              restart_transition_count: Repo.aggregate(TransitionEvent, :count),
              attempt_count: Repo.aggregate(TaskAttempt, :count),
              lease_count: Repo.aggregate(WorkerLease, :count),
              retry_count: Repo.aggregate(RetrySchedule, :count),
              blocker_count: Repo.aggregate(Blocker, :count),
              budget_count: Repo.aggregate(Budget, :count),
              usage_count: Repo.aggregate(UsageEntry, :count),
              outbox_count: Repo.aggregate(ExternalActionOutboxReference, :count)
            }
          end)

        result =
          first
          |> Map.merge(restart)
          |> Map.put(:first_repo_stopped?, first_stopped?)
          |> Map.put(:restarted_repo_stopped?, stop_repo!(restarted_repo))

        assert_equal!(result.restart_task_id, result.task_id, "restart task identity")
        Map.drop(result, [:actor_id, :task_id, :restart_task_id])
      after
        if Process.alive?(restarted_repo), do: Supervisor.stop(restarted_repo)
      end
    after
      if Process.alive?(first_repo), do: Supervisor.stop(first_repo)
    end
  end

  defp create_registration! do
    project =
      %Project{}
      |> Project.changeset(%{id: uuid(), name: "SXF M3 Scratch", status: "active"})
      |> Repo.insert!()

    actor =
      %Actor{}
      |> Actor.changeset(%{
        id: uuid(),
        kind: "external_system",
        external_ref: "isolated-github-poller",
        display_name: "isolated-github-poller"
      })
      |> Repo.insert!()

    repository =
      %RepositoryRegistration{}
      |> RepositoryRegistration.registration_changeset(%{
        id: uuid(),
        project_id: project.id,
        provider: "github",
        external_id: "#{@repository_id}",
        owner: "kool1160",
        name: "sxf-m3-scratch",
        clone_url: "https://github.com/kool1160/sxf-m3-scratch.git",
        default_branch: "main",
        manifest_schema_version: "0.1",
        normalized_manifest: %{"schemaVersion" => "0.1"},
        raw_manifest_sha256: String.duplicate("a", 64),
        registration_fingerprint: String.duplicate("b", 64),
        registered_by_actor_id: actor.id,
        registered_at: @now,
        registration_correlation_id: uuid()
      })
      |> Repo.insert!()

    %{actor: actor, repository: repository}
  end

  defp poll_opts(fixture, pem) do
    [
      repository_external_id: fixture.repository.external_id,
      app_id: "123456",
      installation_id: @installation_id,
      actor_id: fixture.actor.id,
      private_key_resolver: fn -> {:ok, pem} end,
      now_fn: fn -> @now end,
      correlation_id_fn: fn -> uuid() end,
      max_pages: 1,
      max_observations: 1,
      transport: &transport/1
    ]
  end

  defp transport(%{method: :post}) do
    {:ok,
     response(201, %{
       "token" => @token,
       "expires_at" => "2026-07-28T17:30:00Z",
       "installation_id" => @installation_id,
       "repository_selection" => "selected",
       "repositories" => [%{"id" => @repository_id}],
       "permissions" => %{
         "metadata" => "read",
         "contents" => "write",
         "issues" => "read",
         "pull_requests" => "write"
       }
     })}
  end

  defp transport(%{path: "/repositories/" <> _id}) do
    {:ok,
     response(200, %{
       "id" => @repository_id,
       "name" => "sxf-m3-scratch",
       "owner" => %{"login" => "kool1160"},
       "archived" => false
     })}
  end

  defp transport(%{path: path}) do
    if String.contains?(path, "/issues?") do
      {:ok,
       response(200, [
         %{
           "id" => 9_001,
           "number" => 42,
           "title" => "Restart durable intake",
           "body" => "Untrusted issue body",
           "state" => "open",
           "updated_at" => "2026-07-28T17:01:00Z",
           "html_url" => "https://github.com/kool1160/sxf-m3-scratch/issues/42",
           "url" => "https://api.github.com/repos/kool1160/sxf-m3-scratch/issues/42",
           "labels" => [%{"name" => "sxf:ready"}],
           "user" => %{"id" => 8_001, "login" => "operator"}
         }
       ])}
    else
      {:error, :unexpected_request}
    end
  end

  defp response(status, body) do
    %{
      status: status,
      headers: %{
        "x-github-request-id" => "ISOLATED-REQUEST",
        "x-ratelimit-limit" => "5000",
        "x-ratelimit-remaining" => "4999",
        "x-ratelimit-reset" => "1785258120"
      },
      body: body
    }
  end

  defp with_dynamic_repo(repo, fun) do
    previous_repo = Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous_repo)
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
