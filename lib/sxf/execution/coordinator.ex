defmodule Sxf.Execution.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    coordinator_opts = Keyword.put_new(opts, :task_supervisor, Sxf.Execution.TaskSupervisor)

    children = [
      {Task.Supervisor, name: Sxf.Execution.TaskSupervisor},
      {Sxf.Execution.Coordinator, coordinator_opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end

defmodule Sxf.Execution.Coordinator do
  @moduledoc """
  Durable dispatch authority with supervised, non-blocking execution workers.

  OTP tasks provide liveness and cancellation only. Claims, leases, renewal history, runtime
  deadlines, retries, blockers, usage, and outcomes remain authoritative in `TaskStore`.
  """

  use GenServer

  alias Sxf.Execution.{Context, Event, Result}

  defstruct [
    :task_store,
    :agent_backend,
    :workspace_backend,
    :sandbox_backend,
    :task_supervisor,
    :actor_id,
    :worker_id,
    :backend_name,
    :lease_ttl_ms,
    :lease_renewal_interval_ms,
    :control_tick_ms,
    :now_fn,
    :backend_options,
    automatic_timers: true,
    active: %{},
    monitors: %{},
    waiters: [],
    completed: []
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

  def advance(server, %DateTime{} = observed_at) do
    GenServer.call(server, {:advance, observed_at}, 30_000)
  end

  def await_idle(server, timeout \\ 30_000), do: GenServer.call(server, :await_idle, timeout)
  def active_count(server), do: GenServer.call(server, :active_count)

  @impl true
  def init(opts) do
    lease_ttl_ms = Keyword.get(opts, :lease_ttl_ms, 60_000)
    renewal_interval = Keyword.get(opts, :lease_renewal_interval_ms, div(lease_ttl_ms, 3))

    state = %__MODULE__{
      task_store: Keyword.fetch!(opts, :task_store),
      agent_backend: Keyword.fetch!(opts, :agent_backend),
      workspace_backend: Keyword.fetch!(opts, :workspace_backend),
      sandbox_backend: Keyword.fetch!(opts, :sandbox_backend),
      task_supervisor: Keyword.get(opts, :task_supervisor, Sxf.Execution.TaskSupervisor),
      actor_id: Keyword.fetch!(opts, :actor_id),
      worker_id: Keyword.fetch!(opts, :worker_id),
      backend_name: Keyword.get(opts, :backend_name, "fake"),
      lease_ttl_ms: lease_ttl_ms,
      lease_renewal_interval_ms: renewal_interval,
      control_tick_ms: Keyword.get(opts, :control_tick_ms, renewal_interval),
      automatic_timers: Keyword.get(opts, :automatic_timers, true),
      now_fn: Keyword.get(opts, :now_fn, &DateTime.utc_now/0),
      backend_options: Map.new(Keyword.get(opts, :backend_options, []))
    }

    if Keyword.get(opts, :reconcile_on_start, true) do
      {:ok, state, {:continue, :reconcile}}
    else
      {:ok, schedule_control_tick(state)}
    end
  end

  @impl true
  def handle_continue(:reconcile, state) do
    do_reconcile(state)
    {:noreply, schedule_control_tick(state)}
  end

  @impl true
  def handle_call({:tick, opts}, _from, state) do
    {reply, state} = dispatch_once(state, opts)
    {:reply, reply, state}
  end

  def handle_call(:reconcile, _from, state), do: {:reply, do_reconcile(state), state}

  def handle_call({:advance, observed_at}, _from, state) do
    {results, state} = advance_active(state, observed_at)
    {:reply, results, state}
  end

  def handle_call(:active_count, _from, state), do: {:reply, map_size(state.active), state}

  def handle_call(:await_idle, from, %{active: active} = state) when map_size(active) > 0 do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:await_idle, _from, state) do
    {:reply, {:ok, Enum.reverse(state.completed)}, %{state | completed: []}}
  end

  def handle_call({:backend_event, lease_id, %Event{} = event}, {pid, _tag}, state) do
    case Map.get(state.active, lease_id) do
      %{pid: ^pid, status: :running} = entry ->
        expected = entry.claim.attempt.execution_event_sequence + 1

        if event.sequence != expected do
          {:reply, {:error, {:invalid_execution_event_sequence, expected}}, state}
        else
          attrs = %{
            actor_id: entry.context.actor_id,
            correlation_id: entry.context.correlation_id,
            observed_at: state.now_fn.()
          }

          case state.task_store.record_event(entry.claim, event, attrs) do
            {:ok, result} ->
              claim = %{entry.claim | attempt: result.attempt}

              state =
                put_entry(state, %{entry | claim: claim, context: %{entry.context | claim: claim}})

              reply =
                case result.exhausted_metrics do
                  [] -> :ok
                  metrics -> {:error, {:budget_exhausted, metrics}}
                end

              {:reply, reply, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end

      _ ->
        {:reply, {:error, :stale_backend_event}, state}
    end
  end

  @impl true
  def handle_info({:execution_context, lease_id, pid, %Context{} = context}, state) do
    state =
      case Map.get(state.active, lease_id) do
        %{pid: ^pid, status: :running} = entry -> put_entry(state, %{entry | context: context})
        _ -> state
      end

    {:noreply, state}
  end

  def handle_info({:execution_finished, lease_id, pid, result, cleanup_errors}, state) do
    state =
      case Map.get(state.active, lease_id) do
        %{pid: ^pid, status: :running} = entry ->
          finish_backend_execution(state, entry, result, cleanup_errors)

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:control_stop_finished, lease_id, control_pid, details}, state) do
    state =
      case Map.get(state.active, lease_id) do
        %{control_pid: ^control_pid, status: :stopping} = entry ->
          finish_control_stop(state, entry, details)

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {lease_id, monitors} ->
        state = %{state | monitors: monitors}

        case Map.get(state.active, lease_id) do
          %{monitor_ref: ^ref, status: :running} = entry ->
            observed_at = state.now_fn.()

            {:noreply,
             begin_control_stop(
               state,
               entry,
               :interrupted,
               "supervised execution process exited: #{inspect(reason)}",
               observed_at,
               false
             )}

          _ ->
            {:noreply, state}
        end
    end
  end

  def handle_info(:control_tick, state) do
    {_results, state} = advance_active(state, state.now_fn.())
    {:noreply, schedule_control_tick(state)}
  end

  defp dispatch_once(state, opts) do
    observed_at = state.now_fn.()
    dispatch_key = Keyword.get(opts, :idempotency_key, "dispatch:#{Sxf.Identifiers.generate()}")
    correlation_id = Keyword.get(opts, :correlation_id, Sxf.Identifiers.generate())

    claim_attrs = %{
      worker_id: state.worker_id,
      actor_id: state.actor_id,
      backend: state.backend_name,
      occurred_at: observed_at,
      expires_at: DateTime.add(observed_at, state.lease_ttl_ms, :millisecond),
      correlation_id: correlation_id,
      idempotency_key: dispatch_key,
      dispatch_input: Map.new(Keyword.get(opts, :dispatch_input, %{}))
    }

    case state.task_store.claim_next(claim_attrs) do
      {:ok, nil} ->
        {{:ok, :idle}, state}

      {:ok, %{replayed?: true} = claim} ->
        {{:ok, %{status: :replayed, claim: claim, durable: durable_snapshot(claim)}}, state}

      {:ok, claim} ->
        start_execution(state, claim, dispatch_key, correlation_id)

      {:error, reason} ->
        {{:error, {:claim_failed, reason}}, state}
    end
  end

  defp start_execution(state, claim, dispatch_key, correlation_id) do
    context = %Context{
      claim: claim,
      actor_id: state.actor_id,
      correlation_id: correlation_id,
      started_at: claim.attempt.started_at,
      options: state.backend_options
    }

    coordinator = self()

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           Sxf.Execution.Worker.run(coordinator, context, %{
             agent: state.agent_backend,
             workspace: state.workspace_backend,
             sandbox: state.sandbox_backend
           })
         end) do
      {:ok, pid} ->
        monitor_ref = Process.monitor(pid)

        entry = %{
          claim: claim,
          context: context,
          pid: pid,
          monitor_ref: monitor_ref,
          control_pid: nil,
          status: :running,
          dispatch_key: dispatch_key,
          renewal_sequence: claim.renewal_sequence,
          next_renewal_at:
            DateTime.add(
              claim.lease.heartbeat_at || claim.lease.acquired_at,
              state.lease_renewal_interval_ms,
              :millisecond
            ),
          runtime_deadline_at: claim.runtime_deadline_at
        }

        state =
          state
          |> put_entry(entry)
          |> put_monitor(monitor_ref, claim.lease.id)
          |> schedule_entry_tick(entry)

        {{:ok, %{status: :accepted, claim: claim}}, state}

      {:error, reason} ->
        attrs =
          finish_attrs(
            state,
            claim,
            dispatch_key,
            correlation_id,
            "worker start failed: #{inspect(reason)}"
          )

        case state.task_store.finish(claim, :backend_unavailable, attrs) do
          {:ok, durable} ->
            {{:ok,
              %{
                status: :completed,
                claim: claim,
                outcome: %Result{outcome: :backend_unavailable, reason: attrs.reason},
                durable: durable
              }}, state}

          {:error, finish_reason} ->
            {{:error, {:worker_start_failed, reason, finish_reason}}, state}
        end
    end
  end

  defp advance_active(state, observed_at) do
    Enum.reduce(Map.values(state.active), {[], state}, fn entry, {results, state} ->
      case Map.get(state.active, entry.claim.lease.id) do
        %{status: :running} = current ->
          cond do
            current.runtime_deadline_at &&
                DateTime.compare(observed_at, current.runtime_deadline_at) != :lt ->
              state =
                begin_control_stop(
                  state,
                  current,
                  :runtime_timeout,
                  "control-plane runtime deadline reached",
                  observed_at,
                  true
                )

              {[%{lease_id: current.claim.lease.id, action: :runtime_timeout} | results], state}

            DateTime.compare(observed_at, current.next_renewal_at) != :lt ->
              case renew_entry(state, current, observed_at) do
                {:ok, state} ->
                  {[%{lease_id: current.claim.lease.id, action: :renewed} | results], state}

                {:error, reason, state} ->
                  state =
                    begin_control_stop(
                      state,
                      current,
                      :interrupted,
                      "lease renewal failed: #{inspect(reason)}",
                      observed_at,
                      true
                    )

                  {[
                     %{lease_id: current.claim.lease.id, action: :renewal_failed, reason: reason}
                     | results
                   ], state}
              end

            true ->
              {results, state}
          end

        _ ->
          {results, state}
      end
    end)
    |> then(fn {results, state} -> {Enum.reverse(results), state} end)
  end

  defp renew_entry(state, entry, observed_at) do
    sequence = entry.renewal_sequence + 1
    base = max_datetime(entry.claim.lease.expires_at, observed_at)
    expires_at = DateTime.add(base, state.lease_ttl_ms, :millisecond)

    attrs = %{
      renewed_at: observed_at,
      expires_at: expires_at,
      sequence: sequence,
      idempotency_key: "lease-renewal:#{entry.claim.lease.id}:#{sequence}"
    }

    case state.task_store.renew_lease(entry.claim, attrs) do
      {:ok, %{lease: lease}} ->
        claim = %{entry.claim | lease: lease, renewal_sequence: sequence}

        entry = %{
          entry
          | claim: claim,
            context: %{entry.context | claim: claim},
            renewal_sequence: sequence,
            next_renewal_at:
              DateTime.add(observed_at, state.lease_renewal_interval_ms, :millisecond)
        }

        state = state |> put_entry(entry) |> schedule_entry_tick(entry)
        {:ok, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp begin_control_stop(state, %{status: :running} = entry, kind, reason, observed_at, cancel?) do
    Process.demonitor(entry.monitor_ref, [:flush])
    _ = Task.Supervisor.terminate_child(state.task_supervisor, entry.pid)
    coordinator = self()
    context = entry.context

    {:ok, control_pid} =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        cancellation =
          if cancel?,
            do: Sxf.Execution.Worker.cancel(context, state.agent_backend),
            else: %{attempted: false, result: :not_requested}

        cleanup_errors =
          Sxf.Execution.Worker.cleanup(
            context,
            state.workspace_backend,
            state.sandbox_backend
          )

        send(coordinator, {
          :control_stop_finished,
          context.claim.lease.id,
          self(),
          %{
            kind: kind,
            reason: reason,
            observed_at: observed_at,
            cancellation: cancellation,
            cleanup_errors: cleanup_errors
          }
        })
      end)

    monitors = Map.delete(state.monitors, entry.monitor_ref)

    put_entry(%{state | monitors: monitors}, %{
      entry
      | status: :stopping,
        control_pid: control_pid
    })
  end

  defp finish_backend_execution(state, entry, backend_result, cleanup_errors) do
    Process.demonitor(entry.monitor_ref, [:flush])
    result = normalize_backend_result(backend_result)
    observed_at = state.now_fn.()

    attrs =
      finish_attrs(
        state,
        entry.claim,
        entry.dispatch_key,
        entry.context.correlation_id,
        result.reason || Atom.to_string(result.outcome)
      )
      |> Map.put(:occurred_at, observed_at)
      |> Map.put(:metadata, %{
        timeout_source: if(result.outcome == :timeout, do: "backend_declared", else: nil),
        cleanup_errors: cleanup_errors
      })

    completion =
      case state.task_store.finish(entry.claim, result.outcome, attrs) do
        {:ok, durable} ->
          %{claim: entry.claim, outcome: result, durable: durable, cleanup_errors: cleanup_errors}

        {:error, reason} ->
          %{claim: entry.claim, error: {:finish_failed, reason}, cleanup_errors: cleanup_errors}
      end

    complete_entry(state, entry, completion)
  end

  defp finish_control_stop(state, entry, details) do
    attrs = %{
      actor_id: state.actor_id,
      occurred_at: details.observed_at,
      observed_at: details.observed_at,
      correlation_id: entry.context.correlation_id,
      idempotency_key: "#{entry.dispatch_key}:#{details.kind}",
      reason: details.reason,
      cancellation: details.cancellation,
      cleanup_errors: details.cleanup_errors,
      metadata: %{
        cancellation: details.cancellation,
        cleanup_errors: details.cleanup_errors,
        stop_kind: to_string(details.kind)
      }
    }

    result =
      case details.kind do
        :runtime_timeout -> state.task_store.enforce_runtime_timeout(entry.claim, attrs)
        :interrupted -> state.task_store.interrupt(entry.claim, attrs)
      end

    completion =
      case result do
        {:ok, durable} ->
          %{
            claim: entry.claim,
            outcome: details.kind,
            durable: durable,
            cancellation: details.cancellation,
            cleanup_errors: details.cleanup_errors
          }

        {:error, reason} ->
          %{
            claim: entry.claim,
            error: {details.kind, reason},
            cancellation: details.cancellation,
            cleanup_errors: details.cleanup_errors
          }
      end

    complete_entry(state, entry, completion)
  end

  defp complete_entry(state, entry, completion) do
    active = Map.delete(state.active, entry.claim.lease.id)
    monitors = Map.delete(state.monitors, entry.monitor_ref)

    state = %{
      state
      | active: active,
        monitors: monitors,
        completed: [completion | state.completed]
    }

    if map_size(active) == 0 and state.waiters != [] do
      reply = {:ok, Enum.reverse(state.completed)}
      Enum.each(state.waiters, &GenServer.reply(&1, reply))
      %{state | waiters: [], completed: []}
    else
      state
    end
  end

  defp do_reconcile(state) do
    observed_at = state.now_fn.()
    correlation_id = Sxf.Identifiers.generate()
    expired = state.task_store.reconcile_expired(observed_at, state.actor_id, correlation_id)

    interrupted =
      state.task_store.active_claims(state.worker_id)
      |> Enum.reject(&Map.has_key?(state.active, &1.lease.id))
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
            attrs = %{
              actor_id: state.actor_id,
              occurred_at: observed_at,
              correlation_id: correlation_id,
              idempotency_key: "restart-interrupted:#{claim.lease.id}",
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

  defp finish_attrs(state, claim, dispatch_key, correlation_id, reason) do
    %{
      actor_id: state.actor_id,
      occurred_at: state.now_fn.(),
      correlation_id: correlation_id,
      idempotency_key: "#{dispatch_key}:finish",
      reason: reason,
      metadata: %{attempt_id: claim.attempt.id}
    }
  end

  defp durable_snapshot(claim) do
    %{task: claim.task, attempt: claim.attempt, lease: claim.lease, replayed?: true}
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

  defp put_entry(state, entry),
    do: %{state | active: Map.put(state.active, entry.claim.lease.id, entry)}

  defp put_monitor(state, ref, lease_id),
    do: %{state | monitors: Map.put(state.monitors, ref, lease_id)}

  defp schedule_control_tick(%{automatic_timers: false} = state), do: state

  defp schedule_control_tick(state) do
    Process.send_after(self(), :control_tick, state.control_tick_ms)
    state
  end

  defp schedule_entry_tick(%{automatic_timers: false} = state, _entry), do: state

  defp schedule_entry_tick(state, entry) do
    deadline =
      [entry.next_renewal_at, entry.runtime_deadline_at]
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime)

    delay = max(DateTime.diff(deadline, state.now_fn.(), :millisecond), 0)
    Process.send_after(self(), :control_tick, delay)
    state
  end

  defp max_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end
