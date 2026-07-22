defmodule Sxf.ExecutionFakes.Workspace do
  @behaviour Sxf.Execution.WorkspaceBackend
  import Kernel, except: [inspect: 1]

  @impl true
  def prepare(context) do
    notify(context, :workspace_prepare)

    case context.options[:workspace] do
      :unavailable ->
        {:error, :unavailable}

      _ ->
        {:ok,
         %{
           id: "workspace-#{context.claim.attempt.id}-#{context.claim.lease.fencing_token}"
         }}
    end
  end

  @impl true
  def inspect(context), do: {:ok, context.workspace}

  @impl true
  def release(context) do
    notify(context, :workspace_release)

    case context.options[:workspace_release] do
      :error -> {:error, :workspace_cleanup_failed}
      _ -> :ok
    end
  end

  defp notify(context, message) do
    if pid = context.options[:notify], do: send(pid, message)
  end
end

defmodule Sxf.ExecutionFakes.Sandbox do
  @behaviour Sxf.Execution.SandboxBackend
  import Kernel, except: [inspect: 1]

  @impl true
  def prepare(context) do
    notify(context, :sandbox_prepare)

    case context.options[:sandbox] do
      :unavailable -> {:error, :unavailable}
      _ -> {:ok, %{id: "sandbox-#{context.claim.attempt.id}"}}
    end
  end

  @impl true
  def inspect(context), do: {:ok, context.sandbox}

  @impl true
  def release(context) do
    notify(context, :sandbox_release)

    case context.options[:sandbox_release] do
      :error -> {:error, :sandbox_cleanup_failed}
      _ -> :ok
    end
  end

  defp notify(context, message) do
    if pid = context.options[:notify], do: send(pid, message)
  end
end

defmodule Sxf.ExecutionFakes.Agent do
  @behaviour Sxf.Execution.AgentBackend
  import Kernel, except: [inspect: 1]

  alias Sxf.Execution.{Event, Result}

  @impl true
  def capabilities do
    %{continuation: true, cancellation: true, inspection: true, usage: true}
  end

  @impl true
  def start(context, emit) do
    if pid = context.options[:notify], do: send(pid, {:agent_started, self()})

    case context.options[:scenario] || :success do
      :unavailable ->
        {:error, :unavailable}

      scenario when scenario in [:blocking, :hanging] ->
        receive do
          :continue -> run_events(context, emit, :success)
        end

      scenario when scenario in [:started_then_blocking, :started_then_hanging] ->
        with :ok <- emit_events(context, emit) do
          receive do
            :continue -> {:ok, result(:success)}
          end
        end

      :controllable ->
        controllable_loop(context, emit)

      scenario ->
        run_events(context, emit, scenario)
    end
  end

  @impl true
  def resume(context, emit) do
    if pid = context.options[:notify], do: send(pid, {:agent_resumed, self()})

    case context.options[:resume_scenario] || :success do
      :unavailable ->
        {:error, :unavailable}

      scenario when scenario in [:blocking, :hanging] ->
        receive do
          :continue -> {:ok, result(:success)}
        end

      scenario ->
        run_events(context, emit, scenario)
    end
  end

  @impl true
  def inspect(context) do
    case context.options[:inspect] || :missing do
      inspect when is_function(inspect, 1) -> inspect.(context)
      {:error, _reason} = error -> error
      state -> {:ok, state}
    end
  end

  @impl true
  def cancel(context) do
    if pid = context.options[:notify], do: send(pid, {:agent_cancelled, context.claim.attempt.id})

    case context.options[:cancel] do
      :error -> {:error, :cancel_failed}
      _ -> :ok
    end
  end

  defp run_events(context, emit, scenario) do
    case emit_events(context, emit) do
      :ok ->
        {:ok, result(scenario)}

      {:error, {:budget_exhausted, _metrics} = reason} ->
        {:ok, %Result{outcome: :deterministic_failure, reason: Kernel.inspect(reason)}}

      {:error, reason} ->
        {:error, {:event_rejected, reason}}
    end
  end

  defp emit_events(context, emit) do
    events = context.options[:events] || [default_started_event(context)]

    Enum.reduce_while(events, :ok, fn event, :ok ->
      case emit.(event) do
        :ok ->
          if pid = context.options[:notify], do: send(pid, {:event_emitted, event.id})
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp controllable_loop(context, emit) do
    receive do
      {:emit, event} ->
        case emit.(event) do
          :ok ->
            if pid = context.options[:notify], do: send(pid, {:event_emitted, event.id})
            controllable_loop(context, emit)

          {:error, reason} ->
            if pid = context.options[:notify], do: send(pid, {:event_rejected, reason})
            {:error, {:event_rejected, reason}}
        end

      :continue ->
        {:ok, result(:success)}
    end
  end

  defp default_started_event(context) do
    %Event{
      id: Ecto.UUID.generate(),
      sequence: context.claim.attempt.execution_event_sequence + 1,
      kind: :started,
      occurred_at: DateTime.add(context.started_at, 1, :millisecond),
      session_id: "fake-session-#{context.claim.attempt.id}",
      payload: %{backend: "fake"}
    }
  end

  defp result(:success), do: %Result{outcome: :success, reason: "fake execution succeeded"}

  defp result(:deterministic_failure),
    do: %Result{outcome: :deterministic_failure, reason: "fake deterministic failure"}

  defp result(:timeout), do: %Result{outcome: :timeout, reason: "fake timeout"}
  defp result(:cancelled), do: %Result{outcome: :cancelled, reason: "fake cancellation"}

  defp result(:backend_unavailable),
    do: %Result{outcome: :backend_unavailable, reason: "fake backend unavailable"}
end

defmodule Sxf.ExecutionFakes.AgentWithoutResume do
  @behaviour Sxf.Execution.AgentBackend

  alias Sxf.ExecutionFakes.Agent

  @impl true
  def capabilities, do: %{continuation: false, cancellation: true, inspection: true, usage: true}

  @impl true
  defdelegate start(context, emit), to: Agent

  @impl true
  defdelegate resume(context, emit), to: Agent

  @impl true
  defdelegate inspect(context), to: Agent

  @impl true
  defdelegate cancel(context), to: Agent
end
