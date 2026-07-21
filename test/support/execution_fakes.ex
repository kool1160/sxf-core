defmodule Sxf.ExecutionFakes.Workspace do
  @behaviour Sxf.Execution.WorkspaceBackend
  import Kernel, except: [inspect: 1]

  @impl true
  def prepare(context) do
    notify(context, :workspace_prepare)

    case context.options[:workspace] do
      :unavailable -> {:error, :unavailable}
      _ -> {:ok, %{id: "workspace-#{context.claim.task.id}"}}
    end
  end

  @impl true
  def inspect(context), do: {:ok, context.workspace}

  @impl true
  def release(context) do
    notify(context, :workspace_release)
    :ok
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
    :ok
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

      :blocking ->
        receive do
          :continue -> run_events(context, emit, :success)
        end

      scenario ->
        run_events(context, emit, scenario)
    end
  end

  @impl true
  def resume(context, emit), do: start(context, emit)

  @impl true
  def inspect(context), do: {:ok, context.options[:inspect] || :missing}

  @impl true
  def cancel(_context), do: :ok

  defp run_events(context, emit, scenario) do
    events = context.options[:events] || [default_started_event(context)]

    case Enum.reduce_while(events, :ok, fn event, :ok ->
           case emit.(event) do
             :ok -> {:cont, :ok}
             {:error, reason} -> {:halt, {:error, reason}}
           end
         end) do
      :ok ->
        {:ok, result(scenario)}

      {:error, {:budget_exhausted, _metrics} = reason} ->
        {:ok, %Result{outcome: :deterministic_failure, reason: Kernel.inspect(reason)}}

      {:error, reason} ->
        {:error, {:event_rejected, reason}}
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
