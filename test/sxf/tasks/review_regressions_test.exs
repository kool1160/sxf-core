defmodule Sxf.Tasks.ReviewRegressionsTest do
  use Sxf.DataCase, async: false

  alias Sxf.Repo
  alias Sxf.Tasks
  alias Sxf.Tasks.Blocker
  alias Sxf.Tasks.EvidenceReference
  alias Sxf.Tasks.Task
  alias Sxf.Tasks.TransitionEvent

  test "project/repository and task/attempt ownership is coherent" do
    first = domain_fixture()
    second = domain_fixture()

    assert {:error, :repository_project_mismatch} =
             Tasks.create_task(%{
               id: uuid(),
               project_id: first.project.id,
               repository_registration_id: second.repository.id,
               title: "cross-project task",
               actor_id: first.system_actor.id,
               reason: "must be rejected",
               occurred_at: base_time(),
               correlation_id: uuid(),
               idempotency_key: "cross-project"
             })

    cross_project_changeset =
      Task.create_changeset(%Task{}, %{
        id: uuid(),
        project_id: first.project.id,
        repository_registration_id: second.repository.id,
        title: "bypass command",
        state: "DISCOVERED",
        last_transition_at: base_time(),
        transition_sequence: 1
      })

    assert_raise Ecto.ConstraintError, fn -> Repo.insert(cross_project_changeset) end

    first_task = advance_to_ready(first)
    second_task = advance_to_ready(second)
    foreign_attempt = attempt_fixture(second_task)

    assert {:error, :attempt_task_mismatch} =
             Tasks.schedule_retry(%{
               task_id: first_task.id,
               attempt_id: foreign_attempt.id,
               sequence: 1,
               due_at: DateTime.add(base_time(), 10, :second),
               reason: "wrong owner",
               resume_state: "READY",
               correlation_id: uuid(),
               idempotency_key: "cross-task-retry"
             })

    assert {:error, :attempt_task_mismatch} =
             Tasks.block_task(first_task.id, %{
               actor_id: first.system_actor.id,
               attempt_id: foreign_attempt.id,
               kind: "dependency",
               reason: "wrong owner",
               occurred_at: DateTime.add(base_time(), 5, :second),
               correlation_id: uuid(),
               idempotency_key: "cross-task-block"
             })

    task_budget = budget_fixture(first_task)

    assert {:error, :attempt_task_mismatch} =
             Tasks.record_usage(%{
               budget_id: task_budget.id,
               task_id: first_task.id,
               attempt_id: foreign_attempt.id,
               actor_id: first.system_actor.id,
               metric: "agent_turns",
               quantity: 1,
               occurred_at: DateTime.add(base_time(), 5, :second),
               correlation_id: uuid(),
               idempotency_key: "cross-task-usage"
             })

    evidence_changeset =
      EvidenceReference.changeset(%EvidenceReference{}, %{
        id: uuid(),
        task_id: first_task.id,
        attempt_id: foreign_attempt.id,
        producer_actor_id: first.system_actor.id,
        kind: "check_result",
        storage_uri: "sha256://#{String.duplicate("b", 64)}/cross-task",
        sha256: String.duplicate("b", 64),
        finalized_at: base_time()
      })

    assert_raise Ecto.ConstraintError, fn -> Repo.insert(evidence_changeset) end
  end

  test "a human decision authorizes exactly one identified transition and is durably linked" do
    fixture = domain_fixture()
    {:ok, %{task: specified}} = transition(fixture.task, fixture.system_actor, "SPECIFIED", 1)

    {:ok, %{task: cancelled}} =
      transition(specified, fixture.system_actor, "CANCELLED", 2, %{
        reason_code: "operator_cancel"
      })

    budget_fixture(cancelled)
    event_id = uuid()

    decision =
      decision_fixture(cancelled, fixture.human_actor, "reopen", %{
        target_type: "transition",
        target_id: event_id,
        target_action: "READY"
      })

    assert {:error, :decision_scope_mismatch} =
             transition(cancelled, fixture.human_actor, "READY", 3, %{
               event_id: uuid(),
               human_decision_id: decision.id
             })

    assert {:ok, %{task: reopened, event: event}} =
             transition(cancelled, fixture.human_actor, "READY", 4, %{
               event_id: event_id,
               human_decision_id: decision.id
             })

    assert reopened.state == "READY"
    assert event.human_decision_id == decision.id
    assert Repo.get!(TransitionEvent, event.id).human_decision_id == decision.id

    assert {:error, :decision_scope_mismatch} =
             transition(reopened, fixture.human_actor, "IMPLEMENTING", 5, %{
               event_id: uuid(),
               human_decision_id: decision.id
             })
  end

  test "a blocker decision is scoped to the exact blocker action and persisted on resolution" do
    fixture = domain_fixture()

    {:ok, %{blocker: blocker}} =
      Tasks.block_task(fixture.task.id, %{
        actor_id: fixture.system_actor.id,
        kind: "policy",
        reason: "operator approval required",
        occurred_at: DateTime.add(base_time(), 1, :second),
        correlation_id: uuid(),
        idempotency_key: "policy-block"
      })

    decision =
      decision_fixture(fixture.task, fixture.human_actor, "unblock", %{
        target_type: "blocker_resolution",
        target_id: blocker.id,
        target_action: "resolve:policy"
      })

    wrong_target =
      %Blocker{}
      |> Blocker.changeset(%{
        id: uuid(),
        task_id: fixture.task.id,
        created_by_actor_id: fixture.system_actor.id,
        kind: "operator_input",
        status: "active",
        reason: "different blocker",
        resume_state: "DISCOVERED",
        created_at: DateTime.add(base_time(), 1, :second),
        correlation_id: uuid()
      })
      |> Repo.insert!()

    resolution = %{
      actor_id: fixture.human_actor.id,
      occurred_at: DateTime.add(base_time(), 2, :second),
      correlation_id: uuid(),
      idempotency_key: "resolve-policy",
      human_decision_id: decision.id,
      metadata: %{ticket: "SEC-1"}
    }

    assert {:error, :decision_scope_mismatch} = Tasks.resolve_blocker(wrong_target.id, resolution)
    assert {:ok, %{blocker: resolved}} = Tasks.resolve_blocker(blocker.id, resolution)
    assert resolved.resolution_human_decision_id == decision.id
    assert resolved.resolution_request_fingerprint =~ ~r/\A[0-9a-f]{64}\z/

    assert {:error, :idempotency_conflict} =
             Tasks.resolve_blocker(blocker.id, put_in(resolution, [:metadata, :ticket], "SEC-2"))
  end

  test "all idempotent commands reject replay with changed accepted input" do
    fixture = domain_fixture()

    creation_replay = %{
      id: fixture.task.id,
      project_id: fixture.project.id,
      repository_registration_id: fixture.repository.id,
      title: fixture.task.title,
      source_ref: fixture.task.source_ref,
      actor_id: fixture.system_actor.id,
      reason: fixture.creation_event.reason,
      reason_code: fixture.creation_event.reason_code,
      occurred_at: fixture.creation_event.occurred_at,
      correlation_id: fixture.creation_event.correlation_id,
      idempotency_key: fixture.creation_event.idempotency_key,
      event_id: uuid()
    }

    assert {:error, :idempotency_conflict} = Tasks.create_task(creation_replay)

    transition_command = %{
      actor_id: fixture.system_actor.id,
      resulting_state: "SPECIFIED",
      reason: "specified",
      occurred_at: DateTime.add(base_time(), 1, :second),
      correlation_id: uuid(),
      idempotency_key: "fingerprint-transition",
      metadata: %{source: "first"}
    }

    assert {:ok, %{task: specified}} = Tasks.transition_task(fixture.task.id, transition_command)

    assert {:error, :idempotency_conflict} =
             Tasks.transition_task(
               fixture.task.id,
               put_in(transition_command, [:metadata, :source], "changed")
             )

    block_command = %{
      actor_id: fixture.system_actor.id,
      kind: "dependency",
      reason: "waiting",
      occurred_at: DateTime.add(base_time(), 2, :second),
      correlation_id: uuid(),
      idempotency_key: "fingerprint-block",
      blocker_metadata: %{dependency: "one"}
    }

    assert {:ok, %{blocker: blocker}} = Tasks.block_task(specified.id, block_command)

    assert {:error, :idempotency_conflict} =
             Tasks.block_task(
               specified.id,
               put_in(block_command, [:blocker_metadata, :dependency], "two")
             )

    assert {:ok, %{blocker: _}} =
             Tasks.resolve_blocker(blocker.id, %{
               actor_id: fixture.human_actor.id,
               occurred_at: DateTime.add(base_time(), 3, :second),
               correlation_id: uuid(),
               idempotency_key: "resolve-dependency"
             })

    {:ok, %{task: ready}} =
      transition(blocker_task(blocker), fixture.system_actor, "SPECIFIED", 4)

    {:ok, %{task: planned}} = transition(ready, fixture.system_actor, "PLANNED", 5)
    {:ok, %{task: ready}} = transition(planned, fixture.system_actor, "READY", 6)

    attempt_command = %{
      id: uuid(),
      task_id: ready.id,
      sequence: 1,
      status: "planned",
      idempotency_key: "fingerprint-attempt",
      finished_at: DateTime.add(base_time(), 7, :second),
      outcome: "first",
      metadata: %{input: "one"}
    }

    assert {:ok, %{attempt: attempt}} = Tasks.create_attempt(attempt_command)

    for changed <- [
          %{attempt_command | finished_at: DateTime.add(base_time(), 8, :second)},
          %{attempt_command | outcome: "changed"},
          put_in(attempt_command, [:metadata, :input], "two")
        ] do
      assert {:error, :idempotency_conflict} = Tasks.create_attempt(changed)
    end

    retry_command = %{
      id: uuid(),
      task_id: ready.id,
      attempt_id: attempt.id,
      sequence: 1,
      status: "claimed",
      due_at: DateTime.add(base_time(), 10, :second),
      reason: "provider unavailable",
      resume_state: "READY",
      correlation_id: uuid(),
      idempotency_key: "fingerprint-retry",
      claimed_at: DateTime.add(base_time(), 9, :second),
      finished_at: DateTime.add(base_time(), 11, :second),
      metadata: %{input: "one"}
    }

    assert {:ok, %{retry: _}} = Tasks.schedule_retry(retry_command)

    for changed <- [
          %{retry_command | claimed_at: DateTime.add(base_time(), 8, :second)},
          %{retry_command | finished_at: DateTime.add(base_time(), 12, :second)},
          put_in(retry_command, [:metadata, :input], "two")
        ] do
      assert {:error, :idempotency_conflict} = Tasks.schedule_retry(changed)
    end

    decision_command = %{
      id: uuid(),
      task_id: ready.id,
      actor_id: fixture.human_actor.id,
      kind: "approval",
      decision: "approved",
      reason: "approve exact event",
      occurred_at: DateTime.add(base_time(), 12, :second),
      correlation_id: uuid(),
      idempotency_key: "fingerprint-decision",
      target_type: "transition",
      target_id: uuid(),
      target_action: "APPROVED",
      metadata: %{input: "one"}
    }

    assert {:ok, %{decision: _}} = Tasks.record_human_decision(decision_command)

    assert {:error, :idempotency_conflict} =
             Tasks.record_human_decision(put_in(decision_command, [:metadata, :input], "two"))

    assert {:error, :idempotency_conflict} =
             Tasks.record_human_decision(%{
               decision_command
               | target_id: uuid(),
                 target_action: "CHANGES_REQUESTED"
             })

    budget = budget_fixture(ready, %{attempt_id: attempt.id, max_agent_turns: 10})

    evidence =
      evidence_fixture(ready, fixture.system_actor, "usage_receipt", %{attempt_id: attempt.id})

    usage_command = %{
      id: uuid(),
      budget_id: budget.id,
      task_id: ready.id,
      attempt_id: attempt.id,
      actor_id: fixture.system_actor.id,
      metric: "agent_turns",
      quantity: 1,
      occurred_at: DateTime.add(base_time(), 13, :second),
      correlation_id: uuid(),
      idempotency_key: "fingerprint-usage",
      evidence_reference_ids: [evidence.id],
      metadata: %{input: "one"}
    }

    assert {:ok, %{usage: _}} = Tasks.record_usage(usage_command)

    assert {:error, :idempotency_conflict} =
             Tasks.record_usage(%{usage_command | evidence_reference_ids: []})

    assert {:error, :idempotency_conflict} =
             Tasks.record_usage(put_in(usage_command, [:metadata, :input], "two"))
  end

  test "equal timestamps remain deterministic through a monotonic per-task sequence" do
    fixture = domain_fixture()

    command = fn resulting_state, key ->
      %{
        actor_id: fixture.system_actor.id,
        resulting_state: resulting_state,
        reason: "same observed time",
        occurred_at: base_time(),
        correlation_id: uuid(),
        idempotency_key: key
      }
    end

    assert {:ok, %{task: specified, event: second}} =
             Tasks.transition_task(fixture.task.id, command.("SPECIFIED", "same-time-2"))

    assert {:ok, %{task: planned, event: third}} =
             Tasks.transition_task(specified.id, command.("PLANNED", "same-time-3"))

    assert fixture.creation_event.sequence == 1
    assert second.sequence == 2
    assert third.sequence == 3
    assert planned.transition_sequence == 3
    assert Enum.map(Tasks.task_history(planned.id), & &1.sequence) == [1, 2, 3]
  end

  defp advance_to_ready(fixture) do
    {:ok, %{task: task}} = transition(fixture.task, fixture.system_actor, "SPECIFIED", 1)
    {:ok, %{task: task}} = transition(task, fixture.system_actor, "PLANNED", 2)
    {:ok, %{task: task}} = transition(task, fixture.system_actor, "READY", 3)
    task
  end

  defp blocker_task(blocker), do: Repo.get!(Task, blocker.task_id)
end
