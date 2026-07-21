defmodule Sxf.Execution.Coordinator do
  @moduledoc """
  Single-authority dispatch service whose process state is never workflow truth.

  Every claim, event, usage delta, lease change, retry, blocker, and outcome is committed through
  `Sxf.Execution.TaskStore` before the coordinator acts on it. A process restart reconstructs work
  only from that store.
  """

  use GenServer

  alias Sxf.Execution.{Context, Event, Result}

  defstruct [
    :task_store,
    :agent_backend,
    :workspace_backend,
    :sandbox_backend,
    :actor_id,
    :worker_id,
    :backend_name,
    :lease_ttl_ms,
    :now_fn,
    :backend_options
  ]

  @type server :: GenServer.server()

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def tick(server, opts \\ []) do
    GenServer.call(server, {:tick, opts}, Keyword.get(opts, :timeout, 30_000))
  end

  def reconcile(server), do: GenServer.call(server, :reconcile, 30_000)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      task_store: Keyword.fetch!(opts, :task_store),
      agent_backend: Keyword.fetch!(opts, :agent_backend),
      workspace_backend: Keyword.fetch!(opts, :workspace_backend),
      sandbox_backend: Keyword.fetch!(opts, :sandbox_backend),
      actor_id: Keyword.fetch!(opts, :actor_id),
      worker_id: Keyword.fetch!(opts, :worker_id),
      backend_name: Keyword.get(opts, :backend_name, "fake"),
      lease_ttl_ms: Keyword.get(opts, :lease_ttl_ms, 60_000),
      now_fn: Keyword.get(opts, :now_fn, &DateTime.utc_now/0),
      backend_options: Map.new(Keyword.get(opts, :backend_options, []))
    }

    if Keyword.get(opts, :reconcile_on_start, true) do
      {:ok, state, {:continue, :reconcile}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:reconcile, state) do
    do_reconcile(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:tick, opts}, _from, state) do
    {:reply, dispatch_once(state, opts), state}
  end

  def handle_call(:reconcile, _from, state) do
    {:reply, do_reconcile(state), state}
  end

  defp dispatch_once(state, opts) do
    started_at = state.now_fn.()
    dispatch_key = Keyword.get(opts, :idempotency_key, "dispatch:#{Sxf.Identifiers.generate()}")
    correlation_id = Keyword.get(opts, :correlation_id, Sxf.Identifiers.generate())

    claim_attrs = %{
      worker_id: state.worker_id,
      actor_id: state.actor_id,
      backend: state.backend_name,
      occurred_at: started_at,
      expires_at: DateTime.add(started_at, state.lease_ttl_ms, :millisecond),
      correlation_id: correlation_id,
      idempotency_key: dispatch_key
    }

    case state.task_store.claim_next(claim_attrs) do
      {:ok, nil} ->
        {:ok, :idle}

      {:ok, claim} ->
        run_claim(state, claim, started_at, correlation_id, dispatch_key)

      {:error, reason} ->
        {:error, {:claim_failed, reason}}
    end
  end

  defp run_claim(state, claim, started_at, correlation_id, dispatch_key) do
    context = %Context{
      claim: claim,
      actor_id: state.actor_id,
      correlation_id: correlation_id,
      started_at: started_at,
      options: state.backend_options
    }

    counter = :atomics.new(1, signed: false)
    :atomics.put(counter, 1, claim.attempt.execution_event_sequence)
    latest_key = {__MODULE__, :latest_event_at, make_ref()}
    Process.put(latest_key, started_at)

    emit = fn event ->
      persist_backend_event(state, claim, context, event, counter, latest_key)
    end

    outcome =
      with {:ok, workspace} <- state.workspace_backend.prepare(context),
           workspace_context = %{context | workspace: workspace},
           {:ok, sandbox} <- state.sandbox_backend.prepare(workspace_context),
           execution_context = %{workspace_context | sandbox: sandbox} do
        try do
          normalize_backend_result(state.agent_backend.start(execution_context, emit))
        after
          state.sandbox_backend.release(execution_context)
          state.workspace_backend.release(workspace_context)
        end
      else
        {:error, reason} -> %Result{outcome: :backend_unavailable, reason: inspect(reason)}
      end

    if outcome.outcome == :backend_unavailable do
      persist_retry_usage(state, claim, context, counter, latest_key, dispatch_key)
    end

    finished_at = max_datetime(Process.get(latest_key, started_at), state.now_fn.())
    Process.delete(latest_key)

    case state.task_store.finish(claim, outcome.outcome, %{
           actor_id: state.actor_id,
           occurred_at: finished_at,
           correlation_id: correlation_id,
           idempotency_key: "#{dispatch_key}:finish",
           reason: outcome.reason || Atom.to_string(outcome.outcome)
         }) do
      {:ok, result} -> {:ok, %{claim: claim, outcome: outcome, durable: result}}
      {:error, reason} -> {:error, {:finish_failed, reason}}
    end
  end

  defp persist_backend_event(state, claim, context, %Event{} = event, counter, latest_key) do
    expected = :atomics.get(counter, 1) + 1

    if event.sequence != expected do
      {:error, {:invalid_execution_event_sequence, expected}}
    else
      event = %{event | idempotency_key: event.idempotency_key || "backend-event:#{event.id}"}

      case state.task_store.record_event(claim, event, %{
             actor_id: context.actor_id,
             correlation_id: context.correlation_id
           }) do
        {:ok, %{exhausted_metrics: []}} ->
          :atomics.put(counter, 1, event.sequence)
          Process.put(latest_key, max_datetime(Process.get(latest_key), event.occurred_at))
          :ok

        {:ok, %{exhausted_metrics: metrics}} ->
          :atomics.put(counter, 1, event.sequence)
          Process.put(latest_key, max_datetime(Process.get(latest_key), event.occurred_at))
          {:error, {:budget_exhausted, metrics}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp persist_retry_usage(state, claim, context, counter, latest_key, dispatch_key) do
    sequence = :atomics.get(counter, 1) + 1
    occurred_at = max_datetime(Process.get(latest_key), state.now_fn.())
    key = "#{dispatch_key}:provider-retry"

    event = %Event{
      id: deterministic_uuid(key),
      idempotency_key: key,
      sequence: sequence,
      kind: :usage,
      occurred_at: occurred_at,
      payload: %{reason: "backend unavailable"},
      usage: %{provider_retries: 1}
    }

    case persist_backend_event(state, claim, context, event, counter, latest_key) do
      :ok -> :ok
      {:error, {:budget_exhausted, _metrics}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_reconcile(state) do
    observed_at = state.now_fn.()
    correlation_id = Sxf.Identifiers.generate()
    expired = state.task_store.reconcile_expired(observed_at, state.actor_id, correlation_id)

    interrupted =
      state.task_store.active_claims(state.worker_id)
      |> Enum.flat_map(fn claim ->
        context = %Context{
          claim: claim,
          actor_id: state.actor_id,
          correlation_id: correlation_id,
          started_at: claim.attempt.started_at,
          options: state.backend_options
        }

        case state.agent_backend.inspect(context) do
          {:ok, :running} ->
            []

          _not_running ->
            key = "restart-interrupted:#{claim.lease.id}"
            counter = :atomics.new(1, signed: false)
            :atomics.put(counter, 1, claim.attempt.execution_event_sequence)
            latest_key = {__MODULE__, :reconcile_event_at, claim.lease.id}
            Process.put(latest_key, observed_at)
            persist_retry_usage(state, claim, context, counter, latest_key, key)
            Process.delete(latest_key)

            attrs = %{
              actor_id: state.actor_id,
              occurred_at: observed_at,
              correlation_id: correlation_id,
              idempotency_key: "#{key}:finish",
              reason: "coordinator restart found no running backend session"
            }

            case state.task_store.interrupt(claim, attrs) do
              {:ok, result} -> [result]
              {:error, :stale_backend_event} -> []
              {:error, reason} -> [%{error: reason, claim: claim}]
            end
        end
      end)

    %{expired: expired, interrupted: interrupted}
  end

  defp normalize_backend_result({:ok, %Result{outcome: outcome} = result})
       when outcome in [
              :success,
              :deterministic_failure,
              :timeout,
              :cancelled,
              :backend_unavailable
            ],
       do: result

  defp normalize_backend_result({:error, reason}),
    do: %Result{outcome: :backend_unavailable, reason: inspect(reason)}

  defp normalize_backend_result(other),
    do: %Result{
      outcome: :backend_unavailable,
      reason: "invalid backend result: #{inspect(other)}"
    }

  defp max_datetime(nil, right), do: right
  defp max_datetime(left, nil), do: left

  defp max_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp deterministic_uuid(value) do
    <<raw::binary-size(16), _::binary>> = :crypto.hash(:sha256, value)
    {:ok, uuid} = Ecto.UUID.load(raw)
    uuid
  end
end
