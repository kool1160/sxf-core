defmodule Sxf.Execution.TaskStore.Ecto do
  @moduledoc "SQLite-backed execution authority for the SXF coordinator."

  @behaviour Sxf.Execution.TaskStore

  import Ecto.Query

  alias Sxf.Execution.{Claim, Event}
  alias Sxf.Repo
  alias Sxf.Tasks

  alias Sxf.Tasks.{
    Blocker,
    Budget,
    ExecutionEvent,
    LeaseRenewal,
    RetrySchedule,
    Task,
    TaskAttempt,
    UsageEntry,
    WorkerLease
  }

  @auto_resolvable_blockers ~w(external_failure lease_expired worker_lost)

  @impl true
  def claim_next(attrs) when is_map(attrs) do
    with :ok <-
           require_keys(attrs, [
             :worker_id,
             :actor_id,
             :backend,
             :occurred_at,
             :expires_at,
             :correlation_id,
             :idempotency_key
           ]),
         :ok <- validate_claim_times(attrs) do
      request_fingerprint = fingerprint(Map.put(attrs, :command, :claim_next))

      Repo.transaction(fn ->
        case existing_claim(attrs.idempotency_key) do
          nil -> create_claim(attrs, request_fingerprint)
          lease -> replay_claim(lease, request_fingerprint)
        end
      end)
      |> flatten()
    end
  end

  @impl true
  def renew_lease(%Claim{} = claim, attrs) when is_map(attrs) do
    with :ok <- require_keys(attrs, [:renewed_at, :expires_at, :idempotency_key]),
         :ok <- validate_renewal_times(attrs) do
      request_fingerprint =
        fingerprint(%{
          command: :renew_lease,
          task_id: claim.task.id,
          attempt_id: claim.attempt.id,
          lease_id: claim.lease.id,
          fencing_token: claim.lease.fencing_token,
          renewed_at: attrs.renewed_at,
          expires_at: attrs.expires_at,
          idempotency_key: attrs.idempotency_key
        })

      Repo.transaction(fn ->
        case Repo.get_by(LeaseRenewal,
               lease_id: claim.lease.id,
               idempotency_key: attrs.idempotency_key
             ) do
          %LeaseRenewal{request_fingerprint: ^request_fingerprint} = renewal ->
            %{renewal: renewal, lease: Repo.get!(WorkerLease, claim.lease.id), idempotent?: true}

          %LeaseRenewal{} ->
            Repo.rollback(:idempotency_conflict)

          nil ->
            lease = validate_active_lease!(claim, attrs.renewed_at)

            if DateTime.compare(attrs.expires_at, lease.expires_at) != :gt do
              Repo.rollback(:lease_renewal_must_extend_expiry)
            end

            renewal =
              %LeaseRenewal{}
              |> LeaseRenewal.changeset(%{
                task_id: lease.task_id,
                attempt_id: lease.attempt_id,
                lease_id: lease.id,
                fencing_token: lease.fencing_token,
                renewed_at: attrs.renewed_at,
                expires_at: attrs.expires_at,
                idempotency_key: attrs.idempotency_key,
                request_fingerprint: request_fingerprint
              })
              |> insert!()

            lease =
              lease
              |> WorkerLease.changeset(%{
                heartbeat_at: attrs.renewed_at,
                expires_at: attrs.expires_at
              })
              |> update!()

            %{renewal: renewal, lease: lease, idempotent?: false}
        end
      end)
      |> flatten()
    end
  end

  @impl true
  def record_event(%Claim{} = claim, %Event{} = event, attrs) when is_map(attrs) do
    with :ok <- require_keys(attrs, [:actor_id, :correlation_id]) do
      Repo.transaction(fn -> do_record_event(claim, event, attrs) end)
      |> flatten()
    end
  end

  @impl true
  def finish(%Claim{} = claim, outcome, attrs) when is_atom(outcome) and is_map(attrs) do
    with true <-
           outcome in Sxf.Execution.Result.outcomes() || {:error, :invalid_execution_outcome},
         :ok <-
           require_keys(attrs, [
             :actor_id,
             :occurred_at,
             :correlation_id,
             :idempotency_key,
             :reason
           ]) do
      Repo.transaction(fn -> do_finish(claim, outcome, attrs) end)
      |> flatten()
    end
  end

  @impl true
  def active_claims(worker_id) when is_binary(worker_id) do
    WorkerLease
    |> where([lease], lease.worker_id == ^worker_id and lease.status == "active")
    |> order_by([lease], asc: lease.acquired_at, asc: lease.id)
    |> Repo.all()
    |> Enum.map(&load_claim/1)
  end

  @impl true
  def interrupt(%Claim{} = claim, attrs) do
    with :ok <-
           require_keys(attrs, [
             :actor_id,
             :occurred_at,
             :correlation_id,
             :idempotency_key,
             :reason
           ]) do
      Repo.transaction(fn -> do_finish(claim, :interrupted, attrs) end)
      |> flatten()
    end
  end

  @impl true
  def reconcile_expired(observed_at, actor_id, correlation_id) do
    Tasks.reconcile_expired_leases(observed_at, actor_id, correlation_id)
    |> Enum.map(fn
      {:ok, result} -> result
      {:error, reason} -> %{error: reason}
    end)
  end

  defp create_claim(attrs, request_fingerprint) do
    case due_retry(attrs.occurred_at) || ready_task() do
      nil ->
        nil

      %RetrySchedule{} = retry ->
        claim_retry(retry, attrs, request_fingerprint)

      %Task{} = task ->
        claim_task(task, nil, attrs, request_fingerprint)
    end
  end

  defp ready_task do
    Task
    |> where([task], task.state == "READY")
    |> order_by([task], asc: task.last_transition_at, asc: task.id)
    |> Repo.all()
    |> Enum.find(&eligible_task?/1)
  end

  defp due_retry(observed_at) do
    RetrySchedule
    |> join(:inner, [retry], task in Task, on: task.id == retry.task_id)
    |> where(
      [retry, task],
      retry.status == "scheduled" and retry.due_at <= ^observed_at and task.state == "BLOCKED"
    )
    |> order_by([retry], asc: retry.due_at, asc: retry.sequence, asc: retry.id)
    |> Repo.all()
    |> Enum.find(fn retry ->
      Task
      |> Repo.get!(retry.task_id)
      |> eligible_retry_task?()
    end)
  end

  defp eligible_task?(task) do
    no_active_lease?(task.id) and no_active_attempt?(task.id) and budget_available?(task.id)
  end

  defp eligible_retry_task?(task) do
    active_blockers =
      Repo.all(
        from blocker in Blocker, where: blocker.task_id == ^task.id and blocker.status == "active"
      )

    active_blockers != [] and
      Enum.all?(active_blockers, &(&1.kind in @auto_resolvable_blockers)) and
      no_active_lease?(task.id) and no_active_attempt?(task.id) and budget_available?(task.id)
  end

  defp no_active_lease?(task_id) do
    not Repo.exists?(
      from lease in WorkerLease, where: lease.task_id == ^task_id and lease.status == "active"
    )
  end

  defp no_active_attempt?(task_id) do
    not Repo.exists?(
      from attempt in TaskAttempt,
        where: attempt.task_id == ^task_id and attempt.status == "running"
    )
  end

  defp claim_retry(retry, attrs, request_fingerprint) do
    task = Repo.get!(Task, retry.task_id)

    Repo.all(
      from blocker in Blocker, where: blocker.task_id == ^task.id and blocker.status == "active"
    )
    |> Enum.each(fn blocker ->
      {:ok, _} =
        Tasks.resolve_blocker(blocker.id, %{
          actor_id: attrs.actor_id,
          occurred_at: attrs.occurred_at,
          correlation_id: attrs.correlation_id,
          idempotency_key: "#{attrs.idempotency_key}:resolve:#{blocker.id}"
        })
    end)

    retry
    |> RetrySchedule.changeset(%{
      status: "fired",
      claimed_at: attrs.occurred_at,
      finished_at: attrs.occurred_at
    })
    |> update!()

    claim_task(task, retry, attrs, request_fingerprint)
  end

  defp claim_task(task, retry, attrs, request_fingerprint) do
    attempt_sequence =
      Repo.one(
        from attempt in TaskAttempt,
          where: attempt.task_id == ^task.id,
          select: max(attempt.sequence)
      ) || 0

    {:ok, %{attempt: attempt}} =
      Tasks.create_attempt(%{
        task_id: task.id,
        sequence: attempt_sequence + 1,
        status: "running",
        backend: attrs.backend,
        started_at: attrs.occurred_at,
        idempotency_key: "#{attrs.idempotency_key}:attempt",
        metadata: if(retry, do: %{retry_schedule_id: retry.id}, else: %{})
      })

    fencing_token =
      (Repo.one(
         from lease in WorkerLease,
           where: lease.task_id == ^task.id,
           select: max(lease.fencing_token)
       ) || 0) + 1

    lease =
      %WorkerLease{}
      |> WorkerLease.changeset(%{
        task_id: task.id,
        attempt_id: attempt.id,
        worker_id: attrs.worker_id,
        fencing_token: fencing_token,
        status: "active",
        acquired_at: attrs.occurred_at,
        heartbeat_at: attrs.occurred_at,
        expires_at: attrs.expires_at,
        idempotency_key: attrs.idempotency_key,
        request_fingerprint: request_fingerprint,
        metadata: if(retry, do: %{retry_schedule_id: retry.id}, else: %{})
      })
      |> insert!()

    {:ok, %{task: implementing}} =
      Tasks.transition_task(task.id, %{
        actor_id: attrs.actor_id,
        attempt_id: attempt.id,
        resulting_state: "IMPLEMENTING",
        reason: if(retry, do: "durable retry claimed", else: "durable task claimed"),
        reason_code: if(retry, do: "retry_claimed", else: "execution_claimed"),
        occurred_at: attrs.occurred_at,
        correlation_id: attrs.correlation_id,
        idempotency_key: "#{attrs.idempotency_key}:transition",
        metadata: %{lease_id: lease.id, fencing_token: lease.fencing_token}
      })

    %Claim{
      task: implementing,
      attempt: attempt,
      lease: lease,
      budgets: budgets_for(task.id, attempt.id)
    }
  end

  defp replay_claim(lease, request_fingerprint) do
    if lease.request_fingerprint == request_fingerprint do
      load_claim(lease)
    else
      Repo.rollback(:idempotency_conflict)
    end
  end

  defp existing_claim(idempotency_key) do
    Repo.one(
      from lease in WorkerLease, where: lease.idempotency_key == ^idempotency_key, limit: 1
    )
  end

  defp load_claim(lease) do
    attempt = Repo.get!(TaskAttempt, lease.attempt_id)

    %Claim{
      task: Repo.get!(Task, lease.task_id),
      attempt: attempt,
      lease: lease,
      budgets: budgets_for(lease.task_id, attempt.id)
    }
  end

  defp do_record_event(claim, event, attrs) do
    idempotency_key = event.idempotency_key || event.id
    request_fingerprint = event_fingerprint(claim, event, attrs)

    case Repo.get_by(ExecutionEvent, task_id: claim.task.id, idempotency_key: idempotency_key) do
      %ExecutionEvent{request_fingerprint: ^request_fingerprint} = persisted ->
        %{event: persisted, idempotent?: true, exhausted_metrics: []}

      %ExecutionEvent{} ->
        Repo.rollback(:idempotency_conflict)

      nil ->
        lease = validate_active_lease!(claim, event.occurred_at)
        attempt = Repo.get!(TaskAttempt, claim.attempt.id)

        if attempt.status != "running" do
          Repo.rollback(:stale_backend_event)
        end

        if event.sequence != attempt.execution_event_sequence + 1 do
          Repo.rollback({:invalid_execution_event_sequence, attempt.execution_event_sequence + 1})
        end

        validate_usage!(event.usage)

        persisted =
          %ExecutionEvent{}
          |> ExecutionEvent.changeset(%{
            id: event.id,
            task_id: claim.task.id,
            attempt_id: attempt.id,
            lease_id: lease.id,
            actor_id: attrs.actor_id,
            sequence: event.sequence,
            fencing_token: lease.fencing_token,
            kind: Atom.to_string(event.kind),
            occurred_at: event.occurred_at,
            correlation_id: attrs.correlation_id,
            idempotency_key: idempotency_key,
            request_fingerprint: request_fingerprint,
            payload: event.payload
          })
          |> insert!()

        attempt
        |> TaskAttempt.event_changeset(%{
          execution_event_sequence: event.sequence,
          backend_session_id: event.session_id || attempt.backend_session_id
        })
        |> update!()

        exhausted_metrics = persist_usage(claim, event, attrs)
        %{event: persisted, idempotent?: false, exhausted_metrics: exhausted_metrics}
    end
  end

  defp persist_usage(claim, event, attrs) do
    budgets = budgets_for(claim.task.id, claim.attempt.id)

    for {metric, quantity} <- normalize_usage(event.usage),
        budget <- budgets,
        reduce: [] do
      exhausted ->
        {:ok, result} =
          Tasks.record_usage(%{
            budget_id: budget.id,
            task_id: claim.task.id,
            attempt_id: claim.attempt.id,
            actor_id: attrs.actor_id,
            metric: metric,
            quantity: quantity,
            occurred_at: event.occurred_at,
            correlation_id: attrs.correlation_id,
            idempotency_key: "#{event.idempotency_key || event.id}:#{metric}",
            metadata: %{execution_event_id: event.id, fencing_token: claim.lease.fencing_token}
          })

        if result.exhausted?, do: [metric | exhausted], else: exhausted
    end
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp do_finish(claim, outcome, attrs) do
    request_fingerprint = finish_fingerprint(claim, outcome, attrs)

    case Repo.get_by(ExecutionEvent,
           task_id: claim.task.id,
           idempotency_key: attrs.idempotency_key
         ) do
      %ExecutionEvent{request_fingerprint: ^request_fingerprint} ->
        current_result(claim, true)

      %ExecutionEvent{} ->
        Repo.rollback(:idempotency_conflict)

      nil ->
        attempt = persist_completion_event(claim, outcome, attrs, request_fingerprint)

        attempt =
          attempt
          |> TaskAttempt.changeset(%{
            status: attempt_status(outcome),
            finished_at: attrs.occurred_at,
            outcome: Atom.to_string(outcome)
          })
          |> update!()

        lease =
          WorkerLease
          |> Repo.get!(claim.lease.id)
          |> WorkerLease.changeset(%{
            status: lease_status(outcome),
            released_at: attrs.occurred_at
          })
          |> update!()

        finalize_task(claim, outcome, attrs)
        |> Map.merge(%{attempt: attempt, lease: lease, idempotent?: false})
    end
  end

  defp persist_completion_event(claim, outcome, attrs, request_fingerprint) do
    lease = validate_active_lease!(claim, attrs.occurred_at)
    attempt = Repo.get!(TaskAttempt, claim.attempt.id)

    if attempt.status != "running" do
      Repo.rollback(:stale_backend_event)
    end

    sequence = attempt.execution_event_sequence + 1

    %ExecutionEvent{}
    |> ExecutionEvent.changeset(%{
      id: deterministic_uuid(attrs.idempotency_key),
      task_id: claim.task.id,
      attempt_id: attempt.id,
      lease_id: lease.id,
      actor_id: attrs.actor_id,
      sequence: sequence,
      fencing_token: lease.fencing_token,
      kind: Atom.to_string(outcome_kind(outcome)),
      occurred_at: attrs.occurred_at,
      correlation_id: attrs.correlation_id,
      idempotency_key: attrs.idempotency_key,
      request_fingerprint: request_fingerprint,
      payload: %{outcome: Atom.to_string(outcome), reason: attrs.reason}
    })
    |> insert!()

    attempt
    |> TaskAttempt.event_changeset(%{execution_event_sequence: sequence})
    |> update!()
  end

  defp finalize_task(claim, outcome, attrs) do
    task = Repo.get!(Task, claim.task.id)

    cond do
      task.state == "BLOCKED" ->
        maybe_schedule_retry(task, claim.attempt, outcome, attrs)
        %{task: task}

      outcome in [:backend_unavailable, :interrupted] ->
        {kind, reason_code} =
          if outcome == :interrupted,
            do: {"worker_lost", "execution_interrupted"},
            else: {"external_failure", "backend_unavailable"}

        {:ok, %{task: blocked}} =
          Tasks.block_task(task.id, %{
            actor_id: attrs.actor_id,
            attempt_id: claim.attempt.id,
            kind: kind,
            reason: attrs.reason,
            reason_code: reason_code,
            occurred_at: attrs.occurred_at,
            correlation_id: attrs.correlation_id,
            idempotency_key: "#{attrs.idempotency_key}:block"
          })

        maybe_schedule_retry(blocked, claim.attempt, outcome, attrs)
        %{task: blocked}

      true ->
        resulting_state = outcome_state(outcome)

        {:ok, %{task: transitioned}} =
          Tasks.transition_task(task.id, %{
            actor_id: attrs.actor_id,
            attempt_id: claim.attempt.id,
            resulting_state: resulting_state,
            reason: attrs.reason,
            reason_code: outcome_reason_code(outcome),
            occurred_at: attrs.occurred_at,
            correlation_id: attrs.correlation_id,
            idempotency_key: "#{attrs.idempotency_key}:transition"
          })

        %{task: transitioned}
    end
  end

  defp maybe_schedule_retry(_task, _attempt, outcome, _attrs)
       when outcome not in [:backend_unavailable, :interrupted],
       do: :ok

  defp maybe_schedule_retry(task, attempt, outcome, attrs)
       when outcome in [:backend_unavailable, :interrupted] do
    sequence =
      (Repo.one(
         from retry in RetrySchedule,
           where: retry.task_id == ^task.id,
           select: max(retry.sequence)
       ) || 0) + 1

    available? = metric_available?(task.id, attempt.id, "provider_retries")
    status = if available?, do: "scheduled", else: "exhausted"
    delay_seconds = min(trunc(:math.pow(2, sequence - 1)) * 10, 300)

    {:ok, _} =
      Tasks.schedule_retry(%{
        task_id: task.id,
        attempt_id: attempt.id,
        sequence: sequence,
        status: status,
        due_at: DateTime.add(attrs.occurred_at, delay_seconds, :second),
        reason: attrs.reason,
        resume_state: task.resume_state || task.state,
        correlation_id: attrs.correlation_id,
        idempotency_key: "#{attrs.idempotency_key}:retry",
        finished_at: if(status == "exhausted", do: attrs.occurred_at),
        metadata: %{backoff_seconds: delay_seconds, outcome: Atom.to_string(outcome)}
      })

    :ok
  end

  defp current_result(claim, idempotent?) do
    %{
      task: Repo.get!(Task, claim.task.id),
      attempt: Repo.get!(TaskAttempt, claim.attempt.id),
      lease: Repo.get!(WorkerLease, claim.lease.id),
      idempotent?: idempotent?
    }
  end

  defp validate_active_lease!(claim, observed_at) do
    lease = Repo.get!(WorkerLease, claim.lease.id)

    newest_token =
      Repo.one(
        from item in WorkerLease,
          where: item.task_id == ^claim.task.id,
          select: max(item.fencing_token)
      )

    if lease.task_id != claim.task.id or lease.attempt_id != claim.attempt.id or
         lease.fencing_token != claim.lease.fencing_token or lease.fencing_token != newest_token or
         lease.status != "active" or DateTime.compare(lease.expires_at, observed_at) != :gt do
      Repo.rollback(:stale_backend_event)
    end

    lease
  end

  defp budgets_for(task_id, nil) do
    Repo.all(
      from budget in Budget,
        where: budget.task_id == ^task_id and is_nil(budget.attempt_id),
        order_by: [asc: budget.inserted_at, asc: budget.id]
    )
  end

  defp budgets_for(task_id, attempt_id) do
    Repo.all(
      from budget in Budget,
        where:
          budget.task_id == ^task_id and
            (is_nil(budget.attempt_id) or budget.attempt_id == ^attempt_id),
        order_by: [asc: budget.inserted_at, asc: budget.id]
    )
  end

  defp budget_available?(task_id) do
    budgets = budgets_for(task_id, nil)
    budgets != [] and Enum.all?(budgets, &budget_capacity?/1)
  end

  defp budget_capacity?(budget) do
    budget.status == "active" and
      Enum.all?(~w(cost_microusd runtime_ms agent_turns), fn metric ->
        case limit_for(budget, metric) do
          nil -> true
          limit -> usage_total(budget.id, metric) < limit
        end
      end)
  end

  defp metric_available?(task_id, attempt_id, metric) do
    budgets_for(task_id, attempt_id)
    |> Enum.any?(fn budget ->
      case limit_for(budget, metric) do
        nil -> false
        limit -> budget.status == "active" and usage_total(budget.id, metric) < limit
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

  defp limit_for(budget, "cost_microusd"), do: budget.max_cost_microusd
  defp limit_for(budget, "runtime_ms"), do: budget.max_runtime_ms
  defp limit_for(budget, "agent_turns"), do: budget.max_agent_turns
  defp limit_for(budget, "repair_cycles"), do: budget.max_repair_cycles
  defp limit_for(budget, "provider_retries"), do: budget.max_provider_retries

  defp validate_usage!(usage) when is_map(usage) do
    valid_metrics = MapSet.new(UsageEntry.metrics())

    Enum.each(normalize_usage(usage), fn {metric, quantity} ->
      unless MapSet.member?(valid_metrics, metric) and is_integer(quantity) and quantity >= 0 do
        Repo.rollback(:invalid_usage_delta)
      end
    end)
  end

  defp validate_usage!(_usage), do: Repo.rollback(:invalid_usage_delta)

  defp normalize_usage(usage) do
    Enum.map(usage, fn {metric, quantity} -> {to_string(metric), quantity} end)
  end

  defp validate_claim_times(%{
         occurred_at: %DateTime{} = occurred_at,
         expires_at: %DateTime{} = expires_at
       }) do
    if DateTime.compare(expires_at, occurred_at) == :gt,
      do: :ok,
      else: {:error, :invalid_lease_expiry}
  end

  defp validate_claim_times(_attrs), do: {:error, :invalid_claim_time}

  defp validate_renewal_times(%{
         renewed_at: %DateTime{} = renewed_at,
         expires_at: %DateTime{} = expires_at
       }) do
    if DateTime.compare(expires_at, renewed_at) == :gt,
      do: :ok,
      else: {:error, :invalid_lease_expiry}
  end

  defp validate_renewal_times(_attrs), do: {:error, :invalid_claim_time}

  defp event_fingerprint(claim, event, attrs) do
    fingerprint(%{
      command: :record_execution_event,
      task_id: claim.task.id,
      attempt_id: claim.attempt.id,
      lease_id: claim.lease.id,
      fencing_token: claim.lease.fencing_token,
      actor_id: attrs.actor_id,
      correlation_id: attrs.correlation_id,
      event: Map.from_struct(event)
    })
  end

  defp finish_fingerprint(claim, outcome, attrs) do
    fingerprint(%{
      command: :finish_execution,
      task_id: claim.task.id,
      attempt_id: claim.attempt.id,
      lease_id: claim.lease.id,
      fencing_token: claim.lease.fencing_token,
      outcome: outcome,
      actor_id: attrs.actor_id,
      occurred_at: attrs.occurred_at,
      correlation_id: attrs.correlation_id,
      idempotency_key: attrs.idempotency_key,
      reason: attrs.reason
    })
  end

  defp fingerprint(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp deterministic_uuid(value) do
    <<raw::binary-size(16), _::binary>> = :crypto.hash(:sha256, value)
    {:ok, uuid} = Ecto.UUID.load(raw)
    uuid
  end

  defp outcome_kind(:success), do: :completed
  defp outcome_kind(:deterministic_failure), do: :failed
  defp outcome_kind(:timeout), do: :timed_out
  defp outcome_kind(:cancelled), do: :cancelled
  defp outcome_kind(:backend_unavailable), do: :backend_unavailable
  defp outcome_kind(:interrupted), do: :backend_unavailable

  defp attempt_status(:success), do: "succeeded"
  defp attempt_status(:cancelled), do: "cancelled"
  defp attempt_status(:interrupted), do: "lost"
  defp attempt_status(_outcome), do: "failed"

  defp lease_status(:interrupted), do: "lost"
  defp lease_status(_outcome), do: "released"

  defp outcome_state(:success), do: "CI_RUNNING"
  defp outcome_state(:cancelled), do: "CANCELLED"
  defp outcome_state(_outcome), do: "FAILED"

  defp outcome_reason_code(:success), do: "execution_succeeded"
  defp outcome_reason_code(:cancelled), do: "execution_cancelled"
  defp outcome_reason_code(_outcome), do: "terminal_failure"

  defp require_keys(attrs, keys) do
    case Enum.find(keys, &(not Map.has_key?(attrs, &1) or is_nil(Map.get(attrs, &1)))) do
      nil -> :ok
      key -> {:error, {:missing_command_field, key}}
    end
  end

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp flatten({:ok, result}), do: {:ok, result}
  defp flatten({:error, reason}), do: {:error, reason}
end
