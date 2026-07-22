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
    :control_timer_ref,
    :control_timer_deadline,
    :control_timer_token,
    :next_reconciliation_at,
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
  def control_timer(server), do: GenServer.call(server, :control_timer)

  @impl true
  def init(opts) do
    lease_ttl_ms = Keyword.get(opts, :lease_ttl_ms, 60_000)
    renewal_interval = Keyword.get(opts, :lease_renewal_interval_ms, div(lease_ttl_ms, 3))
    control_tick_ms = Keyword.get(opts, :control_tick_ms, renewal_interval)

    with :ok <- validate_timing_config(lease_ttl_ms, renewal_interval, control_tick_ms) do
      observed_at = Keyword.get(opts, :now_fn, &DateTime.utc_now/0).()

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
        control_tick_ms: control_tick_ms,
        automatic_timers: Keyword.get(opts, :automatic_timers, true),
        now_fn: Keyword.get(opts, :now_fn, &DateTime.utc_now/0),
        backend_options: Map.new(Keyword.get(opts, :backend_options, [])),
        next_reconciliation_at: DateTime.add(observed_at, control_tick_ms, :millisecond)
      }

      if Keyword.get(opts, :reconcile_on_start, true) do
        {:ok, state, {:continue, :reconcile}}
      else
        {:ok, reschedule_control_timer(state)}
      end
    else
      {:error, reason} -> {:stop, {:invalid_timing_configuration, reason}}
    end
  end

  @impl true
  def handle_continue(:reconcile, state) do
    observed_at = state.now_fn.()
    {_report, state} = do_reconcile(state, observed_at)
    {:noreply, state |> reset_reconciliation_deadline(observed_at) |> reschedule_control_timer()}
  end

  @impl true
  def handle_call({:tick, opts}, _from, state) do
    {reply, state} = dispatch_once(state, opts)
    {:reply, reply, state}
  end

  def handle_call(:reconcile, _from, state) do
    observed_at = state.now_fn.()
    {report, state} = do_reconcile(state, observed_at)
    state = state |> reset_reconciliation_deadline(observed_at) |> reschedule_control_timer()
    {:reply, report, state}
  end

  def handle_call({:advance, observed_at}, _from, state) do
    {results, state} = advance_active(state, observed_at)
    {:reply, results, reschedule_control_timer(state)}
  end

  def handle_call(:active_count, _from, state), do: {:reply, map_size(state.active), state}

  def handle_call(:control_timer, _from, state) do
    {:reply,
     %{
       ref: state.control_timer_ref,
       deadline: state.control_timer_deadline,
       token: state.control_timer_token
     }, state}
  end

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
        observed_at = state.now_fn.()

        cond do
          event.sequence != expected ->
            {:reply, {:error, {:invalid_execution_event_sequence, expected}}, state}

          deadline_reached?(entry.runtime_deadline_at, observed_at) ->
            state =
              begin_control_stop(
                state,
                entry,
                :runtime_timeout,
                "backend event observed after the durable runtime deadline",
                observed_at,
                true
              )

            {:reply, {:error, :runtime_deadline_reached}, reschedule_control_timer(state)}

          true ->
            attrs = %{
              actor_id: entry.context.actor_id,
              correlation_id: entry.context.correlation_id,
              observed_at: observed_at
            }

            case state.task_store.record_event(entry.claim, event, attrs) do
              {:ok, result} ->
                claim = %{
                  entry.claim
                  | attempt: result.attempt,
                    runtime_deadline_at: result.attempt.runtime_deadline_at
                }

                state =
                  state
                  |> put_entry(%{
                    entry
                    | claim: claim,
                      context: %{entry.context | claim: claim},
                      runtime_deadline_at: claim.runtime_deadline_at
                  })
                  |> reschedule_control_timer()

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

    {:noreply, reschedule_control_timer(state)}
  end

  def handle_info({:execution_finished, lease_id, pid, result, cleanup_errors}, state) do
    state =
      case Map.get(state.active, lease_id) do
        %{pid: ^pid, status: :running} = entry ->
          normalized = normalize_backend_result(result)

          if entry.mode == :resume and normalized.outcome == :backend_unavailable do
            begin_control_stop(
              state,
              entry,
              :interrupted,
              "backend resume failed: #{normalized.reason}",
              state.now_fn.(),
              true
            )
          else
            finish_backend_execution(state, entry, normalized, cleanup_errors)
          end

        _ ->
          state
      end

    {:noreply, reschedule_control_timer(state)}
  end

  def handle_info({:control_stop_finished, lease_id, control_pid, details}, state) do
    state =
      case Map.get(state.active, lease_id) do
        %{control_pid: ^control_pid, status: :stopping} = entry ->
          finish_control_stop(state, entry, details)

        _ ->
          state
      end

    {:noreply, reschedule_control_timer(state)}
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

            state =
              begin_control_stop(
                state,
                entry,
                :interrupted,
                "supervised execution process exited: #{inspect(reason)}",
                observed_at,
                false
              )

            {:noreply, reschedule_control_timer(state)}

          _ ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:control_tick, token}, %{control_timer_token: token} = state) do
    if state.control_timer_ref, do: Process.cancel_timer(state.control_timer_ref)

    observed_at = state.now_fn.()

    state = %{
      state
      | control_timer_ref: nil,
        control_timer_deadline: nil,
        control_timer_token: nil
    }

    {_report, state} = do_reconcile(state, observed_at)
    {_results, state} = advance_active(state, observed_at)

    {:noreply, state |> reset_reconciliation_deadline(observed_at) |> reschedule_control_timer()}
  end

  def handle_info({:control_tick, _stale_token}, state), do: {:noreply, state}
  def handle_info(:control_tick, state), do: {:noreply, state}

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
           receive do
             :begin_execution ->
               Sxf.Execution.Worker.run(coordinator, context, %{
                 agent: state.agent_backend,
                 workspace: state.workspace_backend,
                 sandbox: state.sandbox_backend
               })
           end
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
          mode: :start,
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
          |> reschedule_control_timer()

        send(pid, :begin_execution)

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
            deadline_reached?(current.claim.lease.expires_at, observed_at) ->
              state =
                begin_control_stop(
                  state,
                  current,
                  :lease_expired,
                  "durable worker lease expired before renewal",
                  observed_at,
                  true
                )

              {[%{lease_id: current.claim.lease.id, action: :lease_expired} | results], state}

            deadline_reached?(current.runtime_deadline_at, observed_at) ->
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
    expires_at = DateTime.add(observed_at, state.lease_ttl_ms, :millisecond)

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

        state = state |> put_entry(entry) |> reschedule_control_timer()
        {:ok, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp begin_control_stop(state, %{status: :running} = entry, kind, reason, observed_at, cancel?) do
    if entry.monitor_ref, do: Process.demonitor(entry.monitor_ref, [:flush])
    if entry.pid, do: Task.Supervisor.terminate_child(state.task_supervisor, entry.pid)
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

    monitors =
      if entry.monitor_ref,
        do: Map.delete(state.monitors, entry.monitor_ref),
        else: state.monitors

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
        :runtime_timeout ->
          state.task_store.enforce_runtime_timeout(entry.claim, attrs)

        :interrupted ->
          state.task_store.interrupt(entry.claim, attrs)

        :lease_expired ->
          case state.task_store.reconcile_expired(
                 details.observed_at,
                 state.actor_id,
                 entry.context.correlation_id,
                 []
               ) do
            [] -> {:error, :expired_lease_not_reconciled}
            results -> {:ok, %{expired: results}}
          end
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

    state =
      if map_size(active) == 0 and state.waiters != [] do
        reply = {:ok, Enum.reverse(state.completed)}
        Enum.each(state.waiters, &GenServer.reply(&1, reply))
        %{state | waiters: [], completed: []}
      else
        state
      end

    reschedule_control_timer(state)
  end

  defp do_reconcile(state, observed_at) do
    correlation_id = Sxf.Identifiers.generate()
    locally_owned = Map.keys(state.active)

    expired =
      state.task_store.reconcile_expired(
        observed_at,
        state.actor_id,
        correlation_id,
        locally_owned
      )

    {actions, state} =
      state.task_store.active_claims(state.worker_id)
      |> Enum.reject(&Map.has_key?(state.active, &1.lease.id))
      |> Enum.reduce({[], state}, fn claim, {actions, state} ->
        {action, state} = reconcile_claim(state, claim, correlation_id)
        {[action | actions], state}
      end)

    report =
      Enum.reduce(actions, %{expired: expired, resumed: [], interrupted: [], errors: []}, fn
        {:resumed, value}, report -> %{report | resumed: [value | report.resumed]}
        {:interrupted, value}, report -> %{report | interrupted: [value | report.interrupted]}
        {:expired, value}, report -> %{report | expired: report.expired ++ value}
        {:error, value}, report -> %{report | errors: [value | report.errors]}
      end)

    report =
      report
      |> Map.update!(:resumed, &Enum.reverse/1)
      |> Map.update!(:interrupted, &Enum.reverse/1)
      |> Map.update!(:errors, &Enum.reverse/1)

    {report, reschedule_control_timer(state)}
  end

  defp reconcile_claim(state, claim, correlation_id) do
    context = %Context{
      claim: claim,
      actor_id: state.actor_id,
      correlation_id: correlation_id,
      started_at: claim.attempt.started_at,
      options: state.backend_options
    }

    inspection = safe_backend_call(fn -> state.agent_backend.inspect(context) end)
    refreshed_at = state.now_fn.()

    case state.task_store.refresh_claim(claim, refreshed_at) do
      {:ok, refreshed_claim} ->
        context = %{context | claim: refreshed_claim}

        cond do
          deadline_reached?(refreshed_claim.runtime_deadline_at, refreshed_at) ->
            state =
              start_recovered_stop(
                state,
                context,
                :runtime_timeout,
                "runtime deadline reached during restart inspection",
                refreshed_at,
                cancellation_supported?(state)
              )

            {{:interrupted, %{claim: refreshed_claim, action: :runtime_timeout}}, state}

          safe_resume?(state, refreshed_claim, inspection) ->
            case start_resumed_execution(state, context, refreshed_at) do
              {:ok, state} ->
                {{:resumed, %{claim: refreshed_claim, action: :resumed}}, state}

              {:error, reason, state} ->
                state =
                  start_recovered_stop(
                    state,
                    context,
                    :interrupted,
                    "failed to start supervised resume worker: #{inspect(reason)}",
                    refreshed_at,
                    cancellation_supported?(state)
                  )

                {{:interrupted, %{claim: refreshed_claim, reason: reason}}, state}
            end

          true ->
            reason = restart_interruption_reason(inspection, refreshed_claim)

            state =
              start_recovered_stop(
                state,
                context,
                :interrupted,
                reason,
                refreshed_at,
                cancellation_supported?(state)
              )

            {{:interrupted, %{claim: refreshed_claim, reason: reason}}, state}
        end

      {:error, :stale_backend_event} ->
        expired =
          state.task_store.reconcile_expired(
            refreshed_at,
            state.actor_id,
            correlation_id,
            Map.keys(state.active)
          )

        {{:expired, expired}, state}

      {:error, reason} ->
        {{:error, %{claim: claim, reason: reason}}, state}
    end
  end

  defp start_resumed_execution(state, %Context{} = context, observed_at) do
    coordinator = self()

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           receive do
             :begin_resume ->
               Sxf.Execution.Worker.resume(coordinator, context, state.agent_backend)
           end
         end) do
      {:ok, pid} ->
        monitor_ref = Process.monitor(pid)
        claim = context.claim

        entry = %{
          claim: claim,
          context: context,
          pid: pid,
          monitor_ref: monitor_ref,
          control_pid: nil,
          status: :running,
          mode: :resume,
          dispatch_key: "restart-resume:#{claim.lease.id}",
          renewal_sequence: claim.renewal_sequence,
          next_renewal_at:
            DateTime.add(
              claim.lease.heartbeat_at || claim.lease.acquired_at,
              state.lease_renewal_interval_ms,
              :millisecond
            ),
          runtime_deadline_at: claim.runtime_deadline_at,
          resumed_at: observed_at
        }

        state =
          state
          |> put_entry(entry)
          |> put_monitor(monitor_ref, claim.lease.id)
          |> reschedule_control_timer()

        send(pid, :begin_resume)
        {:ok, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp start_recovered_stop(state, context, kind, reason, observed_at, cancel?) do
    entry = %{
      claim: context.claim,
      context: context,
      pid: nil,
      monitor_ref: nil,
      control_pid: nil,
      status: :running,
      mode: :resume,
      dispatch_key: "restart-recovery:#{context.claim.lease.id}",
      renewal_sequence: context.claim.renewal_sequence,
      next_renewal_at: nil,
      runtime_deadline_at: context.claim.runtime_deadline_at
    }

    state
    |> put_entry(entry)
    |> begin_control_stop(entry, kind, reason, observed_at, cancel?)
    |> reschedule_control_timer()
  end

  defp safe_resume?(state, claim, {:ok, :running}) do
    capabilities = safe_backend_call(fn -> state.agent_backend.capabilities() end)

    match?(%{continuation: true}, capabilities) and
      is_binary(claim.attempt.backend_session_id) and claim.attempt.backend_session_id != ""
  end

  defp safe_resume?(_state, _claim, _inspection), do: false

  defp cancellation_supported?(state) do
    match?(%{cancellation: true}, safe_backend_call(fn -> state.agent_backend.capabilities() end))
  end

  defp restart_interruption_reason({:ok, :running}, claim) do
    if is_binary(claim.attempt.backend_session_id) and claim.attempt.backend_session_id != "" do
      "backend continuation is unsupported; running session cannot be safely reattached"
    else
      "running backend session has no durable session identity for safe reattachment"
    end
  end

  defp restart_interruption_reason({:ok, :finished}, _claim),
    do: "backend reported finished without a durable accepted completion event"

  defp restart_interruption_reason({:ok, :missing}, _claim),
    do: "coordinator restart found no running backend session"

  defp restart_interruption_reason({:error, reason}, _claim),
    do: "backend inspection failed: #{inspect(reason)}"

  defp restart_interruption_reason(other, _claim),
    do: "backend inspection returned an unknown state: #{inspect(other)}"

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

  defp normalize_backend_result(%Result{outcome: outcome} = result)
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

  defp reschedule_control_timer(%{automatic_timers: false} = state) do
    cancel_control_timer(state)
  end

  defp reschedule_control_timer(state) do
    deadline = next_control_deadline(state)

    if deadline == state.control_timer_deadline and is_reference(state.control_timer_ref) do
      state
    else
      state = cancel_control_timer(state)

      if deadline do
        token = make_ref()
        delay = max(DateTime.diff(deadline, state.now_fn.(), :millisecond), 0)
        ref = Process.send_after(self(), {:control_tick, token}, delay)

        %{
          state
          | control_timer_ref: ref,
            control_timer_deadline: deadline,
            control_timer_token: token
        }
      else
        state
      end
    end
  end

  defp cancel_control_timer(%{control_timer_ref: nil} = state), do: state

  defp cancel_control_timer(state) do
    Process.cancel_timer(state.control_timer_ref)

    %{
      state
      | control_timer_ref: nil,
        control_timer_deadline: nil,
        control_timer_token: nil
    }
  end

  defp next_control_deadline(state) do
    entry_deadlines =
      state.active
      |> Map.values()
      |> Enum.filter(&(&1.status == :running))
      |> Enum.flat_map(fn entry ->
        [entry.next_renewal_at, entry.runtime_deadline_at, entry.claim.lease.expires_at]
      end)

    [state.next_reconciliation_at | entry_deadlines]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      deadlines -> Enum.min(deadlines, DateTime)
    end
  end

  defp reset_reconciliation_deadline(state, observed_at) do
    %{
      state
      | next_reconciliation_at: DateTime.add(observed_at, state.control_tick_ms, :millisecond)
    }
  end

  defp deadline_reached?(nil, _observed_at), do: false

  defp deadline_reached?(deadline, observed_at),
    do: DateTime.compare(observed_at, deadline) != :lt

  defp validate_timing_config(lease_ttl_ms, renewal_interval_ms, control_tick_ms)
       when is_integer(lease_ttl_ms) and is_integer(renewal_interval_ms) and
              is_integer(control_tick_ms) do
    cond do
      lease_ttl_ms <= 0 -> {:error, :lease_ttl_must_be_positive}
      renewal_interval_ms <= 0 -> {:error, :lease_renewal_interval_must_be_positive}
      renewal_interval_ms >= lease_ttl_ms -> {:error, :lease_renewal_interval_must_precede_ttl}
      control_tick_ms <= 0 -> {:error, :control_tick_must_be_positive}
      true -> :ok
    end
  end

  defp validate_timing_config(_lease_ttl_ms, _renewal_interval_ms, _control_tick_ms),
    do: {:error, :timing_values_must_be_integers}

  defp safe_backend_call(fun) do
    fun.()
  rescue
    error -> {:error, {:exception, error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason}}
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

  def resume(coordinator, %Context{} = context, agent_backend) do
    lease_id = context.claim.lease.id

    emit = fn event ->
      GenServer.call(coordinator, {:backend_event, lease_id, event}, 30_000)
    end

    result = safe_call(fn -> agent_backend.resume(context, emit) end)
    send(coordinator, {:execution_finished, lease_id, self(), result, []})
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
