defmodule Sxf.Execution.CoordinatorTest do
  use Sxf.DataCase, async: false

  alias Sxf.Execution.{Claim, Coordinator, Event}
  alias Sxf.Execution.TaskStore.Ecto, as: TaskStore
  alias Sxf.ExecutionFakes.{Agent, Sandbox, Workspace}
  alias Sxf.Repo
  alias Sxf.Tasks.Task, as: DomainTask

  alias Sxf.Tasks.{
    Blocker,
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

  test "claim, attempt, lease, and transition are atomic and dispatch replay is idempotent" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    attrs = claim_attrs(fixture, "atomic")

    assert {:ok, %Claim{} = first} = TaskStore.claim_next(attrs)
    assert {:ok, %Claim{} = replay} = TaskStore.claim_next(attrs)
    assert replay.attempt.id == first.attempt.id
    assert replay.lease.id == first.lease.id

    assert {:error, :idempotency_conflict} =
             TaskStore.claim_next(%{
               attrs
               | expires_at: DateTime.add(attrs.expires_at, 1, :second)
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

  test "successful execution persists events and usage, releases the lease, and advances to CI_RUNNING" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    event = usage_event(1, %{agent_turns: 1, runtime_ms: 5, cost_microusd: 10})
    coordinator = start_coordinator(fixture, events: [event])

    assert {:ok, %{outcome: %{outcome: :success}}} = Coordinator.tick(coordinator)
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
    test "#{scenario} produces an explicit durable outcome" do
      fixture = ready_fixture()
      budget_fixture(fixture.task)
      coordinator = start_coordinator(fixture, scenario: unquote(scenario))

      assert {:ok, %{outcome: %{outcome: unquote(scenario)}}} = Coordinator.tick(coordinator)
      assert Repo.get!(DomainTask, fixture.task.id).state == unquote(state)
      assert Repo.get_by!(TaskAttempt, task_id: fixture.task.id).status == unquote(attempt_status)
      assert Repo.get_by!(WorkerLease, task_id: fixture.task.id).status == "released"
    end
  end

  test "backend unavailability consumes retry budget and persists a retry decision" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 2})
    coordinator = start_coordinator(fixture, scenario: :unavailable)

    assert {:ok, %{outcome: %{outcome: :backend_unavailable}}} = Coordinator.tick(coordinator)
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
    assert Repo.get_by!(Blocker, task_id: fixture.task.id).kind == "external_failure"
    assert Repo.get_by!(RetrySchedule, task_id: fixture.task.id).status == "scheduled"

    assert Repo.get_by!(UsageEntry, task_id: fixture.task.id, metric: "provider_retries").quantity ==
             1
  end

  test "workspace backend unavailability is contained behind the contract" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 2})
    coordinator = start_coordinator(fixture, workspace: :unavailable, notify: self())

    assert {:ok, %{outcome: %{outcome: :backend_unavailable}}} = Coordinator.tick(coordinator)
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
    test "#{metric} ceiling blocks the task durably" do
      fixture = ready_fixture()
      budget_fixture(fixture.task, %{unquote(:"max_#{metric}") => unquote(limit)})
      event = usage_event(1, %{unquote(metric) => unquote(limit)})
      coordinator = start_coordinator(fixture, events: [event])

      assert {:ok, %{outcome: %{outcome: :deterministic_failure}}} =
               Coordinator.tick(coordinator)

      assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
      assert Repo.get_by!(Blocker, task_id: fixture.task.id).kind == unquote(blocker_kind)

      assert Repo.get_by!(UsageEntry,
               task_id: fixture.task.id,
               metric: unquote(to_string(metric))
             ).quantity ==
               unquote(limit)
    end
  end

  test "provider retry ceiling creates an exhausted durable retry" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 1})
    coordinator = start_coordinator(fixture, scenario: :unavailable)

    assert {:ok, _} = Coordinator.tick(coordinator)
    assert Repo.get_by!(RetrySchedule, task_id: fixture.task.id).status == "exhausted"
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
  end

  test "worker event payload cannot raise a durable budget ceiling" do
    fixture = ready_fixture()
    budget = budget_fixture(fixture.task, %{max_agent_turns: 1})

    event =
      usage_event(1, %{agent_turns: 1})
      |> Map.put(:payload, %{requested_max_agent_turns: 10_000})

    coordinator = start_coordinator(fixture, events: [event])
    assert {:ok, _} = Coordinator.tick(coordinator)
    assert Repo.get!(Sxf.Tasks.Budget, budget.id).max_agent_turns == 1
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
  end

  test "zero repair and provider-retry ceilings do not prohibit the initial attempt" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_repair_cycles: 0, max_provider_retries: 0})
    coordinator = start_coordinator(fixture, scenario: :success)

    assert {:ok, %{outcome: %{outcome: :success}}} = Coordinator.tick(coordinator)
    assert Repo.get!(DomainTask, fixture.task.id).state == "CI_RUNNING"
  end

  test "a scheduled retry is claimed from the ledger after its durable due time" do
    fixture = ready_fixture()
    budget_fixture(fixture.task, %{max_provider_retries: 2})
    coordinator = start_coordinator(fixture, scenario: :unavailable)
    assert {:ok, _} = Coordinator.tick(coordinator)
    retry = Repo.get_by!(RetrySchedule, task_id: fixture.task.id)

    attrs =
      fixture
      |> claim_attrs("retry-resume", retry.due_at)
      |> Map.put(:expires_at, DateTime.add(retry.due_at, 60, :second))

    assert {:ok, %Claim{} = claim} = TaskStore.claim_next(attrs)
    assert claim.attempt.sequence == 2
    assert Repo.get!(RetrySchedule, retry.id).status == "fired"
    assert Repo.get!(DomainTask, fixture.task.id).state == "IMPLEMENTING"
  end

  test "lease renewal is durable, extending, and fully idempotent" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {:ok, claim} = TaskStore.claim_next(claim_attrs(fixture, "renew"))
    renewed_at = DateTime.add(@execution_time, 10, :second)
    expires_at = DateTime.add(@execution_time, 120, :second)
    attrs = %{renewed_at: renewed_at, expires_at: expires_at, idempotency_key: "renewal:1"}

    assert {:ok, %{idempotent?: false, lease: lease}} = TaskStore.renew_lease(claim, attrs)
    assert lease.expires_at == expires_at
    assert {:ok, %{idempotent?: true}} = TaskStore.renew_lease(claim, attrs)

    assert {:error, :idempotency_conflict} =
             TaskStore.renew_lease(claim, %{
               attrs
               | expires_at: DateTime.add(expires_at, 1, :second)
             })

    assert Repo.aggregate(LeaseRenewal, :count) == 1
  end

  test "expired lease reconciliation marks the attempt lost, blocks, and schedules recovery" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    attrs = claim_attrs(fixture, "expired")
    {:ok, claim} = TaskStore.claim_next(attrs)
    observed_at = DateTime.add(attrs.expires_at, 1, :millisecond)

    assert [%{idempotent?: false}] =
             TaskStore.reconcile_expired(observed_at, fixture.system_actor.id, uuid())

    assert Repo.get!(WorkerLease, claim.lease.id).status == "expired"
    assert Repo.get!(TaskAttempt, claim.attempt.id).status == "lost"
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
    assert Repo.get_by!(RetrySchedule, task_id: fixture.task.id).status == "scheduled"
    assert [] = TaskStore.reconcile_expired(observed_at, fixture.system_actor.id, uuid())
  end

  test "a restarted coordinator reconciles an interrupted active attempt from durable state" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    first = start_coordinator(fixture, scenario: :blocking, notify: self())
    caller = spawn(fn -> Coordinator.tick(first, timeout: 20_000) end)
    assert_receive {:agent_started, ^first}, 2_000
    Process.unlink(first)
    Process.exit(first, :kill)
    ref = Process.monitor(caller)
    assert_receive {:DOWN, ^ref, :process, ^caller, _reason}, 2_000

    second = start_coordinator(fixture, inspect: :missing)
    assert %{interrupted: [_]} = Coordinator.reconcile(second)
    assert Repo.get!(DomainTask, fixture.task.id).state == "BLOCKED"
    assert Repo.get_by!(TaskAttempt, task_id: fixture.task.id).status == "lost"
    assert Repo.get_by!(WorkerLease, task_id: fixture.task.id).status == "lost"
    assert Repo.get_by!(RetrySchedule, task_id: fixture.task.id).status == "scheduled"
  end

  test "events from an expired fencing token are rejected" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    attrs = claim_attrs(fixture, "stale")
    {:ok, claim} = TaskStore.claim_next(attrs)
    observed_at = DateTime.add(attrs.expires_at, 1, :millisecond)
    TaskStore.reconcile_expired(observed_at, fixture.system_actor.id, uuid())

    event = usage_event(1, %{agent_turns: 1}, observed_at)

    assert {:error, :stale_backend_event} =
             TaskStore.record_event(claim, event, %{
               actor_id: fixture.system_actor.id,
               correlation_id: uuid()
             })
  end

  test "execution event replay is idempotent and semantic changes conflict" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {:ok, claim} = TaskStore.claim_next(claim_attrs(fixture, "event-replay"))
    correlation_id = uuid()
    event = usage_event(1, %{agent_turns: 1})
    attrs = %{actor_id: fixture.system_actor.id, correlation_id: correlation_id}

    assert {:ok, %{idempotent?: false}} = TaskStore.record_event(claim, event, attrs)
    assert {:ok, %{idempotent?: true}} = TaskStore.record_event(claim, event, attrs)

    assert {:error, :idempotency_conflict} =
             TaskStore.record_event(claim, %{event | payload: %{changed: true}}, attrs)

    assert Repo.aggregate(ExecutionEvent, :count) == 1
    assert Repo.aggregate(UsageEntry, :count) == 1
  end

  test "completion replay is idempotent and rejects changed accepted input" do
    fixture = ready_fixture()
    budget_fixture(fixture.task)
    {:ok, claim} = TaskStore.claim_next(claim_attrs(fixture, "finish-replay"))

    attrs = %{
      actor_id: fixture.system_actor.id,
      occurred_at: DateTime.add(@execution_time, 1, :millisecond),
      correlation_id: uuid(),
      idempotency_key: "finish-replay",
      reason: "complete once"
    }

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
      idempotency_key: "dispatch:#{suffix}"
    }
  end

  defp start_coordinator(fixture, backend_options) do
    {:ok, pid} =
      Coordinator.start_link(
        task_store: TaskStore,
        agent_backend: Agent,
        workspace_backend: Workspace,
        sandbox_backend: Sandbox,
        actor_id: fixture.system_actor.id,
        worker_id: "coordinator-test",
        backend_name: "fake",
        now_fn: fn -> @execution_time end,
        backend_options: backend_options,
        reconcile_on_start: false
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
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
end
