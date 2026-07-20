defmodule Sxf.TestFixtures do
  alias Sxf.Identifiers
  alias Sxf.Repo
  alias Sxf.Tasks
  alias Sxf.Tasks.Actor
  alias Sxf.Tasks.Budget
  alias Sxf.Tasks.EvidenceReference
  alias Sxf.Tasks.Project
  alias Sxf.Tasks.RepositoryRegistration
  alias Sxf.Tasks.TaskAttempt
  alias Sxf.Tasks.WorkerLease

  @base_time ~U[2026-07-20 20:00:00.000000Z]

  def base_time, do: @base_time
  def uuid, do: Identifiers.generate()

  def domain_fixture(opts \\ []) do
    project =
      %Project{}
      |> Project.changeset(%{id: uuid(), name: "SXF"})
      |> Repo.insert!()

    repository =
      %RepositoryRegistration{}
      |> RepositoryRegistration.changeset(%{
        id: uuid(),
        project_id: project.id,
        provider: "test-provider",
        external_id: "repo-#{System.unique_integer([:positive])}",
        owner: "example",
        name: "sxf-core",
        clone_url: "https://example.invalid/sxf-core.git"
      })
      |> Repo.insert!()

    system_actor = actor_fixture("system", "control-plane")
    human_actor = actor_fixture("human", "operator")
    worker_actor = actor_fixture("worker", "worker-1")
    task_id = Keyword.get(opts, :task_id, uuid())

    {:ok, %{task: task, event: event}} =
      Tasks.create_task(%{
        id: task_id,
        project_id: project.id,
        repository_registration_id: repository.id,
        title: "Durable task",
        source_ref: "issue:2",
        actor_id: system_actor.id,
        reason: "intake accepted",
        reason_code: "intake",
        occurred_at: @base_time,
        correlation_id: uuid(),
        idempotency_key: "create:#{task_id}"
      })

    %{
      project: project,
      repository: repository,
      system_actor: system_actor,
      human_actor: human_actor,
      worker_actor: worker_actor,
      task: task,
      creation_event: event
    }
  end

  def actor_fixture(kind, external_ref) do
    %Actor{}
    |> Actor.changeset(%{
      id: uuid(),
      kind: kind,
      external_ref: "#{external_ref}-#{System.unique_integer([:positive])}",
      display_name: external_ref
    })
    |> Repo.insert!()
  end

  def attempt_fixture(task, attrs \\ %{}) do
    defaults = %{
      id: uuid(),
      task_id: task.id,
      sequence: 1,
      status: "running",
      backend: "test-backend",
      backend_session_id: "session-1",
      idempotency_key: "attempt:1",
      started_at: @base_time
    }

    %TaskAttempt{}
    |> TaskAttempt.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  def budget_fixture(task, attrs \\ %{}) do
    defaults = %{
      id: uuid(),
      task_id: task.id,
      idempotency_key: "budget:#{System.unique_integer([:positive])}",
      max_cost_microusd: 1_000,
      max_runtime_ms: 60_000,
      max_agent_turns: 10,
      max_repair_cycles: 2,
      max_provider_retries: 3
    }

    %Budget{}
    |> Budget.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  def lease_fixture(task, attempt, attrs \\ %{}) do
    defaults = %{
      id: uuid(),
      task_id: task.id,
      attempt_id: attempt.id,
      worker_id: "worker-a",
      fencing_token: 1,
      status: "active",
      acquired_at: @base_time,
      heartbeat_at: @base_time,
      expires_at: DateTime.add(@base_time, 60, :second),
      idempotency_key: "lease:#{System.unique_integer([:positive])}"
    }

    %WorkerLease{}
    |> WorkerLease.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  def evidence_fixture(task, actor, kind, attrs \\ %{}) do
    defaults = %{
      id: uuid(),
      task_id: task.id,
      producer_actor_id: actor.id,
      kind: kind,
      storage_uri: "sha256://#{String.duplicate("a", 64)}/#{System.unique_integer([:positive])}",
      sha256: String.duplicate("a", 64),
      media_type: "application/json",
      byte_size: 42,
      finalized_at: @base_time
    }

    %EvidenceReference{}
    |> EvidenceReference.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  def decision_fixture(task, actor, kind, attrs \\ %{}) do
    defaults = %{
      id: uuid(),
      task_id: task.id,
      actor_id: actor.id,
      kind: kind,
      decision: "approved",
      reason: "explicit operator decision",
      occurred_at: @base_time,
      correlation_id: uuid(),
      idempotency_key: "decision:#{kind}:#{System.unique_integer([:positive])}"
    }

    {:ok, %{decision: decision}} = Tasks.record_human_decision(Map.merge(defaults, attrs))
    decision
  end

  def transition(task, actor, resulting_state, offset, attrs \\ %{}) do
    command = %{
      actor_id: actor.id,
      resulting_state: resulting_state,
      reason: "move to #{resulting_state}",
      occurred_at: DateTime.add(@base_time, offset, :second),
      correlation_id: uuid(),
      idempotency_key: "transition:#{task.id}:#{resulting_state}:#{offset}"
    }

    Tasks.transition_task(task.id, Map.merge(command, attrs))
  end
end
