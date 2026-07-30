defmodule Sxf.TestFixtures do
  alias Sxf.Identifiers
  alias Sxf.Repo
  alias Sxf.Tasks
  alias Sxf.Tasks.Actor
  alias Sxf.Tasks.Budget
  alias Sxf.Tasks.Project
  alias Sxf.Tasks.RepositoryRegistration
  alias Sxf.Tasks.TaskPreparation
  alias Sxf.Tasks.TaskAttempt
  alias Sxf.Tasks.TransitionEvent
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
      request_fingerprint: String.duplicate("f", 64),
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

    case Repo.get_by(TaskPreparation, task_id: task.id) do
      nil ->
        %Budget{}
        |> Budget.changeset(Map.merge(defaults, attrs))
        |> Repo.insert!()

      preparation ->
        budget =
          Repo.get_by!(Budget,
            task_id: task.id,
            idempotency_key: "preparation:#{preparation.id}:budget"
          )

        updates =
          defaults
          |> Map.drop([:id, :task_id, :idempotency_key])
          |> Map.merge(attrs)

        budget =
          budget
          |> Budget.changeset(updates)
          |> Repo.update!()

        contract =
          put_in(preparation.contract, ["budgets"], %{
            "maxCostMicrousd" => budget.max_cost_microusd,
            "maxRuntimeMs" => budget.max_runtime_ms,
            "maxAgentTurns" => budget.max_agent_turns,
            "maxRepairCycles" => budget.max_repair_cycles,
            "maxProviderRetries" => budget.max_provider_retries
          })

        semantic_fingerprint = preparation_semantic_fingerprint(preparation, contract)

        preparation
        |> Ecto.Changeset.change(
          contract: contract,
          semantic_fingerprint: semantic_fingerprint
        )
        |> Repo.update!()

        for state <- ~w(specified planned ready) do
          event =
            Repo.get_by!(TransitionEvent,
              task_id: task.id,
              idempotency_key: "preparation:#{preparation.id}:#{state}"
            )

          event
          |> Ecto.Changeset.change(
            metadata: Map.put(event.metadata, "semantic_fingerprint", semantic_fingerprint)
          )
          |> Repo.update!()
        end

        budget
    end
  end

  def preparation_semantic_fingerprint(preparation, contract) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        %{
          command: :prepare_task,
          task_id: preparation.task_id,
          project_id: preparation.project_id,
          repository_registration_id: preparation.repository_registration_id,
          registration_fingerprint: preparation.registration_fingerprint,
          source_inbox_id: preparation.source_inbox_id,
          source_version: preparation.source_version,
          source_payload_sha256: preparation.source_payload_sha256,
          actor_id: preparation.prepared_by_actor_id,
          contract: contract
        },
        [:deterministic]
      )
    )
    |> Base.encode16(case: :lower)
  end

  def execution_preparation_fixture(fixture) do
    registration_fingerprint =
      :crypto.hash(:sha256, "execution-registration:#{fixture.repository.id}")
      |> Base.encode16(case: :lower)

    manifest = %{
      "schemaVersion" => "0.1",
      "commands" => %{"install" => "fixture install", "test" => "fixture test"},
      "autonomy" => %{
        "createBranches" => true,
        "openPullRequests" => true,
        "mergeToDefault" => false,
        "deployToProduction" => false
      },
      "verification" => %{
        "independent" => true,
        "requireDeterministicChecks" => true
      },
      "budgets" => %{
        "maxCostMicrousd" => 2_000_000,
        "maxRuntimeMinutes" => 15,
        "maxAgentTurns" => 20,
        "maxRepairCycles" => 0
      },
      "restrictions" => %{"allowedNetworkDomains" => []}
    }

    repository =
      fixture.repository
      |> RepositoryRegistration.registration_changeset(%{
        manifest_schema_version: "0.1",
        normalized_manifest: manifest,
        raw_manifest_sha256: String.duplicate("a", 64),
        registration_fingerprint: registration_fingerprint,
        registered_by_actor_id: fixture.system_actor.id,
        registered_at: DateTime.add(@base_time, -1, :second),
        registration_correlation_id: uuid()
      })
      |> Repo.update!()

    {:ok, intake} =
      Tasks.normalize_external_issue(%{
        provider: repository.provider,
        repository_external_id: repository.external_id,
        issue_external_id: fixture.task.source_ref,
        source_version: DateTime.to_iso8601(@base_time),
        payload_sha256: String.duplicate("b", 64),
        title: fixture.task.title,
        body: "Execution fixture request",
        actor_id: fixture.system_actor.id,
        received_at: @base_time,
        correlation_id: uuid(),
        metadata: %{}
      })

    {:ok, prepared} =
      Sxf.TaskPreparation.prepare(%{
        task_id: fixture.task.id,
        actor_id: fixture.system_actor.id,
        prepared_at: DateTime.add(@base_time, 1, :second),
        correlation_id: uuid(),
        idempotency_key: "fixture-preparation:#{fixture.task.id}"
      })

    Map.merge(fixture, %{
      repository: repository,
      task: prepared.task,
      inbox: intake.inbox,
      preparation: prepared.preparation,
      preparation_budget: prepared.budget
    })
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
      media_type: "application/json",
      finalized_at: @base_time,
      correlation_id: uuid(),
      idempotency_key: "evidence:#{System.unique_integer([:positive])}",
      redacted: true
    }

    evidence_attrs = Map.merge(defaults, attrs)
    bytes = Map.get(evidence_attrs, :bytes, Jason.encode!(%{kind: kind, task_id: task.id}))

    {:ok, %{reference: reference}} =
      evidence_attrs
      |> Map.delete(:bytes)
      |> Sxf.Evidence.put(bytes)

    reference
  end

  def decision_fixture(task, actor, kind, attrs \\ %{}) do
    target_action =
      case kind do
        "deploy_approval" -> "DEPLOYED"
        "reopen" -> "READY"
        "cancel" -> "CANCELLED"
        _ -> "APPROVED"
      end

    defaults = %{
      id: uuid(),
      task_id: task.id,
      actor_id: actor.id,
      kind: kind,
      decision: "approved",
      reason: "explicit operator decision",
      occurred_at: @base_time,
      correlation_id: uuid(),
      idempotency_key: "decision:#{kind}:#{System.unique_integer([:positive])}",
      target_type: "transition",
      target_id: uuid(),
      target_action: target_action
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
