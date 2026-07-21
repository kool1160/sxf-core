defmodule Sxf.Tasks do
  @moduledoc """
  Durable task-domain commands and restart queries.

  Every lifecycle command writes the append-only transition event and the task projection in one
  database transaction. Callers supply timestamps, correlations, and idempotency keys so recovery
  and tests never depend on process memory or wall-clock sleeps.
  """

  import Ecto.Query

  alias Sxf.Repo
  alias Sxf.Tasks.Actor
  alias Sxf.Tasks.Blocker
  alias Sxf.Tasks.Budget
  alias Sxf.Tasks.EventEvidenceReference
  alias Sxf.Tasks.EvidenceReference
  alias Sxf.Tasks.ExternalActionOutboxReference
  alias Sxf.Tasks.HumanDecision
  alias Sxf.Tasks.RetrySchedule
  alias Sxf.Tasks.StateMachine
  alias Sxf.Tasks.Task
  alias Sxf.Tasks.TaskAttempt
  alias Sxf.Tasks.TransitionEvent
  alias Sxf.Tasks.UsageEntry
  alias Sxf.Tasks.WorkerLease

  @type command_result ::
          {:ok, %{task: %Task{}, event: %TransitionEvent{}, idempotent?: boolean()}}
          | {:error, term()}

  @doc "Creates a DISCOVERED task and its creation event atomically. A caller-provided task ID is required."
  @spec create_task(map()) :: command_result()
  def create_task(attrs) do
    with :ok <-
           require_keys(
             attrs,
             command_keys() ++ [:id, :project_id, :repository_registration_id, :title]
           ),
         :ok <- validate_command(attrs) do
      fingerprint = creation_fingerprint(attrs)

      Repo.transaction(fn ->
        case Repo.get(Task, attrs.id) do
          nil -> create_new_task(attrs, fingerprint)
          task -> replay_creation(task, attrs.idempotency_key, fingerprint)
        end
      end)
      |> flatten_transaction()
    end
  end

  @doc "Applies one legal transition and attaches finalized evidence references in the same transaction."
  @spec transition_task(Ecto.UUID.t(), map()) :: command_result()
  def transition_task(task_id, attrs) do
    with :ok <- require_keys(attrs, command_keys() ++ [:resulting_state]),
         :ok <- validate_command(attrs) do
      Repo.transaction(fn -> do_transition(task_id, attrs) end)
      |> flatten_transaction()
    end
  end

  @doc "Creates a provider-independent attempt idempotently."
  def create_attempt(attrs) do
    required = [:task_id, :sequence, :idempotency_key]

    with :ok <- require_keys(attrs, required) do
      attrs = Map.put(attrs, :request_fingerprint, attempt_fingerprint(attrs))

      Repo.transaction(fn -> do_create_attempt(attrs) end)
      |> flatten_transaction()
    end
  end

  @doc "Persists a retry deadline; no process timer is authoritative."
  def schedule_retry(attrs) do
    required = [
      :task_id,
      :sequence,
      :due_at,
      :reason,
      :resume_state,
      :correlation_id,
      :idempotency_key
    ]

    with :ok <- require_keys(attrs, required) do
      attrs = Map.put(attrs, :request_fingerprint, retry_fingerprint(attrs))

      Repo.transaction(fn -> do_schedule_retry(attrs) end)
      |> flatten_transaction()
    end
  end

  @doc "Records an explicit human decision idempotently after validating actor authority."
  def record_human_decision(attrs) do
    required = [
      :task_id,
      :actor_id,
      :kind,
      :decision,
      :reason,
      :occurred_at,
      :correlation_id,
      :idempotency_key,
      :target_type,
      :target_id,
      :target_action
    ]

    with :ok <- require_keys(attrs, required) do
      request_fingerprint = decision_fingerprint(attrs)

      Repo.transaction(fn ->
        actor = Repo.get(Actor, attrs.actor_id) || Repo.rollback(:actor_not_found)

        if actor.kind != "human" do
          Repo.rollback(:human_actor_required)
        end

        validate_decision_target(attrs)

        case Repo.get_by(HumanDecision,
               task_id: attrs.task_id,
               idempotency_key: attrs.idempotency_key
             ) do
          nil ->
            %HumanDecision{}
            |> HumanDecision.changeset(Map.put(attrs, :request_fingerprint, request_fingerprint))
            |> Repo.insert()
            |> unwrap_or_rollback()
            |> then(&%{decision: &1, idempotent?: false})

          %HumanDecision{} = decision ->
            if decision.request_fingerprint == request_fingerprint do
              %{decision: decision, idempotent?: true}
            else
              Repo.rollback(:idempotency_conflict)
            end
        end
      end)
      |> flatten_transaction()
    end
  end

  @doc "Returns retry rows that were durably due at the supplied observation time."
  def due_retries(%DateTime{} = observed_at) do
    RetrySchedule
    |> where([retry], retry.status == "scheduled" and retry.due_at <= ^observed_at)
    |> order_by([retry], asc: retry.due_at, asc: retry.sequence, asc: retry.id)
    |> Repo.all()
  end

  @doc "Returns task transition history in its authoritative, gap-free per-task sequence."
  def task_history(task_id) do
    Repo.all(
      from event in TransitionEvent,
        where: event.task_id == ^task_id,
        order_by: [asc: event.sequence]
    )
  end

  @doc "Returns the durable inputs a scheduler must reconcile after process restart."
  def restart_snapshot(%DateTime{} = observed_at) do
    nonterminal = StateMachine.nonterminal_states()

    %{
      tasks: Repo.all(from task in Task, where: task.state in ^nonterminal, order_by: task.id),
      due_retries: due_retries(observed_at),
      stale_leases:
        Repo.all(
          from lease in WorkerLease,
            where: lease.status == "active" and lease.expires_at <= ^observed_at,
            order_by: [asc: lease.expires_at, asc: lease.id]
        ),
      pending_outbox:
        Repo.all(
          from action in ExternalActionOutboxReference,
            where:
              action.status in ["pending", "unknown"] and action.available_at <= ^observed_at,
            order_by: [asc: action.available_at, asc: action.id]
        )
    }
  end

  @doc "Creates a durable blocker and moves the task to BLOCKED atomically."
  def block_task(task_id, attrs) do
    required = command_keys() ++ [:kind]

    with :ok <- require_keys(attrs, required),
         :ok <- validate_command(attrs) do
      Repo.transaction(fn ->
        task = Repo.get(Task, task_id) || Repo.rollback(:task_not_found)

        if StateMachine.terminal?(task.state) do
          Repo.rollback(:terminal_task_cannot_be_blocked)
        end

        load_attempt(task.id, Map.get(attrs, :attempt_id))

        transition_attrs =
          attrs
          |> Map.put(:resulting_state, "BLOCKED")
          |> Map.put(:reason_code, Map.get(attrs, :reason_code, attrs.kind))

        case event_by_key(task.id, attrs.idempotency_key) do
          %TransitionEvent{} -> replay_block(task, transition_attrs)
          nil -> create_block_and_transition(task, attrs, transition_attrs)
        end
      end)
      |> flatten_transaction()
    end
  end

  defp create_block_and_transition(task, attrs, transition_attrs) do
    blocker =
      %Blocker{}
      |> Blocker.changeset(%{
        id: Map.get(attrs, :blocker_id),
        task_id: task.id,
        attempt_id: Map.get(attrs, :attempt_id),
        created_by_actor_id: attrs.actor_id,
        kind: attrs.kind,
        status: "active",
        reason: attrs.reason,
        resume_state: task.state,
        created_at: attrs.occurred_at,
        correlation_id: attrs.correlation_id,
        metadata: Map.get(attrs, :blocker_metadata, %{})
      })
      |> Repo.insert()
      |> unwrap_or_rollback()

    result = do_transition(task.id, transition_attrs)
    Map.put(result, :blocker, blocker)
  end

  defp replay_block(task, transition_attrs) do
    result = do_transition(task.id, transition_attrs)

    blocker =
      Repo.one(
        from blocker in Blocker,
          where:
            blocker.task_id == ^task.id and
              blocker.correlation_id == ^transition_attrs.correlation_id and
              blocker.kind == ^transition_attrs.reason_code and
              blocker.reason == ^transition_attrs.reason,
          order_by: [asc: blocker.inserted_at],
          limit: 1
      ) || Repo.rollback(:blocker_replay_missing)

    Map.put(result, :blocker, blocker)
  end

  @doc "Resolves one blocker. The task remains BLOCKED until a separate legal unblock command."
  def resolve_blocker(blocker_id, attrs) do
    required = [:actor_id, :occurred_at, :correlation_id, :idempotency_key]

    with :ok <- require_keys(attrs, required) do
      request_fingerprint = blocker_resolution_fingerprint(blocker_id, attrs)

      Repo.transaction(fn ->
        blocker = Repo.get(Blocker, blocker_id) || Repo.rollback(:blocker_not_found)
        validate_blocker_resolution_authority(blocker, attrs)

        case blocker.status do
          "resolved" when blocker.resolution_idempotency_key == attrs.idempotency_key ->
            if blocker.resolution_request_fingerprint == request_fingerprint do
              %{blocker: blocker, idempotent?: true}
            else
              Repo.rollback(:idempotency_conflict)
            end

          "resolved" ->
            Repo.rollback(:idempotency_conflict)

          "active" ->
            blocker
            |> Blocker.changeset(%{
              status: "resolved",
              resolved_by_actor_id: attrs.actor_id,
              resolved_at: attrs.occurred_at,
              resolution_idempotency_key: attrs.idempotency_key,
              resolution_correlation_id: attrs.correlation_id,
              resolution_human_decision_id: Map.get(attrs, :human_decision_id),
              resolution_request_fingerprint: request_fingerprint,
              metadata: Map.merge(blocker.metadata, Map.get(attrs, :metadata, %{}))
            })
            |> Repo.update()
            |> unwrap_or_rollback()
            |> then(&%{blocker: &1, idempotent?: false})
        end
      end)
      |> flatten_transaction()
    end
  end

  @doc "Records usage once and atomically blocks a nonterminal task when the limit is exhausted."
  def record_usage(attrs) do
    required = [
      :budget_id,
      :task_id,
      :actor_id,
      :metric,
      :quantity,
      :occurred_at,
      :correlation_id,
      :idempotency_key
    ]

    with :ok <- require_keys(attrs, required) do
      attrs = Map.put(attrs, :request_fingerprint, usage_fingerprint(attrs))

      Repo.transaction(fn -> do_record_usage(attrs) end)
      |> flatten_transaction()
    end
  end

  @doc "Marks stale leases and attempts, blocks affected tasks, and schedules bounded retries."
  def reconcile_expired_leases(%DateTime{} = observed_at, actor_id, correlation_id) do
    leases =
      Repo.all(
        from lease in WorkerLease,
          where: lease.status == "active" and lease.expires_at <= ^observed_at,
          order_by: [asc: lease.expires_at, asc: lease.id]
      )

    Enum.map(leases, fn lease ->
      reconcile_one_lease(lease.id, observed_at, actor_id, correlation_id)
    end)
  end

  defp create_new_task(attrs, fingerprint) do
    registration =
      Repo.get(Sxf.Tasks.RepositoryRegistration, attrs.repository_registration_id) ||
        Repo.rollback(:repository_registration_not_found)

    if registration.project_id != attrs.project_id do
      Repo.rollback(:repository_project_mismatch)
    end

    task_attrs =
      attrs
      |> Map.take([:id, :project_id, :repository_registration_id, :title, :source_ref, :metadata])
      |> Map.put(:state, "DISCOVERED")
      |> Map.put(:last_transition_at, attrs.occurred_at)
      |> Map.put(:transition_sequence, 1)

    task =
      %Task{}
      |> Task.create_changeset(task_attrs)
      |> Repo.insert()
      |> unwrap_or_rollback()

    event_attrs = event_attrs(task, nil, attrs, "DISCOVERED", fingerprint, 1)

    event =
      %TransitionEvent{}
      |> TransitionEvent.changeset(event_attrs)
      |> Repo.insert()
      |> unwrap_or_rollback()

    %{task: task, event: event, idempotent?: false}
  end

  defp replay_creation(task, idempotency_key, fingerprint) do
    case event_by_key(task.id, idempotency_key) do
      %TransitionEvent{request_fingerprint: ^fingerprint} = event ->
        %{task: task, event: event, idempotent?: true}

      %TransitionEvent{} ->
        Repo.rollback(:idempotency_conflict)

      nil ->
        Repo.rollback(:task_id_conflict)
    end
  end

  defp do_transition(task_id, attrs) do
    fingerprint = transition_fingerprint(attrs)

    case event_by_key(task_id, attrs.idempotency_key) do
      %TransitionEvent{request_fingerprint: ^fingerprint} = event ->
        %{task: Repo.get!(Task, task_id), event: event, idempotent?: true}

      %TransitionEvent{} ->
        Repo.rollback(:idempotency_conflict)

      nil ->
        apply_new_transition(task_id, attrs, fingerprint)
    end
  end

  defp apply_new_transition(task_id, attrs, fingerprint) do
    task = Repo.get(Task, task_id) || Repo.rollback(:task_not_found)
    attrs = Map.put_new(attrs, :event_id, Sxf.Identifiers.generate())
    sequence = task.transition_sequence + 1

    if DateTime.compare(attrs.occurred_at, task.last_transition_at) == :lt do
      Repo.rollback(:out_of_order_transition)
    end

    evidence =
      load_evidence(
        task,
        Map.get(attrs, :evidence_reference_ids, []),
        Map.get(attrs, :attempt_id)
      )

    context = transition_context(task, attrs, evidence)

    case StateMachine.validate(task.state, attrs.resulting_state, context) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    event =
      %TransitionEvent{}
      |> TransitionEvent.changeset(
        event_attrs(task, task.state, attrs, attrs.resulting_state, fingerprint, sequence)
      )
      |> Repo.insert()
      |> unwrap_or_rollback()

    attach_evidence(event, evidence, attrs.occurred_at)

    task =
      task
      |> Task.transition_changeset(
        projection_attrs(task, attrs.resulting_state, attrs.occurred_at, sequence)
      )
      |> Repo.update()
      |> unwrap_or_rollback()

    %{task: task, event: event, idempotent?: false}
  end

  defp transition_context(task, attrs, evidence) do
    attempt = load_attempt(task.id, Map.get(attrs, :attempt_id))
    actor = Repo.get(Actor, attrs.actor_id) || Repo.rollback(:actor_not_found)

    decision =
      load_decision(
        task.id,
        Map.get(attrs, :human_decision_id),
        "transition",
        attrs.event_id,
        attrs.resulting_state
      )

    occurred_at = attrs.occurred_at

    %{
      active_blocker?: active_blockers?(task.id),
      blockers_resolved?: not active_blockers?(task.id),
      resume_state: task.resume_state,
      attempt_active?: attempt != nil and attempt.status == "running",
      lease_active?: active_lease?(task.id, attempt, occurred_at),
      budget_available?: budget_available?(task.id, attempt && attempt.id),
      repair_budget_available?: repair_budget_available?(task.id, attempt && attempt.id),
      check_evidence?: finalized_evidence?(evidence, "check_result"),
      verification_evidence?: finalized_evidence?(evidence, "verification_result"),
      deploy_approved?: approved_decision?(decision, "deploy_approval"),
      reopen_approved?: approved_decision?(decision, "reopen"),
      cancellation_authorized?: cancellation_authorized?(actor, decision),
      terminal_failure?:
        actor.kind in ["system", "human"] and
          Map.get(attrs, :reason_code) in ["terminal_failure", "unrecoverable"]
    }
  end

  defp projection_attrs(task, resulting_state, occurred_at, sequence) do
    terminal? = StateMachine.terminal?(resulting_state)

    %{
      state: resulting_state,
      resume_state:
        cond do
          resulting_state == "BLOCKED" -> task.state
          task.state == "BLOCKED" -> nil
          terminal? -> nil
          true -> task.resume_state
        end,
      terminal_at: if(terminal?, do: occurred_at, else: nil),
      last_transition_at: occurred_at,
      transition_sequence: sequence
    }
  end

  defp event_attrs(task, prior_state, attrs, resulting_state, fingerprint, sequence) do
    %{
      id: Map.get(attrs, :event_id),
      task_id: task.id,
      sequence: sequence,
      attempt_id: Map.get(attrs, :attempt_id),
      actor_id: attrs.actor_id,
      prior_state: prior_state,
      resulting_state: resulting_state,
      reason: attrs.reason,
      reason_code: Map.get(attrs, :reason_code),
      occurred_at: attrs.occurred_at,
      correlation_id: attrs.correlation_id,
      idempotency_key: attrs.idempotency_key,
      request_fingerprint: fingerprint,
      human_decision_id: Map.get(attrs, :human_decision_id),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  defp load_evidence(_task, [], _attempt_id), do: []

  defp load_evidence(task, ids, attempt_id) when is_list(ids) do
    unique_ids = Enum.uniq(ids)

    evidence =
      Repo.all(from item in EvidenceReference, where: item.id in ^unique_ids, order_by: item.id)

    cond do
      length(evidence) != length(unique_ids) ->
        Repo.rollback(:evidence_not_found)

      Enum.any?(evidence, &(&1.task_id != task.id)) ->
        Repo.rollback(:evidence_task_mismatch)

      attempt_id && Enum.any?(evidence, &(&1.attempt_id not in [nil, attempt_id])) ->
        Repo.rollback(:evidence_attempt_mismatch)

      true ->
        evidence
    end
  end

  defp load_attempt(_task_id, nil), do: nil

  defp load_attempt(task_id, attempt_id) do
    case Repo.get(TaskAttempt, attempt_id) do
      %TaskAttempt{task_id: ^task_id} = attempt -> attempt
      %TaskAttempt{} -> Repo.rollback(:attempt_task_mismatch)
      nil -> Repo.rollback(:attempt_not_found)
    end
  end

  defp load_decision(_task_id, nil, _target_type, _target_id, _target_action), do: nil

  defp load_decision(task_id, decision_id, target_type, target_id, target_action) do
    case Repo.get(HumanDecision, decision_id) do
      %HumanDecision{task_id: ^task_id} = decision ->
        case Repo.get(Actor, decision.actor_id) do
          %Actor{kind: "human"} ->
            if decision.target_type == target_type and decision.target_id == target_id and
                 decision.target_action == target_action do
              decision
            else
              Repo.rollback(:decision_scope_mismatch)
            end

          _ ->
            Repo.rollback(:invalid_human_decision_actor)
        end

      %HumanDecision{} ->
        Repo.rollback(:decision_task_mismatch)

      nil ->
        Repo.rollback(:decision_not_found)
    end
  end

  defp validate_blocker_resolution_authority(blocker, attrs) do
    expected_decision =
      case blocker.kind do
        kind when kind in ["budget_exhausted", "runtime_exhausted"] ->
          "budget_override"

        kind
        when kind in ["policy", "approval_required", "operator_input", "indeterminate_outcome"] ->
          "unblock"

        _ ->
          nil
      end

    decision =
      if Map.get(attrs, :human_decision_id) do
        load_decision(
          blocker.task_id,
          Map.get(attrs, :human_decision_id),
          "blocker_resolution",
          blocker.id,
          "resolve:#{blocker.kind}"
        )
      end

    if decision && decision.actor_id != attrs.actor_id do
      Repo.rollback(:decision_actor_mismatch)
    end

    if expected_decision do
      unless approved_decision?(decision, expected_decision) do
        Repo.rollback(:approved_human_decision_required)
      end
    end

    :ok
  end

  defp validate_decision_target(attrs) do
    Repo.get(Task, attrs.task_id) || Repo.rollback(:task_not_found)

    if evidence_id = Map.get(attrs, :evidence_reference_id) do
      case Repo.get(EvidenceReference, evidence_id) do
        %EvidenceReference{task_id: task_id} when task_id == attrs.task_id -> :ok
        %EvidenceReference{} -> Repo.rollback(:evidence_task_mismatch)
        nil -> Repo.rollback(:evidence_not_found)
      end
    end

    case attrs.target_type do
      "transition" ->
        unless Sxf.Identifiers.valid?(attrs.target_id) and
                 attrs.target_action in StateMachine.states() do
          Repo.rollback(:invalid_decision_target)
        end

      "blocker_resolution" ->
        case Repo.get(Blocker, attrs.target_id) do
          %Blocker{task_id: task_id, kind: kind} when task_id == attrs.task_id ->
            if attrs.target_action == "resolve:#{kind}" do
              :ok
            else
              Repo.rollback(:invalid_decision_target)
            end

          %Blocker{task_id: task_id} when task_id != attrs.task_id ->
            Repo.rollback(:decision_target_task_mismatch)

          %Blocker{} ->
            Repo.rollback(:invalid_decision_target)

          nil ->
            Repo.rollback(:decision_target_not_found)
        end

      _ ->
        Repo.rollback(:invalid_decision_target)
    end

    :ok
  end

  defp attach_evidence(_event, [], _occurred_at), do: :ok

  defp attach_evidence(event, evidence, occurred_at) do
    Enum.each(evidence, fn item ->
      %EventEvidenceReference{}
      |> EventEvidenceReference.changeset(%{
        task_id: event.task_id,
        transition_event_id: event.id,
        evidence_reference_id: item.id,
        attached_at: occurred_at
      })
      |> Repo.insert()
      |> unwrap_or_rollback()
    end)
  end

  defp active_blockers?(task_id) do
    Repo.exists?(
      from blocker in Blocker, where: blocker.task_id == ^task_id and blocker.status == "active"
    )
  end

  defp active_lease?(_task_id, nil, _occurred_at), do: false

  defp active_lease?(task_id, attempt, occurred_at) do
    Repo.exists?(
      from lease in WorkerLease,
        where:
          lease.task_id == ^task_id and lease.attempt_id == ^attempt.id and
            lease.status == "active" and lease.expires_at > ^occurred_at
    )
  end

  defp budget_available?(task_id, attempt_id) do
    budgets = applicable_budgets(task_id, attempt_id)
    budgets != [] and Enum.all?(budgets, &budget_has_capacity?/1)
  end

  defp repair_budget_available?(task_id, attempt_id) do
    applicable_budgets(task_id, attempt_id)
    |> Enum.any?(fn budget ->
      is_integer(budget.max_repair_cycles) and
        usage_total(budget.id, "repair_cycles") < budget.max_repair_cycles
    end)
  end

  defp applicable_budgets(task_id, nil) do
    Repo.all(
      from budget in Budget,
        where:
          budget.task_id == ^task_id and budget.status == "active" and is_nil(budget.attempt_id)
    )
  end

  defp applicable_budgets(task_id, attempt_id) do
    Repo.all(
      from budget in Budget,
        where:
          budget.task_id == ^task_id and budget.status == "active" and
            (is_nil(budget.attempt_id) or budget.attempt_id == ^attempt_id)
    )
  end

  defp budget_has_capacity?(budget) do
    Enum.all?(~w(cost_microusd runtime_ms agent_turns), fn metric ->
      case limit_for(budget, metric) do
        nil -> true
        limit -> usage_total(budget.id, metric) < limit
      end
    end)
  end

  defp usage_total(budget_id, metric) do
    Repo.one(
      from usage in UsageEntry,
        where: usage.budget_id == ^budget_id and usage.metric == ^metric,
        select: coalesce(sum(usage.quantity), 0)
    )
  end

  defp finalized_evidence?(evidence, kind) do
    Enum.any?(evidence, &(&1.kind == kind and not is_nil(&1.finalized_at)))
  end

  defp approved_decision?(%HumanDecision{kind: kind, decision: "approved"}, kind), do: true
  defp approved_decision?(_decision, _kind), do: false

  defp cancellation_authorized?(%Actor{kind: kind}, _decision) when kind in ["system", "human"],
    do: true

  defp cancellation_authorized?(_actor, decision), do: approved_decision?(decision, "cancel")

  defp event_by_key(task_id, idempotency_key) do
    Repo.one(
      from event in TransitionEvent,
        where: event.task_id == ^task_id and event.idempotency_key == ^idempotency_key
    )
  end

  defp do_create_attempt(attrs) do
    case Repo.get_by(TaskAttempt, task_id: attrs.task_id, idempotency_key: attrs.idempotency_key) do
      %TaskAttempt{} = attempt ->
        if attempt.request_fingerprint == attrs.request_fingerprint do
          %{attempt: attempt, idempotent?: true}
        else
          Repo.rollback(:idempotency_conflict)
        end

      nil ->
        task = Repo.get(Task, attrs.task_id) || Repo.rollback(:task_not_found)

        unless task.state in ["READY", "CHANGES_REQUESTED", "BLOCKED"] do
          Repo.rollback(:attempt_not_allowed_in_task_state)
        end

        last_sequence =
          Repo.one(
            from attempt in TaskAttempt,
              where: attempt.task_id == ^task.id,
              select: max(attempt.sequence)
          ) || 0

        if attrs.sequence != last_sequence + 1 do
          Repo.rollback({:invalid_attempt_sequence, last_sequence + 1})
        end

        %TaskAttempt{}
        |> TaskAttempt.changeset(attrs)
        |> Repo.insert()
        |> unwrap_or_rollback()
        |> then(&%{attempt: &1, idempotent?: false})
    end
  end

  defp do_schedule_retry(attrs) do
    case Repo.get_by(RetrySchedule,
           task_id: attrs.task_id,
           idempotency_key: attrs.idempotency_key
         ) do
      %RetrySchedule{} = retry ->
        if retry.request_fingerprint == attrs.request_fingerprint do
          %{retry: retry, idempotent?: true}
        else
          Repo.rollback(:idempotency_conflict)
        end

      nil ->
        task = Repo.get(Task, attrs.task_id) || Repo.rollback(:task_not_found)
        load_attempt(task.id, Map.get(attrs, :attempt_id))

        if StateMachine.terminal?(task.state) do
          Repo.rollback(:terminal_task_rejects_retry)
        end

        expected_resume_state =
          if task.state == "BLOCKED", do: task.resume_state, else: task.state

        if attrs.resume_state != expected_resume_state do
          Repo.rollback({:retry_resume_state_mismatch, expected_resume_state})
        end

        %RetrySchedule{}
        |> RetrySchedule.changeset(attrs)
        |> Repo.insert()
        |> unwrap_or_rollback()
        |> then(&%{retry: &1, idempotent?: false})
    end
  end

  defp do_record_usage(attrs) do
    case Repo.get_by(UsageEntry,
           budget_id: attrs.budget_id,
           idempotency_key: attrs.idempotency_key
         ) do
      %UsageEntry{} = entry ->
        if entry.request_fingerprint == attrs.request_fingerprint do
          %{
            usage: entry,
            exhausted?: Repo.get!(Budget, attrs.budget_id).status == "exhausted",
            idempotent?: true
          }
        else
          Repo.rollback(:idempotency_conflict)
        end

      nil ->
        budget = Repo.get(Budget, attrs.budget_id) || Repo.rollback(:budget_not_found)

        if budget.task_id != attrs.task_id do
          Repo.rollback(:budget_task_mismatch)
        end

        if budget.attempt_id && budget.attempt_id != Map.get(attrs, :attempt_id) do
          Repo.rollback(:budget_attempt_mismatch)
        end

        task = Repo.get!(Task, attrs.task_id)
        load_attempt(task.id, Map.get(attrs, :attempt_id))

        if StateMachine.terminal?(task.state) do
          Repo.rollback(:terminal_task_rejects_usage)
        end

        entry =
          %UsageEntry{}
          |> UsageEntry.changeset(attrs)
          |> Repo.insert()
          |> unwrap_or_rollback()

        exhausted? = not metric_has_capacity?(budget, attrs.metric)

        if exhausted? do
          budget
          |> Budget.changeset(%{status: "exhausted"})
          |> Repo.update()
          |> unwrap_or_rollback()

          block_for_exhaustion(task, budget, entry, attrs)
        end

        %{usage: entry, exhausted?: exhausted?, idempotent?: false}
    end
  end

  defp block_for_exhaustion(%Task{state: "BLOCKED"}, _budget, _entry, _attrs), do: :ok

  defp block_for_exhaustion(task, budget, entry, attrs) do
    kind = if attrs.metric == "runtime_ms", do: "runtime_exhausted", else: "budget_exhausted"
    reason = "#{attrs.metric} budget exhausted"

    blocker =
      %Blocker{}
      |> Blocker.changeset(%{
        task_id: task.id,
        attempt_id: Map.get(attrs, :attempt_id),
        created_by_actor_id: attrs.actor_id,
        kind: kind,
        status: "active",
        reason: reason,
        resume_state: task.state,
        created_at: attrs.occurred_at,
        correlation_id: attrs.correlation_id,
        metadata: %{budget_id: budget.id, usage_entry_id: entry.id}
      })
      |> Repo.insert()
      |> unwrap_or_rollback()

    do_transition(task.id, %{
      actor_id: attrs.actor_id,
      attempt_id: Map.get(attrs, :attempt_id),
      resulting_state: "BLOCKED",
      reason: reason,
      reason_code: kind,
      occurred_at: attrs.occurred_at,
      correlation_id: attrs.correlation_id,
      idempotency_key: "budget-exhausted:#{entry.id}",
      evidence_reference_ids: Map.get(attrs, :evidence_reference_ids, []),
      metadata: %{blocker_id: blocker.id, budget_id: budget.id, usage_entry_id: entry.id}
    })
  end

  defp reconcile_one_lease(lease_id, observed_at, actor_id, correlation_id) do
    Repo.transaction(fn ->
      lease = Repo.get!(WorkerLease, lease_id)

      cond do
        lease.status != "active" ->
          %{lease: lease, idempotent?: true}

        DateTime.compare(lease.expires_at, observed_at) == :gt ->
          Repo.rollback(:lease_not_expired)

        true ->
          lease =
            lease
            |> WorkerLease.changeset(%{status: "expired", released_at: observed_at})
            |> Repo.update()
            |> unwrap_or_rollback()

          attempt = Repo.get!(TaskAttempt, lease.attempt_id)

          attempt
          |> TaskAttempt.changeset(%{
            status: "lost",
            finished_at: observed_at,
            outcome: "lease_expired"
          })
          |> Repo.update()
          |> unwrap_or_rollback()

          task = Repo.get!(Task, lease.task_id)

          if not StateMachine.terminal?(task.state) and task.state != "BLOCKED" do
            blocker =
              %Blocker{}
              |> Blocker.changeset(%{
                task_id: task.id,
                attempt_id: attempt.id,
                created_by_actor_id: actor_id,
                kind: "lease_expired",
                status: "active",
                reason: "worker lease expired during restart reconciliation",
                resume_state: task.state,
                created_at: observed_at,
                correlation_id: correlation_id,
                metadata: %{lease_id: lease.id, worker_id: lease.worker_id}
              })
              |> Repo.insert()
              |> unwrap_or_rollback()

            do_transition(task.id, %{
              actor_id: actor_id,
              attempt_id: attempt.id,
              resulting_state: "BLOCKED",
              reason: "worker lease expired during restart reconciliation",
              reason_code: "lease_expired",
              occurred_at: observed_at,
              correlation_id: correlation_id,
              idempotency_key: "lease-expired:#{lease.id}",
              metadata: %{blocker_id: blocker.id, lease_id: lease.id}
            })

            persist_recovery_retry(task, attempt, observed_at, correlation_id, lease.id)
          end

          %{lease: lease, idempotent?: false}
      end
    end)
    |> flatten_transaction()
  end

  defp persist_recovery_retry(task, attempt, observed_at, correlation_id, lease_id) do
    sequence =
      Repo.one(
        from retry in RetrySchedule, where: retry.task_id == ^task.id, select: max(retry.sequence)
      ) || 0

    next_sequence = sequence + 1
    retry_limit_available? = retry_budget_available?(task.id, attempt.id)
    status = if retry_limit_available?, do: "scheduled", else: "exhausted"
    backoff_seconds = retry_backoff_seconds(task.id, next_sequence)

    retry_attrs = %{
      task_id: task.id,
      attempt_id: attempt.id,
      sequence: next_sequence,
      status: status,
      due_at: DateTime.add(observed_at, backoff_seconds, :second),
      reason: "recover from expired worker lease",
      resume_state: task.state,
      correlation_id: correlation_id,
      idempotency_key: "lease-retry:#{lease_id}",
      finished_at: if(status == "exhausted", do: observed_at),
      metadata: %{lease_id: lease_id, backoff_seconds: backoff_seconds}
    }

    retry_attrs = Map.put(retry_attrs, :request_fingerprint, retry_fingerprint(retry_attrs))

    %RetrySchedule{}
    |> RetrySchedule.changeset(retry_attrs)
    |> Repo.insert()
    |> unwrap_or_rollback()
  end

  defp retry_backoff_seconds(task_id, sequence) do
    base = min(trunc(:math.pow(2, max(sequence - 1, 0))) * 10, 300)
    spread = max(div(base, 5), 1)
    <<sample::unsigned-32, _rest::binary>> = :crypto.hash(:sha256, "#{task_id}:#{sequence}")
    jitter = rem(sample, spread * 2 + 1) - spread
    base |> Kernel.+(jitter) |> max(1) |> min(300)
  end

  defp retry_budget_available?(task_id, attempt_id) do
    applicable_budgets(task_id, attempt_id)
    |> Enum.any?(fn budget ->
      is_integer(budget.max_provider_retries) and
        usage_total(budget.id, "provider_retries") < budget.max_provider_retries
    end)
  end

  defp limit_for(budget, "cost_microusd"), do: budget.max_cost_microusd
  defp limit_for(budget, "runtime_ms"), do: budget.max_runtime_ms
  defp limit_for(budget, "agent_turns"), do: budget.max_agent_turns
  defp limit_for(budget, "repair_cycles"), do: budget.max_repair_cycles
  defp limit_for(budget, "provider_retries"), do: budget.max_provider_retries

  defp metric_has_capacity?(budget, metric) do
    case limit_for(budget, metric) do
      nil -> true
      limit -> usage_total(budget.id, metric) < limit
    end
  end

  defp creation_fingerprint(attrs) do
    fingerprint(%{
      command: :create_task,
      event_id: Map.get(attrs, :event_id),
      task_id: attrs.id,
      project_id: attrs.project_id,
      repository_registration_id: attrs.repository_registration_id,
      title: attrs.title,
      source_ref: Map.get(attrs, :source_ref),
      actor_id: attrs.actor_id,
      attempt_id: Map.get(attrs, :attempt_id),
      human_decision_id: Map.get(attrs, :human_decision_id),
      reason: attrs.reason,
      reason_code: Map.get(attrs, :reason_code),
      occurred_at: attrs.occurred_at,
      correlation_id: attrs.correlation_id,
      idempotency_key: attrs.idempotency_key,
      metadata: Map.get(attrs, :metadata, %{})
    })
  end

  defp transition_fingerprint(attrs) do
    fingerprint(%{
      command: :transition_task,
      event_id: Map.get(attrs, :event_id),
      resulting_state: attrs.resulting_state,
      blocker_id: Map.get(attrs, :blocker_id),
      blocker_kind: Map.get(attrs, :kind),
      blocker_metadata: Map.get(attrs, :blocker_metadata, %{}),
      actor_id: attrs.actor_id,
      attempt_id: Map.get(attrs, :attempt_id),
      human_decision_id: Map.get(attrs, :human_decision_id),
      reason: attrs.reason,
      reason_code: Map.get(attrs, :reason_code),
      occurred_at: attrs.occurred_at,
      correlation_id: attrs.correlation_id,
      idempotency_key: attrs.idempotency_key,
      evidence_reference_ids:
        attrs |> Map.get(:evidence_reference_ids, []) |> Enum.uniq() |> Enum.sort(),
      metadata: Map.get(attrs, :metadata, %{})
    })
  end

  defp attempt_fingerprint(attrs) do
    fingerprint(%{
      command: :create_attempt,
      id: Map.get(attrs, :id),
      task_id: attrs.task_id,
      sequence: attrs.sequence,
      status: Map.get(attrs, :status, "planned"),
      backend: Map.get(attrs, :backend),
      backend_session_id: Map.get(attrs, :backend_session_id),
      idempotency_key: attrs.idempotency_key,
      started_at: Map.get(attrs, :started_at),
      finished_at: Map.get(attrs, :finished_at),
      outcome: Map.get(attrs, :outcome),
      metadata: Map.get(attrs, :metadata, %{})
    })
  end

  defp retry_fingerprint(attrs) do
    fingerprint(%{
      command: :schedule_retry,
      id: Map.get(attrs, :id),
      task_id: attrs.task_id,
      attempt_id: Map.get(attrs, :attempt_id),
      sequence: attrs.sequence,
      status: Map.get(attrs, :status, "scheduled"),
      due_at: attrs.due_at,
      reason: attrs.reason,
      resume_state: attrs.resume_state,
      correlation_id: attrs.correlation_id,
      idempotency_key: attrs.idempotency_key,
      claimed_at: Map.get(attrs, :claimed_at),
      finished_at: Map.get(attrs, :finished_at),
      metadata: Map.get(attrs, :metadata, %{})
    })
  end

  defp usage_fingerprint(attrs) do
    fingerprint(%{
      command: :record_usage,
      id: Map.get(attrs, :id),
      budget_id: attrs.budget_id,
      task_id: attrs.task_id,
      attempt_id: Map.get(attrs, :attempt_id),
      actor_id: attrs.actor_id,
      metric: attrs.metric,
      quantity: attrs.quantity,
      occurred_at: attrs.occurred_at,
      correlation_id: attrs.correlation_id,
      idempotency_key: attrs.idempotency_key,
      evidence_reference_ids:
        attrs |> Map.get(:evidence_reference_ids, []) |> Enum.uniq() |> Enum.sort(),
      metadata: Map.get(attrs, :metadata, %{})
    })
  end

  defp decision_fingerprint(attrs) do
    fingerprint(%{
      command: :record_human_decision,
      id: Map.get(attrs, :id),
      task_id: attrs.task_id,
      actor_id: attrs.actor_id,
      evidence_reference_id: Map.get(attrs, :evidence_reference_id),
      kind: attrs.kind,
      decision: attrs.decision,
      reason: attrs.reason,
      occurred_at: attrs.occurred_at,
      correlation_id: attrs.correlation_id,
      idempotency_key: attrs.idempotency_key,
      target_type: attrs.target_type,
      target_id: attrs.target_id,
      target_action: attrs.target_action,
      metadata: Map.get(attrs, :metadata, %{})
    })
  end

  defp blocker_resolution_fingerprint(blocker_id, attrs) do
    fingerprint(%{
      command: :resolve_blocker,
      blocker_id: blocker_id,
      actor_id: attrs.actor_id,
      occurred_at: attrs.occurred_at,
      correlation_id: attrs.correlation_id,
      idempotency_key: attrs.idempotency_key,
      human_decision_id: Map.get(attrs, :human_decision_id),
      metadata: Map.get(attrs, :metadata, %{})
    })
  end

  defp fingerprint(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp command_keys do
    [:actor_id, :reason, :occurred_at, :correlation_id, :idempotency_key]
  end

  defp require_keys(attrs, keys) when is_map(attrs) do
    case Enum.find(keys, &(not Map.has_key?(attrs, &1) or is_nil(Map.get(attrs, &1)))) do
      nil -> :ok
      key -> {:error, {:missing_command_field, key}}
    end
  end

  defp validate_command(attrs) do
    cond do
      not is_struct(attrs.occurred_at, DateTime) ->
        {:error, {:invalid_command_field, :occurred_at}}

      not Sxf.Identifiers.valid?(attrs.correlation_id) ->
        {:error, {:invalid_command_field, :correlation_id}}

      not is_binary(attrs.reason) or String.trim(attrs.reason) == "" ->
        {:error, {:invalid_command_field, :reason}}

      not is_binary(attrs.idempotency_key) or String.trim(attrs.idempotency_key) == "" ->
        {:error, {:invalid_command_field, :idempotency_key}}

      true ->
        :ok
    end
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp flatten_transaction({:ok, result}), do: {:ok, result}
  defp flatten_transaction({:error, reason}), do: {:error, reason}
end