end

defmodule Sxf.Execution.Worker do
  @moduledoc false

  alias Sxf.Execution.{Context, Result}

  def run(coordinator, %Context{} = context, backends) do
    lease_id = context.claim.lease.id

    case safe_call(fn -> backends.workspace.prepare(context) end) do
      {:ok, workspace} ->
        workspace_context = %{context | workspace: workspace}
        send(coordinator, {:execution_context, lease_id, self(), workspace_context})

        case safe_call(fn -> backends.sandbox.prepare(workspace_context) end) do
          {:ok, sandbox} ->
            execution_context = %{workspace_context | sandbox: sandbox}
            send(coordinator, {:execution_context, lease_id, self(), execution_context})

            emit = fn event ->
              GenServer.call(coordinator, {:backend_event, lease_id, event}, 30_000)
            end

            result = safe_call(fn -> backends.agent.start(execution_context, emit) end)
            cleanup_errors = cleanup(execution_context, backends.workspace, backends.sandbox)
            send(coordinator, {:execution_finished, lease_id, self(), result, cleanup_errors})

          {:error, reason} ->
            cleanup_errors = cleanup(workspace_context, backends.workspace, backends.sandbox)

            send(coordinator, {
              :execution_finished,
              lease_id,
              self(),
              {:ok, %Result{outcome: :backend_unavailable, reason: inspect(reason)}},
              cleanup_errors
            })
        end

      {:error, reason} ->
        send(coordinator, {
          :execution_finished,
          lease_id,
          self(),
          {:ok, %Result{outcome: :backend_unavailable, reason: inspect(reason)}},
          []
        })
    end
  end

  def cancel(context, agent_backend) do
    case safe_call(fn -> agent_backend.cancel(context) end) do
      :ok ->
        %{attempted: true, result: :ok}

      {:error, reason} ->
        %{attempted: true, result: :error, reason: inspect(reason)}

      other ->
        %{attempted: true, result: :error, reason: "invalid cancel result: #{inspect(other)}"}
    end
  end

  def cleanup(context, workspace_backend, sandbox_backend) do
    []
    |> maybe_release(:sandbox, context.sandbox, fn -> sandbox_backend.release(context) end)
    |> maybe_release(:workspace, context.workspace, fn -> workspace_backend.release(context) end)
    |> Enum.reverse()
  end

  defp maybe_release(errors, _kind, nil, _release), do: errors

  defp maybe_release(errors, kind, _resource, release) do
    case safe_call(release) do
      :ok -> errors
      {:error, reason} -> [%{boundary: kind, reason: inspect(reason)} | errors]
      other -> [%{boundary: kind, reason: "invalid release result: #{inspect(other)}"} | errors]
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    error -> {:error, {:exception, error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
