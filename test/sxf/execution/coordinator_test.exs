defmodule Sxf.Execution.CoordinatorTest do
  use Sxf.DataCase, async: false

  alias Sxf.Execution.{Claim, Coordinator, Event}
  alias Sxf.Execution.TaskStore.Ecto, as: TaskStore
  alias Sxf.ExecutionFakes.{Agent, AgentWithoutResume, Sandbox, Workspace}
  alias Sxf.Repo
  alias Sxf.Tasks.Task, as: DomainTask

  alias Sxf.Tasks.{
    Blocker,
    Budget,
    ExecutionEvent,
    LeaseRenewal,
    RetrySchedule,
    TaskAttempt,
    UsageEntry,
    WorkerLease
  }

  @execution_time ~U[2026-07-20 20:00:10.000000Z]

  test "eligible tasks are selected deterministically by transition time and id" do
    first = ready_fixture()
    second = ready_fixture()
    budget_fixture(first.task)
    budget_fixture(second.task)

    expected = Enum.min([first.task.id, second.task.id])
    assert {:ok, %Claim{} = claim} = TaskStore.claim_next(claim_attrs(first, "deterministic"))
    assert claim.task.id == expected
  end

  test "claim, attempt, lease, and transition are atomic and generated values do not break replay" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    attrs = Map.put(claim_attrs(fixture, "atomic"), :dispatch_input, %{task_contract: "same"})

    assert {:ok, %Claim{replayed?: false} = first} = TaskStore.claim_next(attrs)
    assert {:ok, %Claim{replayed?: true} = replay} = TaskStore.claim_next(attrs)
    assert replay.attempt.id == first.attempt.id
    assert replay.lease.id == first.lease.id

    generated_values_changed = %{
      attrs
      | occurred_at: DateTime.add(attrs.occurred_at, 1, :second),
        expires_at: DateTime.add(attrs.expires_at, 2, :second),
        correlation_id: uuid()
    }

    assert {:ok, %Claim{replayed?: true}} = TaskStore.claim_next(generated_values_changed)

    assert {:error, :idempotency_conflict} =
             TaskStore.claim_next(%{
               generated_values_changed
               | dispatch_input: %{task_contract: "changed"}
             })

    assert Repo.aggregate(TaskAttempt, :count) == 1
    assert Repo.aggregate(WorkerLease, :count) == 1
    assert Repo.get!(DomainTask, fixture.task.id).state == "IMPLEMENTING"
    assert {:ok, nil} = TaskStore.claim_next(claim_attrs(fixture, "duplicate-tick"))
  end

  test "concurrent claims cannot create duplicate active attempts" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    parent = self()

    callers =
      for suffix <- ["a", "b"] do
        Elixir.Task.async(fn ->
          send(parent, {:claim_started, suffix})
          TaskStore.claim_next(claim_attrs(fixture, "race-#{suffix}"))
        end)
      end

    assert_receive {:claim_started, _}
    assert_receive {:claim_started, _}
    results = Enum.map(callers, &Elixir.Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, %Claim{}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, nil}, &1)) == 1
    assert Repo.aggregate(TaskAttempt, :count) == 1
    assert Repo.aggregate(WorkerLease, :count) == 1
  end

  test "supervised execution does not block coordinator calls" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {coordinator, _supervisor} = start_coordinator(fixture, scenario: :hanging, notify: self())

    assert {:ok, %{status: :accepted}} = Coordinator.tick(coordinator)
    assert_receive {:agent_started, worker}
    assert Process.alive?(worker)
    assert Coordinator.active_count(coordinator) == 1
    assert [] = Coordinator.advance(coordinator, DateTime.add(@execution_time, 1, :second))
  end

  test "successful execution persists events and usage, releases the lease, and advances" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    event = usage_event(1, %{agent_turns: 1, runtime_ms: 5, cost_microusd: 10})
    {coordinator, _supervisor} = start_coordinator(fixture, events: [event])

    assert %{outcome: %{outcome: :success}} = dispatch_and_wait(coordinator)
    assert Repo.get!(DomainTask, fixture.task.id).state == "CI_RUNNING"
    assert Repo.get_by!(TaskAttempt, task_id: fixture.task.id).status == "succeeded"
    assert Repo.get_by!(WorkerLease, task_id: fixture.task.id).status == "released"
    assert Repo.aggregate(ExecutionEvent, :count) == 2
    assert Repo.aggregate(UsageEntry, :count) == 3
    assert {:ok, :idle} = Coordinator.tick(coordinator)
  end

  for {scenario, state, attempt_status} <- [
        {:deterministic_failure, "FAILED", "failed"},
        {:timeout, "FAILED", "failed"},
        {:cancelled, "CANCELLED", "cancelled"}
      ] do
    test "backend-declared #{scenario} produces its explicit durable outcome" do
      fixture = ready_fixture()
      budget_fixture(fixture.task)
      {coordinator, _supervisor} = start_coordinator(fixture, scenario: unquote(scenario))

      assert %{outcome: %{outcome: unquote(scenario)}} = dispatch_and_wait(coordinator)
      assert Repo.get!(DomainTask, fixture.task.id).state == unquote(state)
      assert Repo.get_by!(TaskAttempt, task_id: fixture.task.id).status == unquote(attempt_status)
      assert Repo.get_by!(WorkerLease, task_id: fixture.task.id).status == "released"
    end
  end

  test "lease expiry remains exactly one TTL after each trusted renewal heartbeat" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {coordinator, _supervisor} = start_coordinator(fixture, scenario: :blocking, notify: self())

    assert {:ok, %{status: :accepted, claim: claim}} = Coordinator.tick(coordinator)
    assert_receive {:agent_started, worker}

    assert [%{action: :renewed}] =
             Coordinator.advance(coordinator, DateTime.add(@execution_time, 10, :second))

    first_expiry = Repo.get!(WorkerLease, claim.lease.id).expires_at
    assert first_expiry == at(40_000)

    assert [%{action: :renewed}] =
             Coordinator.advance(coordinator, DateTime.add(@execution_time, 20, :second))

    assert Repo.get!(WorkerLease, claim.lease.id).expires_at == at(50_000)

    assert [%{action: :renewed}] = Coordinator.advance(coordinator, at(30_000))
    assert Repo.get!(WorkerLease, claim.lease.id).expires_at == at(60_000)

    assert Enum.map(
             Repo.all(from renewal in LeaseRenewal, order_by: renewal.sequence),
             & &1.sequence
           ) == [1, 2, 3]

    send(worker, :continue)
    assert {:ok, [_]} = Coordinator.await_idle(coordinator)
  end

  test "lease renewal stops after normal completion" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {coordinator, _supervisor} = start_coordinator(fixture, scenario: :blocking, notify: self())

    assert {:ok, %{status: :accepted}} = Coordinator.tick(coordinator)
    assert_receive {:agent_started, worker}
    assert [%{action: :renewed}] = Coordinator.advance(coordinator, at(10_000))
    send(worker, :continue)
    assert {:ok, [_]} = Coordinator.await_idle(coordinator)
    assert [] = Coordinator.advance(coordinator, at(20_000))
    assert Repo.aggregate(LeaseRenewal, :count) == 1
  end

  test "lease renewal replay is exact, changed input conflicts, and expiry is a hard fence" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {:ok, claim} = TaskStore.claim_next(claim_attrs(fixture, "renewal-replay"))

    attrs = %{
      renewed_at: at(10_000),
      expires_at: at(70_000),
      sequence: 1,
      idempotency_key: "lease-renewal:#{claim.lease.id}:1"
    }

    assert {:ok, %{idempotent?: false}} = TaskStore.renew_lease(claim, attrs)
    assert {:ok, %{idempotent?: true}} = TaskStore.renew_lease(claim, attrs)
    assert Repo.aggregate(LeaseRenewal, :count) == 1

    assert {:error, :idempotency_conflict} =
             TaskStore.renew_lease(claim, %{attrs | expires_at: at(70_001)})

    assert {:error, :stale_backend_event} =
             TaskStore.renew_lease(claim, %{
               renewed_at: attrs.expires_at,
               expires_at: at(130_000),
               sequence: 2,
               idempotency_key: "lease-renewal:#{claim.lease.id}:2"
             })
  end

  test "invalid lease and control timing relationships are rejected at startup" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    common = [
      task_store: TaskStore,
      agent_backend: Agent,
      workspace_backend: Workspace,
      sandbox_backend: Sandbox,
      actor_id: uuid(),
      worker_id: "invalid-timing"
    ]

    assert {:error, {:invalid_timing_configuration, :lease_renewal_interval_must_precede_ttl}} =
             Coordinator.start_link(
               common ++ [lease_ttl_ms: 10, lease_renewal_interval_ms: 10, control_tick_ms: 1]
             )

    assert {:error, {:invalid_timing_configuration, :control_tick_must_be_positive}} =
             Coordinator.start_link(
               common ++ [lease_ttl_ms: 10, lease_renewal_interval_ms: 5, control_tick_ms: 0]
             )

    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "stale lease renewal cancels execution and prevents continued authority" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {coordinator, _supervisor} = start_coordinator(fixture, scenario: :hanging, notify: self())

    assert {:ok, %{status: :accepted, claim: claim}} = Coordinator.tick(coordinator)
    assert_receive {:agent_started, _worker}
    expired_at = DateTime.add(claim.lease.expires_at, 1, :millisecond)
    assert [_] = TaskStore.reconcile_expired(expired_at, fixture.system_actor.id, uuid())

    assert [%{action: :lease_expired}] = Coordinator.advance(coordinator, expired_at)
    assert_receive {:agent_cancelled, attempt_id}
    assert attempt_id == claim.attempt.id
    assert {:ok, [_]} = Coordinator.await_idle(coordinator)
    assert Coordinator.active_count(coordinator) == 0
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"

    event = usage_event(1, %{agent_turns: 1}, DateTime.add(@execution_time, 1, :millisecond))

    assert {:error, :stale_backend_event} =
             TaskStore.record_event(claim, event, event_attrs(fixture, expired_at))
  end

  test "a hanging backend reaches the authoritative runtime deadline and is cancelled once" do
    fixture = ready_fixture()
    budget = budget_fixture(fixture.task, %{max_runtime_ms: 50})
    {coordinator, _supervisor} = start_coordinator(fixture, scenario: :hanging, notify: self())

    assert {:ok, %{status: :accepted, claim: claim}} = Coordinator.tick(coordinator)
    assert_receive {:agent_started, _worker}
    assert [%{action: :runtime_timeout}] = Coordinator.advance(coordinator, at(50))
    assert_receive {:agent_cancelled, attempt_id}
    assert attempt_id == claim.attempt.id
    assert {:ok, [completion]} = Coordinator.await_idle(coordinator)
    assert completion.outcome == :runtime_timeout
    refute_receive {:agent_cancelled, ^attempt_id}

    assert Repo.get!(Budget, budget.id).status == "exhausted"
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
    assert Repo.get_by!(Blocker, task_id: fixture.task.id).kind == "runtime_exhausted"
    assert Repo.get!(TaskAttempt, claim.attempt.id).status == "failed"
    assert Repo.get!(WorkerLease, claim.lease.id).status == "released"

    assert [%UsageEntry{quantity: 50}] =
             Repo.all(
               from usage in UsageEntry,
                 where: usage.task_id == ^fixture.task.id and usage.metric == "runtime_ms"
             )
  end

  test "positive durable runtime usage refreshes the deadline and stops a later hang at remaining time" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_runtime_ms: 100_000})
    event = usage_event(1, %{runtime_ms: 80_000})

    {coordinator, _supervisor} =
      start_coordinator(fixture, scenario: :controllable, notify: self())

    assert {:ok, %{status: :accepted}} = Coordinator.tick(coordinator)
    assert_receive {:agent_started, worker}
    send(worker, {:emit, event})
    assert_receive {:event_emitted, event_id}
    assert event_id == event.id

    [entry] = :sys.get_state(coordinator).active |> Map.values()
    assert entry.runtime_deadline_at == at(20_000)
    assert Repo.get!(TaskAttempt, entry.claim.attempt.id).runtime_deadline_at == at(20_000)
    assert [%{action: :renewed}] = Coordinator.advance(coordinator, at(19_999))
    [entry] = :sys.get_state(coordinator).active |> Map.values()
    assert entry.runtime_deadline_at == at(20_000)
    assert [%{action: :runtime_timeout}] = Coordinator.advance(coordinator, at(20_000))
    assert {:ok, [%{outcome: :runtime_timeout}]} = Coordinator.await_idle(coordinator)
  end

  test "runtime usage replay cannot shorten the durable deadline twice and changed replay conflicts" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_runtime_ms: 100_000})
    {:ok, claim} = TaskStore.claim_next(claim_attrs(fixture, "runtime-replay"))
    event = usage_event(1, %{runtime_ms: 80_000})
    attrs = event_attrs(fixture, @execution_time)

    assert {:ok, %{idempotent?: false, attempt: attempt}} =
             TaskStore.record_event(claim, event, attrs)

    assert attempt.runtime_deadline_at == at(20_000)

    assert {:ok, %{idempotent?: true, attempt: replayed_attempt}} =
             TaskStore.record_event(claim, event, %{attrs | observed_at: at(5_000)})

    assert replayed_attempt.runtime_deadline_at == at(20_000)
    assert runtime_total(fixture.task.id) == 80_000

    assert {:error, :idempotency_conflict} =
             TaskStore.record_event(claim, %{event | usage: %{runtime_ms: 80_001}}, attrs)
  end

  test "lease renewal preserves an earlier refreshed runtime deadline" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_runtime_ms: 100_000})
    event = usage_event(1, %{runtime_ms: 80_000})

    {coordinator, _supervisor} =
      start_coordinator(fixture, scenario: :controllable, notify: self())

    assert {:ok, %{status: :accepted}} = Coordinator.tick(coordinator)
    assert_receive {:agent_started, worker}
    send(worker, {:emit, event})
    assert_receive {:event_emitted, _}
    assert [%{action: :renewed}] = Coordinator.advance(coordinator, at(10_000))

    [entry] = :sys.get_state(coordinator).active |> Map.values()
    assert entry.runtime_deadline_at == at(20_000)
    assert entry.claim.lease.expires_at == at(40_000)

    send(worker, :continue)
    assert {:ok, [_]} = Coordinator.await_idle(coordinator)
  end

  test "an event observed at the refreshed runtime deadline is rejected durably" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_runtime_ms: 100_000})
    {:ok, claim} = TaskStore.claim_next(claim_attrs(fixture, "late-runtime-event"))
    first = usage_event(1, %{runtime_ms: 80_000})
    assert {:ok, _} = TaskStore.record_event(claim, first, event_attrs(fixture, @execution_time))

    late = usage_event(2, %{agent_turns: 1}, at(20_000))

    assert {:error, :runtime_deadline_reached} =
             TaskStore.record_event(claim, late, event_attrs(fixture, at(20_000)))
  end

  test "a late backend event after control-plane timeout is rejected" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_runtime_ms: 25})
    {coordinator, _supervisor} = start_coordinator(fixture, scenario: :hanging)

    assert {:ok, %{claim: claim}} = Coordinator.tick(coordinator)
    assert [%{action: :runtime_timeout}] = Coordinator.advance(coordinator, at(25))
    assert {:ok, [_]} = Coordinator.await_idle(coordinator)

    late = usage_event(1, %{agent_turns: 1}, at(1))

    assert {:error, :stale_backend_event} =
             TaskStore.record_event(claim, late, event_attrs(fixture, at(26)))
  end

  test "cancellation failure remains visible on a control-plane timeout" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_runtime_ms: 10})
    {coordinator, _supervisor} = start_coordinator(fixture, scenario: :hanging, cancel: :error)

    assert {:ok, %{claim: claim}} = Coordinator.tick(coordinator)
    assert [%{action: :runtime_timeout}] = Coordinator.advance(coordinator, at(10))
    assert {:ok, [%{cancellation: %{result: :error}}]} = Coordinator.await_idle(coordinator)

    completion =
      Repo.one!(
        from event in ExecutionEvent,
          where: event.attempt_id == ^claim.attempt.id and event.kind == "timed_out"
      )

    assert completion.payload["cancellation"]["result"] == "error"
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
  end

  test "backdated backend occurrence time cannot bypass trusted lease observation" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    attrs = claim_attrs(fixture, "backdated")
    {:ok, claim} = TaskStore.claim_next(attrs)
    event = usage_event(1, %{agent_turns: 1}, DateTime.add(attrs.occurred_at, 1, :second))
    observed_after_expiry = DateTime.add(attrs.expires_at, 1, :millisecond)

    assert {:error, :stale_backend_event} =
             TaskStore.record_event(claim, event, event_attrs(fixture, observed_after_expiry))
  end

  test "backend unavailability atomically consumes one provider retry" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 2})
    {coordinator, _supervisor} = start_coordinator(fixture, scenario: :unavailable)

    assert %{outcome: %{outcome: :backend_unavailable}} = dispatch_and_wait(coordinator)
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
    assert Repo.get_by!(Blocker, task_id: fixture.task.id).kind == "external_failure"
    assert Repo.get_by!(RetrySchedule, task_id: fixture.task.id).status == "scheduled"
    assert provider_retry_total(fixture.task.id) == 1
  end

  test "interrupted-session recovery consumes one provider retry and exact replay consumes none" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 2})
    {:ok, claim} = TaskStore.claim_next(claim_attrs(fixture, "interrupted"))
    attrs = finish_attrs(fixture, "interrupted", at(1_000))

    assert {:ok, %{idempotent?: false}} = TaskStore.interrupt(claim, attrs)
    assert provider_retry_total(fixture.task.id) == 1
    assert {:ok, %{idempotent?: true}} = TaskStore.interrupt(claim, attrs)
    assert provider_retry_total(fixture.task.id) == 1
    assert Repo.aggregate(RetrySchedule, :count) == 1
  end

  test "expired-lease recovery consumes one provider retry and exact reconciliation is stable" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 2})
    attrs = claim_attrs(fixture, "expired")
    {:ok, claim} = TaskStore.claim_next(attrs)
    observed_at = DateTime.add(attrs.expires_at, 1, :millisecond)

    assert [%{idempotent?: false}] =
             TaskStore.reconcile_expired(observed_at, fixture.system_actor.id, uuid())

    assert provider_retry_total(fixture.task.id) == 1
    assert Repo.get!(WorkerLease, claim.lease.id).status == "expired"
    assert Repo.get!(TaskAttempt, claim.attempt.id).status == "lost"
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
    assert Repo.get_by!(RetrySchedule, task_id: fixture.task.id).status == "scheduled"
    assert [] = TaskStore.reconcile_expired(observed_at, fixture.system_actor.id, uuid())
    assert provider_retry_total(fixture.task.id) == 1
  end

  test "max_provider_retries two permits exactly two attempts after the initial attempt" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 2})
    {:ok, first} = TaskStore.claim_next(claim_attrs(fixture, "retry-initial"))

    {:ok, _} =
      TaskStore.finish(first, :backend_unavailable, finish_attrs(fixture, "loss-1", at(1)))

    retry_one = Repo.get_by!(RetrySchedule, task_id: fixture.task.id, sequence: 1)

    {:ok, second} =
      TaskStore.claim_next(retry_claim_attrs(fixture, "retry-one", retry_one.due_at))

    {:ok, _} =
      TaskStore.finish(
        second,
        :backend_unavailable,
        finish_attrs(fixture, "loss-2", DateTime.add(retry_one.due_at, 1, :millisecond))
      )

    retry_two = Repo.get_by!(RetrySchedule, task_id: fixture.task.id, sequence: 2)
    {:ok, third} = TaskStore.claim_next(retry_claim_attrs(fixture, "retry-two", retry_two.due_at))

    {:ok, _} =
      TaskStore.finish(
        third,
        :backend_unavailable,
        finish_attrs(fixture, "loss-3", DateTime.add(retry_two.due_at, 1, :millisecond))
      )

    assert Repo.aggregate(TaskAttempt, :count) == 3
    assert provider_retry_total(fixture.task.id) == 2

    assert Repo.get_by!(RetrySchedule, task_id: fixture.task.id, sequence: 3).status ==
             "exhausted"
  end

  test "zero provider retries allows the initial attempt but schedules no retry" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 0})
    {coordinator, _supervisor} = start_coordinator(fixture, scenario: :unavailable)

    assert %{outcome: %{outcome: :backend_unavailable}} = dispatch_and_wait(coordinator)
    assert Repo.aggregate(TaskAttempt, :count) == 1
    assert provider_retry_total(fixture.task.id) == 0
    assert Repo.get_by!(RetrySchedule, task_id: fixture.task.id).status == "exhausted"
  end

  test "completed dispatch replay reconstructs durable result without invoking backends" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {coordinator, _supervisor} = start_coordinator(fixture, notify: self())
    key = "dispatch:complete-replay"

    assert %{outcome: %{outcome: :success}} = dispatch_and_wait(coordinator, idempotency_key: key)
    drain_boundary_messages()
    assert {:ok, %{status: :replayed}} = Coordinator.tick(coordinator, idempotency_key: key)
    refute_receive :workspace_prepare
    refute_receive :sandbox_prepare
    refute_receive {:agent_started, _}
    assert Repo.aggregate(TaskAttempt, :count) == 1
  end

  test "active dispatch replay does not duplicate external execution" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {coordinator, _supervisor} = start_coordinator(fixture, scenario: :blocking, notify: self())
    key = "dispatch:active-replay"

    assert {:ok, %{status: :accepted}} = Coordinator.tick(coordinator, idempotency_key: key)
    assert_receive {:agent_started, worker}
    drain_boundary_messages()
    assert {:ok, %{status: :replayed}} = Coordinator.tick(coordinator, idempotency_key: key)
    refute_receive :workspace_prepare
    refute_receive {:agent_started, _}
    assert Repo.aggregate(TaskAttempt, :count) == 1
    send(worker, :continue)
    assert {:ok, [_]} = Coordinator.await_idle(coordinator)
  end

  test "dispatch key reuse with changed accepted input conflicts" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {coordinator, _supervisor} = start_coordinator(fixture, scenario: :blocking, notify: self())
    key = "dispatch:changed-input"

    assert {:ok, %{status: :accepted}} =
             Coordinator.tick(coordinator,
               idempotency_key: key,
               dispatch_input: %{task_contract: "one"}
             )

    assert_receive {:agent_started, worker}

    assert {:error, {:claim_failed, :idempotency_conflict}} =
             Coordinator.tick(coordinator,
               idempotency_key: key,
               dispatch_input: %{task_contract: "two"}
             )

    send(worker, :continue)
    assert {:ok, [_]} = Coordinator.await_idle(coordinator)
  end

  test "sandbox preparation failure releases the prepared workspace" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 2})
    {coordinator, _supervisor} = start_coordinator(fixture, sandbox: :unavailable, notify: self())

    assert %{outcome: %{outcome: :backend_unavailable}} = dispatch_and_wait(coordinator)
    assert_receive :workspace_prepare
    assert_receive :sandbox_prepare
    assert_receive :workspace_release
    refute_receive {:agent_started, _}
  end

  test "cleanup failure is observable and does not replace the primary success outcome" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {coordinator, _supervisor} = start_coordinator(fixture, workspace_release: :error)

    assert %{outcome: %{outcome: :success}, cleanup_errors: [%{boundary: :workspace}]} =
             dispatch_and_wait(coordinator)

    assert Repo.get!(DomainTask, fixture.task.id).state == "CI_RUNNING"
    completion = Repo.get_by!(ExecutionEvent, task_id: fixture.task.id, kind: "completed")
    assert [%{"boundary" => "workspace"}] = completion.payload["cleanup_errors"]
  end

  test "workspace backend unavailability is contained behind the contract" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 2})

    {coordinator, _supervisor} =
      start_coordinator(fixture, workspace: :unavailable, notify: self())

    assert %{outcome: %{outcome: :backend_unavailable}} = dispatch_and_wait(coordinator)
    assert_receive :workspace_prepare
    refute_receive :sandbox_prepare
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
  end

  for {metric, limit, blocker_kind} <- [
        {:runtime_ms, 10, "runtime_exhausted"},
        {:agent_turns, 2, "budget_exhausted"},
        {:cost_microusd, 25, "budget_exhausted"},
        {:repair_cycles, 1, "budget_exhausted"}
      ] do
    test "#{metric} event ceiling blocks the task durably" do
      fixture = ready_fixture()
      budget_fixture(fixture.task, %{unquote(:"max_#{metric}") => unquote(limit)})
      event = usage_event(1, %{unquote(metric) => unquote(limit)})
      {coordinator, _supervisor} = start_coordinator(fixture, events: [event])

      assert %{outcome: %{outcome: :deterministic_failure}} = dispatch_and_wait(coordinator)
      assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
      assert Repo.get_by!(Blocker, task_id: fixture.task.id).kind == unquote(blocker_kind)

      assert Repo.get_by!(UsageEntry,
               task_id: fixture.task.id,
               metric: unquote(to_string(metric))
             ).quantity == unquote(limit)
    end
  end

  test "worker event payload cannot raise a durable budget ceiling" do
    fixture = ready_fixture()
    budget = budget_fixture(fixture.task, %{max_agent_turns: 1})
    event = %{usage_event(1, %{agent_turns: 1}) | payload: %{requested_max_agent_turns: 10_000}}
    {coordinator, _supervisor} = start_coordinator(fixture, events: [event])

    dispatch_and_wait(coordinator)
    assert Repo.get!(Budget, budget.id).max_agent_turns == 1
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
  end

  test "a restarted coordinator reconciles an interrupted active attempt" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {first, first_supervisor} = start_coordinator(fixture, scenario: :hanging, notify: self())
    assert {:ok, %{status: :accepted}} = Coordinator.tick(first)
    assert_receive {:agent_started, _worker}

    Process.unlink(first)
    ref = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^ref, :process, ^first, :killed}
    Supervisor.stop(first_supervisor)

    {second, _second_supervisor} = start_coordinator(fixture, inspect: :missing)
    assert %{interrupted: [_]} = Coordinator.reconcile(second)
    assert {:ok, [_]} = Coordinator.await_idle(second)
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
    assert Repo.get_by!(TaskAttempt, task_id: fixture.task.id).status == "lost"
    assert Repo.get_by!(WorkerLease, task_id: fixture.task.id).status == "lost"
    assert Repo.get_by!(RetrySchedule, task_id: fixture.task.id).status == "scheduled"
    assert provider_retry_total(fixture.task.id) == 1
  end

  test "restart safely resumes a running durable session exactly once without a new claim" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_runtime_ms: 20_000})

    {first, first_supervisor} =
      start_coordinator(fixture,
        scenario: :started_then_hanging,
        notify: self()
      )

    assert {:ok, %{status: :accepted, claim: original}} = Coordinator.tick(first)
    assert_receive {:agent_started, _}
    assert_receive {:event_emitted, _}
    stop_coordinator(first, first_supervisor)

    {second, _second_supervisor} =
      start_coordinator(fixture,
        inspect: :running,
        resume_scenario: :hanging,
        notify: self()
      )

    assert %{resumed: [%{action: :resumed}]} = Coordinator.reconcile(second)
    assert_receive {:agent_resumed, resumed_worker}
    assert %{resumed: [], interrupted: []} = Coordinator.reconcile(second)
    assert Repo.aggregate(TaskAttempt, :count) == 1
    assert Repo.aggregate(WorkerLease, :count) == 1

    [entry] = :sys.get_state(second).active |> Map.values()
    assert entry.mode == :resume
    assert entry.claim.attempt.id == original.attempt.id
    assert entry.claim.lease.id == original.lease.id
    assert entry.claim.lease.fencing_token == original.lease.fencing_token
    assert entry.claim.attempt.backend_session_id == "fake-session-#{original.attempt.id}"

    assert [%{action: :renewed}] = Coordinator.advance(second, at(10_000))
    assert [%{action: :runtime_timeout}] = Coordinator.advance(second, at(20_000))
    assert_receive {:agent_cancelled, attempt_id}
    assert attempt_id == original.attempt.id
    assert {:ok, [%{outcome: :runtime_timeout}]} = Coordinator.await_idle(second)
    refute Process.alive?(resumed_worker)
  end

  test "unsupported and failed resume become one explicit interrupted retry" do
    for {suffix, agent_backend, resume_scenario} <- [
          {"unsupported", AgentWithoutResume, :hanging},
          {"failed", Agent, :unavailable}
        ] do
      fixture = ready_fixture()
      budget_fixture(fixture.task, %{max_provider_retries: 2})
      claim = claim_with_session(fixture, "restart-#{suffix}")

      {coordinator, _supervisor} =
        start_coordinator(fixture,
          agent_backend: agent_backend,
          inspect: :running,
          resume_scenario: resume_scenario,
          notify: self()
        )

      report = Coordinator.reconcile(coordinator)
      assert report.resumed != [] or report.interrupted != []
      assert {:ok, [_]} = Coordinator.await_idle(coordinator)
      assert Repo.get!(TaskAttempt, claim.attempt.id).status == "lost"
      assert Repo.get!(WorkerLease, claim.lease.id).status == "lost"
      assert provider_retry_total(fixture.task.id) == 1

      assert Repo.aggregate(
               from(retry in RetrySchedule, where: retry.task_id == ^fixture.task.id),
               :count
             ) == 1

      assert %{resumed: [], interrupted: []} = Coordinator.reconcile(coordinator)
      assert provider_retry_total(fixture.task.id) == 1
    end
  end

  test "failed reattachment with no provider retry capacity is explicitly exhausted" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 0})
    claim = claim_with_session(fixture, "resume-exhausted")

    {coordinator, _supervisor} =
      start_coordinator(fixture,
        inspect: :running,
        resume_scenario: :unavailable
      )

    assert %{resumed: [_]} = Coordinator.reconcile(coordinator)
    assert {:ok, [_]} = Coordinator.await_idle(coordinator)
    assert Repo.get!(TaskAttempt, claim.attempt.id).status == "lost"
    assert Repo.get_by!(RetrySchedule, task_id: fixture.task.id).status == "exhausted"
    assert provider_retry_total(fixture.task.id) == 0
  end

  test "a lease that expires during restart inspection follows durable expiry recovery" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 2})
    claim = claim_with_session(fixture, "expiry-during-inspect")
    {clock, now_fn} = mutable_clock(@execution_time)

    inspect = fn _context ->
      Elixir.Agent.update(clock, fn _ -> claim.lease.expires_at end)
      {:ok, :running}
    end

    {coordinator, _supervisor} =
      start_coordinator(fixture, now_fn: now_fn, inspect: inspect)

    assert %{expired: [_], resumed: []} = Coordinator.reconcile(coordinator)
    assert Repo.get!(TaskAttempt, claim.attempt.id).status == "lost"
    assert Repo.get!(WorkerLease, claim.lease.id).status == "expired"
    assert provider_retry_total(fixture.task.id) == 1
  end

  test "a stale fencing token cannot be refreshed or reattached" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    claim = claim_with_session(fixture, "stale-reattach")
    stale = %{claim | lease: %{claim.lease | fencing_token: claim.lease.fencing_token + 1}}

    assert {:error, :stale_backend_event} = TaskStore.refresh_claim(stale, @execution_time)
    assert Repo.get!(TaskAttempt, claim.attempt.id).status == "running"
    assert Repo.get!(WorkerLease, claim.lease.id).status == "active"
  end

  test "runtime reached during restart inspection uses the control-plane timeout path" do
    fixture = ready_fixture()
    budget = budget_fixture(fixture.task, %{max_runtime_ms: 10})
    claim = claim_with_session(fixture, "runtime-during-inspect")
    {clock, now_fn} = mutable_clock(@execution_time)

    inspect = fn _context ->
      Elixir.Agent.update(clock, fn _ -> at(10_000) end)
      {:ok, :running}
    end

    {coordinator, _supervisor} =
      start_coordinator(fixture, now_fn: now_fn, inspect: inspect, notify: self())

    assert %{interrupted: [%{action: :runtime_timeout}]} = Coordinator.reconcile(coordinator)
    assert {:ok, [%{outcome: :runtime_timeout}]} = Coordinator.await_idle(coordinator)
    assert Repo.get!(Budget, budget.id).status == "exhausted"
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
    assert Repo.get!(TaskAttempt, claim.attempt.id).status == "failed"
  end

  test "finished, unknown, and unavailable inspection states never become success" do
    for {suffix, inspection} <- [
          {"finished", :finished},
          {"unknown", :unknown},
          {"unavailable", {:error, :unavailable}}
        ] do
      fixture = ready_fixture()
      budget_fixture(fixture.task, %{max_provider_retries: 1})
      claim = claim_with_session(fixture, "inspection-#{suffix}")
      {coordinator, _supervisor} = start_coordinator(fixture, inspect: inspection)

      assert %{interrupted: [_]} = Coordinator.reconcile(coordinator)
      assert {:ok, [_]} = Coordinator.await_idle(coordinator)
      refute Repo.get!(TaskAttempt, claim.attempt.id).status == "succeeded"
      refute Repo.get!(DomainTask, fixture.task.id).state == "CI_RUNNING"
    end
  end

  test "periodic control reconciliation expires an orphaned durable lease" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 1})
    {:ok, claim} = TaskStore.claim_next(claim_attrs(fixture, "periodic-orphan"))
    {clock, now_fn} = mutable_clock(@execution_time)

    {coordinator, _supervisor} =
      start_coordinator(fixture,
        now_fn: now_fn,
        automatic_timers: true,
        control_tick_ms: 5_000
      )

    timer = Coordinator.control_timer(coordinator)
    Elixir.Agent.update(clock, fn _ -> claim.lease.expires_at end)
    send(coordinator, {:control_tick, timer.token})
    assert Coordinator.active_count(coordinator) == 0
    assert Repo.get!(WorkerLease, claim.lease.id).status == "expired"
    assert Repo.get!(TaskAttempt, claim.attempt.id).status == "lost"
    assert provider_retry_total(fixture.task.id) == 1
  end

  test "restart resume reconstructs the persisted remaining-runtime deadline" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_runtime_ms: 100_000})
    claim = claim_with_session(fixture, "remaining-runtime", %{runtime_ms: 80_000})
    assert claim.runtime_deadline_at == at(20_000)

    {coordinator, _supervisor} =
      start_coordinator(fixture,
        inspect: :running,
        resume_scenario: :hanging,
        notify: self()
      )

    assert %{resumed: [_]} = Coordinator.reconcile(coordinator)
    assert_receive {:agent_resumed, _}
    [entry] = :sys.get_state(coordinator).active |> Map.values()
    assert entry.runtime_deadline_at == at(20_000)
    assert [%{action: :renewed}] = Coordinator.advance(coordinator, at(19_999))
    [entry] = :sys.get_state(coordinator).active |> Map.values()
    assert entry.runtime_deadline_at == at(20_000)
    assert [%{action: :runtime_timeout}] = Coordinator.advance(coordinator, at(20_000))
    assert {:ok, [_]} = Coordinator.await_idle(coordinator)
  end

  test "multiple active executions and an earlier usage deadline retain one owned timer" do
    first_fixture = ready_fixture()
    second_fixture = ready_fixture()
    budget_fixture(first_fixture.task, %{max_runtime_ms: 100_000})
    budget_fixture(second_fixture.task, %{max_runtime_ms: 100_000})

    {coordinator, _supervisor} =
      start_coordinator(first_fixture,
        scenario: :controllable,
        notify: self(),
        automatic_timers: true,
        control_tick_ms: 30_000
      )

    assert {:ok, %{status: :accepted}} = Coordinator.tick(coordinator)
    assert_receive {:agent_started, first_worker}
    first_timer = Coordinator.control_timer(coordinator)
    assert is_reference(first_timer.ref)
    assert first_timer.deadline == at(10_000)

    assert {:ok, %{status: :accepted}} = Coordinator.tick(coordinator)
    assert_receive {:agent_started, second_worker}
    second_timer = Coordinator.control_timer(coordinator)
    assert second_timer.ref == first_timer.ref
    assert Coordinator.active_count(coordinator) == 2

    event = usage_event(1, %{runtime_ms: 95_000})
    send(first_worker, {:emit, event})
    assert_receive {:event_emitted, _}
    earlier_timer = Coordinator.control_timer(coordinator)
    refute earlier_timer.ref == first_timer.ref
    assert earlier_timer.deadline == at(5_000)
    assert Process.read_timer(first_timer.ref) == false

    send(first_worker, :continue)
    send(second_worker, :continue)
    assert {:ok, completions} = Coordinator.await_idle(coordinator)
    assert length(completions) == 2

    reconciliation_timer = Coordinator.control_timer(coordinator)
    assert is_reference(reconciliation_timer.ref)
    assert reconciliation_timer.deadline == at(30_000)

    send(coordinator, {:control_tick, earlier_timer.token})
    assert Coordinator.control_timer(coordinator) == reconciliation_timer
  end

  test "lease renewal and repeated control ticks replace rather than accumulate timer ownership" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_runtime_ms: 100_000})

    {coordinator, _supervisor} =
      start_coordinator(fixture,
        scenario: :hanging,
        notify: self(),
        automatic_timers: true,
        control_tick_ms: 30_000
      )

    assert {:ok, %{status: :accepted}} = Coordinator.tick(coordinator)
    assert_receive {:agent_started, _}
    before_renewal = Coordinator.control_timer(coordinator)
    assert before_renewal.deadline == at(10_000)

    assert [%{action: :renewed}] = Coordinator.advance(coordinator, at(10_000))
    after_renewal = Coordinator.control_timer(coordinator)
    refute after_renewal.ref == before_renewal.ref
    assert after_renewal.deadline == at(20_000)
    assert Process.read_timer(before_renewal.ref) == false

    send(coordinator, {:control_tick, before_renewal.token})
    assert Coordinator.control_timer(coordinator) == after_renewal
  end

  test "idle periodic control ticks retain only the bounded reconciliation timer" do
    fixture = ready_fixture()

    {coordinator, _supervisor} =
      start_coordinator(fixture, automatic_timers: true, control_tick_ms: 10_000)

    first = Coordinator.control_timer(coordinator)
    assert first.deadline == at(10_000)
    send(coordinator, {:control_tick, first.token})
    second = Coordinator.control_timer(coordinator)
    refute second.ref == first.ref
    assert Process.read_timer(first.ref) == false

    send(coordinator, {:control_tick, second.token})
    third = Coordinator.control_timer(coordinator)
    refute third.ref == second.ref
    assert Process.read_timer(second.ref) == false
    assert third.deadline == at(10_000)
  end

  test "execution event replay is idempotent and semantic changes conflict" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {:ok, claim} = TaskStore.claim_next(claim_attrs(fixture, "event-replay"))
    event = usage_event(1, %{agent_turns: 1})
    attrs = event_attrs(fixture, at(1))

    assert {:ok, %{idempotent?: false}} = TaskStore.record_event(claim, event, attrs)

    later_observation = %{attrs | observed_at: at(2)}
    assert {:ok, %{idempotent?: true}} = TaskStore.record_event(claim, event, later_observation)

    assert {:error, :idempotency_conflict} =
             TaskStore.record_event(claim, %{event | payload: %{changed: true}}, attrs)

    assert Repo.aggregate(ExecutionEvent, :count) == 1
    assert Repo.aggregate(UsageEntry, :count) == 1
  end

  test "completion replay is idempotent and rejects changed accepted input" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {:ok, claim} = TaskStore.claim_next(claim_attrs(fixture, "finish-replay"))
    attrs = finish_attrs(fixture, "finish-replay", at(1))

    assert {:ok, %{idempotent?: false}} = TaskStore.finish(claim, :success, attrs)
    assert {:ok, %{idempotent?: true}} = TaskStore.finish(claim, :success, attrs)

    assert {:error, :idempotency_conflict} =
             TaskStore.finish(claim, :success, %{attrs | reason: "changed"})

    assert Repo.aggregate(ExecutionEvent, :count) == 1
  end

  defp ready_fixture do
    fixture = domain_fixture()
    {:ok, %{task: task}} = transition(fixture.task, fixture.system_actor, "SPECIFIED", 1)
    {:ok, %{task: task}} = transition(task, fixture.system_actor, "PLANNED", 2)
    {:ok, %{task: task}} = transition(task, fixture.system_actor, "READY", 3)
    %{fixture | task: task}
  end

  defp claim_attrs(fixture, suffix, occurred_at \\ @execution_time) do
    %{
      worker_id: "coordinator-test",
      actor_id: fixture.system_actor.id,
      backend: "fake",
      occurred_at: occurred_at,
      expires_at: DateTime.add(occurred_at, 60, :second),
      correlation_id: uuid(),
      idempotency_key: "dispatch:#{suffix}",
      dispatch_input: %{}
    }
  end

  defp retry_claim_attrs(fixture, suffix, occurred_at) do
    fixture
    |> claim_attrs(suffix, occurred_at)
    |> Map.put(:expires_at, DateTime.add(occurred_at, 60, :second))
  end

  defp finish_attrs(fixture, suffix, occurred_at) do
    %{
      actor_id: fixture.system_actor.id,
      occurred_at: occurred_at,
      correlation_id: uuid(),
      idempotency_key: "finish:#{suffix}",
      reason: suffix
    }
  end

  defp event_attrs(fixture, observed_at) do
    %{actor_id: fixture.system_actor.id, correlation_id: uuid(), observed_at: observed_at}
  end

  defp start_coordinator(fixture, backend_options) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    coordinator_keys = [
      :agent_backend,
      :now_fn,
      :automatic_timers,
      :control_tick_ms,
      :lease_ttl_ms,
      :lease_renewal_interval_ms,
      :reconcile_on_start
    ]

    {:ok, pid} =
      Coordinator.start_link(
        task_store: TaskStore,
        agent_backend: Keyword.get(backend_options, :agent_backend, Agent),
        workspace_backend: Workspace,
        sandbox_backend: Sandbox,
        task_supervisor: task_supervisor,
        actor_id: fixture.system_actor.id,
        worker_id: "coordinator-test",
        backend_name: "fake",
        lease_ttl_ms: Keyword.get(backend_options, :lease_ttl_ms, 30_000),
        lease_renewal_interval_ms:
          Keyword.get(backend_options, :lease_renewal_interval_ms, 10_000),
        control_tick_ms: Keyword.get(backend_options, :control_tick_ms, 10_000),
        now_fn: Keyword.get(backend_options, :now_fn, fn -> @execution_time end),
        automatic_timers: Keyword.get(backend_options, :automatic_timers, false),
        backend_options: Keyword.drop(backend_options, coordinator_keys),
        reconcile_on_start: Keyword.get(backend_options, :reconcile_on_start, false)
      )

    {pid, task_supervisor}
  end

  defp dispatch_and_wait(coordinator, opts \\ []) do
    assert {:ok, %{status: :accepted}} = Coordinator.tick(coordinator, opts)
    assert {:ok, [completion]} = Coordinator.await_idle(coordinator)
    completion
  end

  defp usage_event(sequence, usage, occurred_at \\ DateTime.add(@execution_time, 1, :millisecond)) do
    %Event{
      id: uuid(),
      sequence: sequence,
      kind: :usage,
      occurred_at: occurred_at,
      payload: %{source: "deterministic-fake"},
      usage: usage
    }
  end

  defp provider_retry_total(task_id) do
    Repo.one(
      from usage in UsageEntry,
        where: usage.task_id == ^task_id and usage.metric == "provider_retries",
        select: coalesce(sum(usage.quantity), 0)
    )
  end

  defp runtime_total(task_id) do
    Repo.one(
      from usage in UsageEntry,
        where: usage.task_id == ^task_id and usage.metric == "runtime_ms",
        select: coalesce(sum(usage.quantity), 0)
    )
  end

  defp claim_with_session(fixture, suffix, usage \\ %{}) do
    attrs =
      fixture
      |> claim_attrs(suffix)
      |> Map.put(:expires_at, at(30_000))

    {:ok, claim} = TaskStore.claim_next(attrs)
    event = %{usage_event(1, usage) | session_id: "session-#{suffix}"}
    {:ok, result} = TaskStore.record_event(claim, event, event_attrs(fixture, @execution_time))

    %{
      claim
      | attempt: result.attempt,
        runtime_deadline_at: result.attempt.runtime_deadline_at
    }
  end

  defp mutable_clock(initial_time) do
    {:ok, clock} = Elixir.Agent.start_link(fn -> initial_time end)
    {clock, fn -> Elixir.Agent.get(clock, & &1) end}
  end

  defp stop_coordinator(coordinator, supervisor) do
    Process.unlink(coordinator)
    ref = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^ref, :process, ^coordinator, :killed}
    Supervisor.stop(supervisor)
  end

  defp at(milliseconds), do: DateTime.add(@execution_time, milliseconds, :millisecond)

  defp drain_boundary_messages do
    receive do
      :workspace_prepare -> drain_boundary_messages()
      :sandbox_prepare -> drain_boundary_messages()
      :workspace_release -> drain_boundary_messages()
      :sandbox_release -> drain_boundary_messages()
      {:agent_started, _} -> drain_boundary_messages()
    after
      0 -> :ok
    end
  end
end
