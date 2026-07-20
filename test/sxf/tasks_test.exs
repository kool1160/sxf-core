defmodule Sxf.TasksTest do
  use Sxf.DataCase, async: false

  alias Sxf.Repo
  alias Sxf.Tasks
  alias Sxf.Tasks.Blocker
  alias Sxf.Tasks.Budget
  alias Sxf.Tasks.EventEvidenceReference
  alias Sxf.Tasks.RetrySchedule
  alias Sxf.Tasks.Task
  alias Sxf.Tasks.TaskAttempt
  alias Sxf.Tasks.TransitionEvent
  alias Sxf.Tasks.UsageEntry
  alias Sxf.Tasks.WorkerLease

  test "task creation is atomic, attributable, stable, and idempotent" do
    fixture = domain_fixture()
    task = fixture.task
    event = fixture.creation_event

    assert event.prior_state == nil
    assert event.resulting_state == "DISCOVERED"
    assert event.actor_id == fixture.system_actor.id
    assert event.reason == "intake accepted"
    assert event.occurred_at == base_time()
    assert task.last_transition_at == event.occurred_at
    assert Sxf.Identifiers.valid?(task.id)
    assert Sxf.Identifiers.valid?(event.id)
    assert Sxf.Identifiers.valid?(event.correlation_id)

    replay = %{
      id: task.id,
      project_id: fixture.project.id,
      repository_registration_id: fixture.repository.id,
      title: task.title,
      source_ref: task.source_ref,
      actor_id: fixture.system_actor.id,
      reason: event.reason,
      reason_code: event.reason_code,
      occurred_at: event.occurred_at,
      correlation_id: event.correlation_id,
      idempotency_key: event.idempotency_key
    }

    assert {:ok, %{idempotent?: true, event: replayed}} = Tasks.create_task(replay)
    assert replayed.id == event.id
    assert Repo.aggregate(TransitionEvent, :count) == 1

    assert {:error, :idempotency_conflict} = Tasks.create_task(%{replay | title: "changed"})
    assert Repo.aggregate(Task, :count) == 1
  end

  test "a valid transition updates projection and history in one transaction" do
    fixture = domain_fixture()

    assert {:ok, %{task: task, event: event, idempotent?: false}} =
             transition(fixture.task, fixture.system_actor, "SPECIFIED", 1)

    assert task.state == "SPECIFIED"
    assert event.prior_state == "DISCOVERED"
    assert event.resulting_state == "SPECIFIED"
    assert Repo.get!(Task, task.id).state == "SPECIFIED"
    assert Repo.aggregate(TransitionEvent, :count) == 2

    command = %{
      actor_id: fixture.system_actor.id,
      resulting_state: "PLANNED",
      reason: "plan accepted",
      occurred_at: DateTime.add(base_time(), 2, :second),
      correlation_id: uuid(),
      idempotency_key: "plan-once"
    }

    assert {:ok, %{event: first, idempotent?: false}} = Tasks.transition_task(task.id, command)
    assert {:ok, %{event: second, idempotent?: true}} = Tasks.transition_task(task.id, command)
    assert first.id == second.id
    assert Repo.aggregate(TransitionEvent, :count) == 3
  end

  test "illegal transitions and missing evidence leave projection and history unchanged" do
    fixture = domain_fixture()
    event_count = Repo.aggregate(TransitionEvent, :count)

    assert {:error, :illegal_transition} =
             transition(fixture.task, fixture.system_actor, "PLANNED", 1)

    assert Repo.get!(Task, fixture.task.id).state == "DISCOVERED"
    assert Repo.aggregate(TransitionEvent, :count) == event_count

    assert {:error, :out_of_order_transition} =
             Tasks.transition_task(fixture.task.id, %{
               actor_id: fixture.system_actor.id,
               resulting_state: "SPECIFIED",
               reason: "stale delivery",
               occurred_at: DateTime.add(base_time(), -1, :second),
               correlation_id: uuid(),
               idempotency_key: "stale:specified"
             })

    task = advance_to_implementing(fixture)
    {:ok, %{task: task}} = transition(task, fixture.system_actor, "CI_RUNNING", 10)
    event_count = Repo.aggregate(TransitionEvent, :count)

    assert {:error, :finalized_check_evidence_required} =
             transition(task, fixture.system_actor, "VERIFYING", 11)

    assert Repo.get!(Task, task.id).state == "CI_RUNNING"
    assert Repo.aggregate(TransitionEvent, :count) == event_count
  end

  test "finalized check and verification evidence is attached to transition events" do
    fixture = domain_fixture()
    task = advance_to_implementing(fixture)
    {:ok, %{task: task}} = transition(task, fixture.system_actor, "CI_RUNNING", 10)

    check = evidence_fixture(task, fixture.worker_actor, "check_result")

    assert {:ok, %{task: task, event: check_event}} =
             transition(task, fixture.system_actor, "VERIFYING", 11, %{
               evidence_reference_ids: [check.id]
             })

    assert Repo.get_by!(EventEvidenceReference,
             transition_event_id: check_event.id,
             evidence_reference_id: check.id
           )

    verification = evidence_fixture(task, fixture.system_actor, "verification_result")

    assert {:ok, %{task: approved}} =
             transition(task, fixture.system_actor, "APPROVED", 12, %{
               evidence_reference_ids: [verification.id]
             })

    assert approved.state == "APPROVED"
  end

  test "execution requires a running attempt, an unexpired lease, and available budget" do
    fixture = domain_fixture()
    task = advance_to_ready(fixture)

    assert {:error, :active_attempt_required} =
             transition(task, fixture.worker_actor, "IMPLEMENTING", 4)

    attempt = attempt_fixture(task)

    assert {:error, :active_lease_required} =
             transition(task, fixture.worker_actor, "IMPLEMENTING", 4, %{attempt_id: attempt.id})

    budget_fixture(task, %{attempt_id: attempt.id})
    lease_fixture(task, attempt)

    assert {:ok, %{task: implementing}} =
             transition(task, fixture.worker_actor, "IMPLEMENTING", 4, %{attempt_id: attempt.id})

    assert implementing.state == "IMPLEMENTING"
  end

  test "blocking preserves a resume state and unblocking requires all blockers to resolve" do
    fixture = domain_fixture()
    {:ok, %{task: specified}} = transition(fixture.task, fixture.system_actor, "SPECIFIED", 1)

    block_command = %{
      actor_id: fixture.system_actor.id,
      kind: "dependency",
      reason: "dependency unavailable",
      occurred_at: DateTime.add(base_time(), 2, :second),
      correlation_id: uuid(),
      idempotency_key: "block:dependency"
    }

    assert {:ok, %{task: blocked, blocker: blocker, idempotent?: false}} =
             Tasks.block_task(specified.id, block_command)

    assert {:ok, %{blocker: replayed_blocker, idempotent?: true}} =
             Tasks.block_task(specified.id, block_command)

    assert replayed_blocker.id == blocker.id
    assert Repo.aggregate(Blocker, :count) == 1

    assert blocked.state == "BLOCKED"
    assert blocked.resume_state == "SPECIFIED"

    assert {:error, :active_blockers_remain} =
             transition(blocked, fixture.system_actor, "SPECIFIED", 3)

    assert {:ok, %{blocker: resolved}} =
             Tasks.resolve_blocker(blocker.id, %{
               actor_id: fixture.human_actor.id,
               occurred_at: DateTime.add(base_time(), 3, :second),
               correlation_id: uuid(),
               idempotency_key: "resolve:dependency"
             })

    assert resolved.status == "resolved"

    assert {:error, :idempotency_conflict} =
             Tasks.resolve_blocker(blocker.id, %{
               actor_id: fixture.human_actor.id,
               occurred_at: DateTime.add(base_time(), 3, :second),
               correlation_id: uuid(),
               idempotency_key: "resolve:dependency"
             })

    assert {:ok, %{task: resumed}} = transition(blocked, fixture.system_actor, "SPECIFIED", 4)
    assert resumed.state == "SPECIFIED"
    assert resumed.resume_state == nil
  end

  test "cancellation is terminal and reopening requires an approved decision and budget" do
    fixture = domain_fixture()
    {:ok, %{task: specified}} = transition(fixture.task, fixture.system_actor, "SPECIFIED", 1)

    assert {:ok, %{task: cancelled}} =
             transition(specified, fixture.system_actor, "CANCELLED", 2, %{
               reason_code: "operator_cancel"
             })

    assert cancelled.terminal_at == DateTime.add(base_time(), 2, :second)

    assert {:error, :reopen_approval_required} =
             transition(cancelled, fixture.human_actor, "READY", 3)

    budget_fixture(cancelled)
    decision = decision_fixture(cancelled, fixture.human_actor, "reopen")

    assert {:ok, %{task: reopened}} =
             transition(cancelled, fixture.human_actor, "READY", 4, %{
               human_decision_id: decision.id
             })

    assert reopened.state == "READY"
    assert reopened.terminal_at == nil
  end

  test "budget exhaustion durably records usage, a blocker, and BLOCKED state" do
    fixture = domain_fixture()
    budget = budget_fixture(fixture.task, %{max_agent_turns: 2})

    command = %{
      budget_id: budget.id,
      task_id: fixture.task.id,
      actor_id: fixture.system_actor.id,
      metric: "agent_turns",
      quantity: 2,
      occurred_at: DateTime.add(base_time(), 1, :second),
      correlation_id: uuid(),
      idempotency_key: "usage:turns:1"
    }

    assert {:ok, %{usage: usage, exhausted?: true, idempotent?: false}} =
             Tasks.record_usage(command)

    assert Repo.get!(Budget, budget.id).status == "exhausted"
    assert Repo.get!(Task, fixture.task.id).state == "BLOCKED"

    blocker = Repo.get_by!(Blocker, task_id: fixture.task.id, kind: "budget_exhausted")
    assert blocker.status == "active"

    assert %TransitionEvent{reason_code: "budget_exhausted"} =
             Repo.get_by!(TransitionEvent,
               task_id: fixture.task.id,
               idempotency_key: "budget-exhausted:#{usage.id}"
             )

    assert {:ok, %{usage: replayed, idempotent?: true}} = Tasks.record_usage(command)
    assert replayed.id == usage.id
    assert {:error, :idempotency_conflict} = Tasks.record_usage(%{command | quantity: 1})
    assert Repo.aggregate(UsageEntry, :count) == 1

    resolution = %{
      actor_id: fixture.human_actor.id,
      occurred_at: DateTime.add(base_time(), 2, :second),
      correlation_id: uuid(),
      idempotency_key: "resolve:budget"
    }

    assert {:error, :approved_human_decision_required} =
             Tasks.resolve_blocker(blocker.id, resolution)

    decision = decision_fixture(fixture.task, fixture.human_actor, "budget_override")

    assert {:ok, %{blocker: resolved}} =
             Tasks.resolve_blocker(
               blocker.id,
               Map.put(resolution, :human_decision_id, decision.id)
             )

    assert resolved.status == "resolved"
  end

  test "retry due times are deterministic and survive scheduler-memory loss" do
    fixture = domain_fixture()
    due_at = DateTime.add(base_time(), 30, :second)

    command = %{
      task_id: fixture.task.id,
      sequence: 1,
      due_at: due_at,
      reason: "transient provider failure",
      resume_state: "DISCOVERED",
      correlation_id: uuid(),
      idempotency_key: "retry:provider:1"
    }

    assert {:error, {:retry_resume_state_mismatch, "DISCOVERED"}} =
             Tasks.schedule_retry(%{command | resume_state: "READY"})

    assert {:ok, %{retry: retry, idempotent?: false}} = Tasks.schedule_retry(command)
    assert Tasks.due_retries(DateTime.add(due_at, -1, :second)) == []
    assert Enum.map(Tasks.due_retries(due_at), & &1.id) == [retry.id]
    assert {:ok, %{retry: replayed, idempotent?: true}} = Tasks.schedule_retry(command)
    assert replayed.id == retry.id

    assert {:error, :idempotency_conflict} =
             Tasks.schedule_retry(%{command | reason: "different failure"})

    assert {:ok, %{retry: exhausted}} =
             Tasks.schedule_retry(
               Map.merge(command, %{
                 sequence: 2,
                 status: "exhausted",
                 idempotency_key: "retry:provider:2",
                 due_at: DateTime.add(due_at, 30, :second)
               })
             )

    assert exhausted.status == "exhausted"
    refute exhausted.id in Enum.map(Tasks.due_retries(exhausted.due_at), & &1.id)
  end

  test "restart reconciliation expires stale leases, loses attempts, blocks tasks, and schedules retry" do
    fixture = domain_fixture()
    task = advance_to_ready(fixture)
    attempt = attempt_fixture(task)
    budget_fixture(task, %{attempt_id: attempt.id})

    lease =
      lease_fixture(task, attempt, %{
        expires_at: DateTime.add(base_time(), 5, :second)
      })

    {:ok, %{task: implementing}} =
      transition(task, fixture.worker_actor, "IMPLEMENTING", 4, %{attempt_id: attempt.id})

    observed_at = DateTime.add(base_time(), 6, :second)
    snapshot = Tasks.restart_snapshot(observed_at)
    assert Enum.map(snapshot.stale_leases, & &1.id) == [lease.id]
    assert Enum.any?(snapshot.tasks, &(&1.id == implementing.id))

    assert [{:ok, %{idempotent?: false}}] =
             Tasks.reconcile_expired_leases(
               observed_at,
               fixture.system_actor.id,
               uuid()
             )

    assert Repo.get!(WorkerLease, lease.id).status == "expired"
    assert Repo.get!(TaskAttempt, attempt.id).status == "lost"
    assert Repo.get!(Task, task.id).state == "BLOCKED"
    assert Repo.get_by!(Blocker, task_id: task.id, kind: "lease_expired")

    assert Repo.get_by!(RetrySchedule,
             task_id: task.id,
             idempotency_key: "lease-retry:#{lease.id}"
           )

    assert Tasks.reconcile_expired_leases(observed_at, fixture.system_actor.id, uuid()) == []
  end

  test "an unknown outcome is represented as BLOCKED and never as success" do
    fixture = domain_fixture()

    assert {:ok, %{task: blocked}} =
             Tasks.block_task(fixture.task.id, %{
               actor_id: fixture.system_actor.id,
               kind: "indeterminate_outcome",
               reason: "external action outcome could not be observed",
               occurred_at: DateTime.add(base_time(), 1, :second),
               correlation_id: uuid(),
               idempotency_key: "unknown:external-action:1"
             })

    assert blocked.state == "BLOCKED"
    refute blocked.state in ["APPROVED", "DEPLOYED"]
  end

  test "SQLite is running in WAL mode with foreign keys enabled" do
    assert %{rows: [["wal"]]} = Ecto.Adapters.SQL.query!(Repo, "PRAGMA journal_mode")
    assert %{rows: [[1]]} = Ecto.Adapters.SQL.query!(Repo, "PRAGMA foreign_keys")
  end

  defp advance_to_ready(fixture) do
    {:ok, %{task: task}} = transition(fixture.task, fixture.system_actor, "SPECIFIED", 1)
    {:ok, %{task: task}} = transition(task, fixture.system_actor, "PLANNED", 2)
    {:ok, %{task: task}} = transition(task, fixture.system_actor, "READY", 3)
    task
  end

  defp advance_to_implementing(fixture) do
    task = advance_to_ready(fixture)
    attempt = attempt_fixture(task)
    budget_fixture(task, %{attempt_id: attempt.id})
    lease_fixture(task, attempt)

    {:ok, %{task: task}} =
      transition(task, fixture.worker_actor, "IMPLEMENTING", 4, %{attempt_id: attempt.id})

    task
  end
end
