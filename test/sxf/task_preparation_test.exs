defmodule Sxf.TaskPreparationTest do
  use Sxf.DataCase, async: false

  alias Sxf.ProjectManifest.Policy
  alias Sxf.ProjectRegistry
  alias Sxf.TaskPreparation
  alias Sxf.Tasks

  alias Sxf.Tasks.{
    Blocker,
    Budget,
    EvidenceReference,
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

  alias Sxf.Tasks.TaskPreparation, as: TaskPreparationRecord

  @intake_time ~U[2026-07-30 12:00:00.000000Z]
  @prepare_time ~U[2026-07-30 12:01:00.000000Z]

  setup do
    system_actor = actor_fixture("system", "task-preparer")
    intake_actor = actor_fixture("external_system", "github-intake")

    %{
      system_actor: system_actor,
      intake_actor: intake_actor
    }
  end

  test "atomically prepares the latest issue through READY without executing commands", fixture do
    sentinel = Path.join(System.tmp_dir!(), "sxf-preparation-#{uuid()}")
    context = prepared_fixture(fixture, install_command: "write-file #{sentinel}")

    assert {:ok, result} = TaskPreparation.prepare(preparation_attrs(context))

    refute result.idempotent?
    assert result.task.state == "READY"
    assert result.task.transition_sequence == 4
    assert Enum.map(result.events, & &1.resulting_state) == ~w(SPECIFIED PLANNED READY)
    assert Enum.map(result.events, & &1.sequence) == [2, 3, 4]

    assert result.preparation.task_id == context.task.id
    assert result.preparation.project_id == context.project.id
    assert result.preparation.repository_registration_id == context.repository.id
    assert result.preparation.source_inbox_id == context.inbox.id

    assert result.preparation.registration_fingerprint ==
             context.repository.registration_fingerprint

    assert result.preparation.source_version == context.inbox.source_version
    assert result.preparation.source_payload_sha256 == context.inbox.payload_sha256
    assert result.preparation.semantic_fingerprint =~ ~r/\A[0-9a-f]{64}\z/

    contract = result.preparation.contract
    assert contract["commands"]["install"] == "write-file #{sentinel}"
    assert contract["commands"]["test"] == "mix test"

    assert contract["commandPlan"] == [
             %{"name" => "install", "command" => "write-file #{sentinel}"},
             %{"name" => "test", "command" => "mix test"}
           ]

    assert contract["task"]["title"] == "Prepare the M3 slice"
    assert contract["task"]["body"] == "Implement only the bounded task."
    assert contract["task"]["source"]["issueExternalId"] == context.task.source_ref
    assert contract["repository"]["registrationId"] == context.repository.id

    assert result.budget.task_id == context.task.id
    assert result.budget.attempt_id == nil
    assert result.budget.max_cost_microusd == 2_000_000
    assert result.budget.max_runtime_ms == 900_000
    assert result.budget.max_agent_turns == 20
    assert result.budget.max_repair_cycles == 0
    assert result.budget.max_provider_retries == 2
    refute File.exists?(sentinel)

    assert Repo.aggregate(TaskPreparationRecord, :count) == 1
    assert Repo.aggregate(Budget, :count) == 1
    assert Repo.aggregate(TransitionEvent, :count) == 4
    assert Repo.aggregate(ExternalEventInboxReference, :count) == 1
    assert_zero_execution_records()

    snapshot = Tasks.restart_snapshot(DateTime.add(@prepare_time, 1, :second))
    assert Enum.map(snapshot.tasks, & &1.id) == [context.task.id]
  end

  test "persists every accepted command in deterministic execution order", fixture do
    context =
      prepared_fixture(fixture,
        command_overrides: %{
          "lint" => "mix format --check-formatted",
          "typecheck" => "mix dialyzer",
          "integrationTest" => "mix test --only integration",
          "build" => "mix compile",
          "start" => "mix run --no-halt"
        }
      )

    assert {:ok, result} = TaskPreparation.prepare(preparation_attrs(context))

    assert result.preparation.contract["commandPlan"] == [
             %{"name" => "install", "command" => "mix deps.get"},
             %{"name" => "lint", "command" => "mix format --check-formatted"},
             %{"name" => "typecheck", "command" => "mix dialyzer"},
             %{"name" => "test", "command" => "mix test"},
             %{"name" => "integrationTest", "command" => "mix test --only integration"},
             %{"name" => "build", "command" => "mix compile"}
           ]
  end

  test "exact semantic replay ignores fresh envelope values and returns durable lookup",
       fixture do
    context = prepared_fixture(fixture)
    attrs = preparation_attrs(context)
    assert {:ok, first} = TaskPreparation.prepare(attrs)

    replay = %{
      attrs
      | prepared_at: DateTime.add(attrs.prepared_at, 60, :second),
        correlation_id: uuid(),
        idempotency_key: "prepare-replay-envelope"
    }

    assert {:ok, second} = TaskPreparation.prepare(replay)
    assert second.idempotent?
    assert second.preparation.id == first.preparation.id
    assert second.budget.id == first.budget.id
    assert second.task.id == first.task.id
    assert Enum.map(second.events, & &1.id) == Enum.map(first.events, & &1.id)
    assert second.preparation.prepared_at == attrs.prepared_at
    assert second.preparation.correlation_id == attrs.correlation_id

    assert {:ok, lookup} = TaskPreparation.lookup(context.task.id)
    assert lookup.idempotent?
    assert lookup.preparation.id == first.preparation.id
    assert lookup.preparation.contract == first.preparation.contract
  end

  test "multiple processed source versions block for operator input before preparation",
       fixture do
    context = prepared_fixture(fixture)

    later_attrs =
      intake_attrs(context, %{
        issue_external_id: context.task.source_ref,
        source_version: "2026-07-30T12:00:30Z",
        payload_sha256: String.duplicate("b", 64),
        title: "Latest issue title",
        body: "Latest issue body",
        received_at: DateTime.add(@intake_time, 30, :second),
        correlation_id: uuid()
      })

    assert {:ok, %{inbox: latest, task: task}} = Tasks.normalize_external_issue(later_attrs)
    assert task.id == context.task.id

    assert {:error, :multiple_processed_source_versions} =
             TaskPreparation.prepare(preparation_attrs(%{context | task: task, inbox: latest}))

    blocked = Repo.get!(Task, task.id)
    assert blocked.state == "BLOCKED"
    assert blocked.resume_state == "DISCOVERED"

    assert %Blocker{
             kind: "operator_input",
             status: "active",
             resume_state: "DISCOVERED",
             metadata: %{
               "preparation_failure" => "multiple_processed_source_versions",
               "source_versions" => source_versions
             }
           } = Repo.get_by!(Blocker, task_id: task.id)

    assert source_versions == [
             "2026-07-30T12:00:00Z",
             "2026-07-30T12:00:30Z"
           ]

    assert Tasks.task_history(task.id) |> Enum.map(&{&1.prior_state, &1.resulting_state}) == [
             {nil, "DISCOVERED"},
             {"DISCOVERED", "BLOCKED"}
           ]

    refute Repo.get_by(TaskPreparationRecord, task_id: task.id)
    refute Repo.get_by(Budget, task_id: task.id)
  end

  test "lower manifest budgets remain exact rather than being raised to M3 ceilings", fixture do
    context =
      prepared_fixture(fixture,
        budget_overrides: %{
          "maxCostUsd" => 1.25,
          "maxRuntimeMinutes" => 10,
          "maxAgentTurns" => 7
        }
      )

    assert {:ok, result} = TaskPreparation.prepare(preparation_attrs(context))
    assert result.budget.max_cost_microusd == 1_250_000
    assert result.budget.max_runtime_ms == 600_000
    assert result.budget.max_agent_turns == 7
    assert result.budget.max_repair_cycles == 0
    assert result.budget.max_provider_retries == 2
  end

  test "a later source version or different preparation actor conflicts after preparation",
       fixture do
    context = prepared_fixture(fixture)
    attrs = preparation_attrs(context)
    assert {:ok, _} = TaskPreparation.prepare(attrs)

    other_actor = actor_fixture("system", "other-preparer")

    assert {:error, :preparation_conflict} =
             TaskPreparation.prepare(%{attrs | actor_id: other_actor.id})

    later_attrs =
      intake_attrs(context, %{
        issue_external_id: context.task.source_ref,
        source_version: "2026-07-30T12:02:00Z",
        payload_sha256: String.duplicate("c", 64),
        body: "Changed after preparation",
        received_at: DateTime.add(@intake_time, 120, :second),
        correlation_id: uuid()
      })

    assert {:ok, _} = Tasks.normalize_external_issue(later_attrs)
    assert {:error, :preparation_conflict} = TaskPreparation.prepare(attrs)

    assert Repo.aggregate(TaskPreparationRecord, :count) == 1
    assert Repo.aggregate(Budget, :count) == 1
    assert Repo.aggregate(TransitionEvent, :count) == 4
  end

  test "invalid manifest authority creates policy blockers without partial promotion",
       fixture do
    missing_autonomy =
      prepared_fixture(fixture,
        external_id: "R_no_branch_#{System.unique_integer([:positive])}",
        manifest_overrides: %{"createBranches" => false}
      )

    assert {:error, :branch_creation_not_authorized} =
             TaskPreparation.prepare(preparation_attrs(missing_autonomy))

    over_budget =
      prepared_fixture(fixture,
        external_id: "R_over_budget_#{System.unique_integer([:positive])}",
        budget_overrides: %{
          "maxCostUsd" => 3,
          "maxRuntimeMinutes" => 16,
          "maxAgentTurns" => 21,
          "maxRepairCycles" => 1
        },
        policy_overrides: [
          max_cost_microusd: 3_000_000,
          max_runtime_minutes: 16,
          max_agent_turns: 21,
          max_repair_cycles: 1
        ]
      )

    assert {:error, :manifest_budget_outside_m3_ceiling} =
             TaskPreparation.prepare(preparation_attrs(over_budget))

    for context <- [missing_autonomy, over_budget] do
      assert Repo.get!(Task, context.task.id).state == "BLOCKED"

      assert Tasks.task_history(context.task.id) |> Enum.map(& &1.resulting_state) ==
               ~w(DISCOVERED BLOCKED)

      refute Repo.get_by(TaskPreparationRecord, task_id: context.task.id)
      refute Repo.get_by(Budget, task_id: context.task.id)

      assert %Blocker{kind: "policy", status: "active"} =
               Repo.get_by!(Blocker, task_id: context.task.id)
    end
  end

  test "M3 rejects merge and production-deployment authority even if registration contains it",
       fixture do
    merge =
      prepared_fixture(fixture,
        external_id: "R_merge_#{System.unique_integer([:positive])}",
        manifest_overrides: %{"mergeToDefault" => true},
        policy_overrides: [
          allowed_autonomy: ["createBranches", "openPullRequests", "mergeToDefault"]
        ]
      )

    assert {:error, :merge_to_default_not_authorized} =
             TaskPreparation.prepare(preparation_attrs(merge))

    production =
      prepared_fixture(fixture,
        external_id: "R_production_#{System.unique_integer([:positive])}"
      )

    repository =
      production.repository
      |> Ecto.Changeset.change(
        normalized_manifest:
          put_in(
            production.repository.normalized_manifest,
            ["autonomy", "deployToProduction"],
            true
          )
      )
      |> Repo.update!()

    production = %{production | repository: repository}

    assert {:error, :production_deployment_not_authorized} =
             TaskPreparation.prepare(preparation_attrs(production))

    for context <- [merge, production] do
      assert Repo.get!(Task, context.task.id).state == "BLOCKED"
      assert %Blocker{kind: "policy"} = Repo.get_by!(Blocker, task_id: context.task.id)
      refute Repo.get_by(TaskPreparationRecord, task_id: context.task.id)
      refute Repo.get_by(Budget, task_id: context.task.id)
    end
  end

  test "missing source, invalid actor, and non-DISCOVERED task roll back completely", fixture do
    context = prepared_fixture(fixture)
    Repo.delete!(context.inbox)

    assert {:error, :source_observation_not_found} =
             TaskPreparation.prepare(preparation_attrs(context))

    context =
      prepared_fixture(fixture, external_id: "R_actor_#{System.unique_integer([:positive])}")

    human = actor_fixture("human", "not-preparer")

    assert {:error, :preparation_actor_required} =
             TaskPreparation.prepare(%{preparation_attrs(context) | actor_id: human.id})

    assert {:ok, %{task: specified}} =
             Tasks.transition_task(context.task.id, %{
               actor_id: fixture.system_actor.id,
               resulting_state: "SPECIFIED",
               reason: "manual preparation is not accepted",
               occurred_at: @prepare_time,
               correlation_id: uuid(),
               idempotency_key: "manual-specified"
             })

    assert specified.state == "SPECIFIED"

    assert {:error, :task_not_discovered} =
             TaskPreparation.prepare(
               preparation_attrs(
                 %{context | task: specified},
                 DateTime.add(@prepare_time, 1, :second)
               )
             )

    assert Repo.aggregate(TaskPreparationRecord, :count) == 0
    assert Repo.aggregate(Budget, :count) == 0
  end

  test "incomplete registration and malformed commands do not create authority", fixture do
    project =
      %Project{}
      |> Project.changeset(%{id: uuid(), name: "Incomplete registration"})
      |> Repo.insert!()

    repository =
      %RepositoryRegistration{}
      |> RepositoryRegistration.changeset(%{
        id: uuid(),
        project_id: project.id,
        provider: "github",
        external_id: "R_incomplete_#{System.unique_integer([:positive])}",
        owner: "kool1160",
        name: "sxf-m3-scratch",
        clone_url: "https://github.com/kool1160/sxf-m3-scratch.git"
      })
      |> Repo.insert!()

    attrs = intake_attrs(fixture, %{repository_external_id: repository.external_id})
    assert {:ok, %{task: task}} = Tasks.normalize_external_issue(attrs)

    context = %{task: task, system_actor: fixture.system_actor}

    assert {:error, :registration_incomplete} =
             TaskPreparation.prepare(preparation_attrs(context))

    assert Repo.get!(Task, task.id).state == "BLOCKED"
    assert %Blocker{kind: "policy"} = Repo.get_by!(Blocker, task_id: task.id)
    assert Repo.aggregate(TaskPreparationRecord, :count) == 0
    assert Repo.aggregate(Budget, :count) == 0
  end

  test "invalid commands are rejected before touching durable task state", fixture do
    context = prepared_fixture(fixture)

    invalid = [
      Map.delete(preparation_attrs(context), :task_id),
      %{preparation_attrs(context) | task_id: "not-a-uuid"},
      %{preparation_attrs(context) | correlation_id: "not-a-uuid"},
      %{preparation_attrs(context) | idempotency_key: ""}
    ]

    for command <- invalid do
      assert {:error, _reason} = TaskPreparation.prepare(command)
    end

    assert Repo.get!(Task, context.task.id).state == "DISCOVERED"
    assert Repo.aggregate(TaskPreparationRecord, :count) == 0
    assert Repo.aggregate(Budget, :count) == 0
  end

  test "database constraints reject cross-task source ownership", fixture do
    first = prepared_fixture(fixture)

    second =
      prepared_fixture(fixture,
        external_id: "R_other_source_#{System.unique_integer([:positive])}"
      )

    attrs = %{
      id: uuid(),
      project_id: first.project.id,
      task_id: first.task.id,
      repository_registration_id: first.repository.id,
      source_inbox_id: second.inbox.id,
      prepared_by_actor_id: fixture.system_actor.id,
      manifest_schema_version: "0.1",
      registration_fingerprint: first.repository.registration_fingerprint,
      source_version: second.inbox.source_version,
      source_payload_sha256: second.inbox.payload_sha256,
      contract: %{"version" => "0.1"},
      semantic_fingerprint: String.duplicate("d", 64),
      prepared_at: @prepare_time,
      correlation_id: uuid(),
      idempotency_key: "invalid-cross-task-source"
    }

    assert_raise Ecto.ConstraintError, fn ->
      %TaskPreparationRecord{}
      |> TaskPreparationRecord.changeset(attrs)
      |> Repo.insert()
    end

    assert Repo.aggregate(TaskPreparationRecord, :count) == 0
  end

  defp prepared_fixture(fixture, opts \\ []) do
    external_id =
      Keyword.get(opts, :external_id, "R_prepare_#{System.unique_integer([:positive])}")

    manifest =
      manifest_map(
        Keyword.get(opts, :install_command, "mix deps.get"),
        Keyword.get(opts, :command_overrides, %{}),
        Keyword.get(opts, :manifest_overrides, %{}),
        Keyword.get(opts, :budget_overrides, %{})
      )

    policy_options =
      [
        allowed_autonomy: ["createBranches", "openPullRequests"],
        allowed_network_domains: ["github.com"],
        max_cost_microusd: 2_000_000,
        max_runtime_minutes: 15,
        max_agent_turns: 20,
        max_repair_cycles: 0
      ]
      |> Keyword.merge(Keyword.get(opts, :policy_overrides, []))

    assert {:ok, registration} =
             ProjectRegistry.register_repository(%{
               provider: "github",
               external_id: external_id,
               owner: "kool1160",
               name: "sxf-m3-scratch",
               clone_url: "https://github.com/kool1160/sxf-m3-scratch.git",
               default_branch: "main",
               manifest_content: Jason.encode!(manifest),
               manifest_format: :json,
               platform_policy: Policy.new(policy_options),
               actor_id: fixture.system_actor.id,
               registered_at: DateTime.add(@intake_time, -60, :second),
               correlation_id: uuid()
             })

    intake_context = Map.merge(fixture, %{repository: registration.repository})
    assert {:ok, intake} = Tasks.normalize_external_issue(intake_attrs(intake_context))

    Map.merge(fixture, %{
      project: registration.project,
      repository: registration.repository,
      task: intake.task,
      inbox: intake.inbox
    })
  end

  defp manifest_map(install_command, command_overrides, autonomy_overrides, budget_overrides) do
    %{
      "schemaVersion" => "0.1",
      "project" => %{
        "name" => "SXF M3 Scratch",
        "description" => "Synthetic M3 repository",
        "status" => "existing"
      },
      "commands" =>
        Map.merge(
          %{
            "install" => install_command,
            "test" => "mix test"
          },
          command_overrides
        ),
      "autonomy" =>
        Map.merge(
          %{
            "createBranches" => true,
            "openPullRequests" => true,
            "mergeToDefault" => false,
            "deployToProduction" => false
          },
          autonomy_overrides
        ),
      "verification" => %{
        "independent" => true,
        "requireDeterministicChecks" => true
      },
      "budgets" =>
        Map.merge(
          %{
            "maxCostUsd" => 2,
            "maxRuntimeMinutes" => 15,
            "maxAgentTurns" => 20,
            "maxRepairCycles" => 0
          },
          budget_overrides
        ),
      "restrictions" => %{
        "allowedNetworkDomains" => ["github.com"]
      }
    }
  end

  defp intake_attrs(context, overrides \\ %{}) do
    repository_external_id =
      (context[:repository] && context.repository.external_id) ||
        Map.fetch!(overrides, :repository_external_id)

    defaults = %{
      provider: "github",
      repository_external_id: repository_external_id,
      issue_external_id: "I_prepare_#{System.unique_integer([:positive])}",
      source_version: "2026-07-30T12:00:00Z",
      payload_sha256: String.duplicate("a", 64),
      title: "Prepare the M3 slice",
      body: "Implement only the bounded task.",
      actor_id: context.intake_actor.id,
      received_at: @intake_time,
      correlation_id: uuid(),
      metadata: %{"issue_number" => 31, "labels" => ["sxf:ready"]}
    }

    Map.merge(defaults, overrides)
  end

  defp preparation_attrs(context, prepared_at \\ @prepare_time) do
    %{
      task_id: context.task.id,
      actor_id: context.system_actor.id,
      prepared_at: prepared_at,
      correlation_id: uuid(),
      idempotency_key: "prepare-task"
    }
  end

  defp assert_zero_execution_records do
    assert Repo.aggregate(TaskAttempt, :count) == 0
    assert Repo.aggregate(WorkerLease, :count) == 0
    assert Repo.aggregate(RetrySchedule, :count) == 0
    assert Repo.aggregate(Blocker, :count) == 0
    assert Repo.aggregate(UsageEntry, :count) == 0
    assert Repo.aggregate(EvidenceReference, :count) == 0
    assert Repo.aggregate(ExternalActionOutboxReference, :count) == 0
  end
end
