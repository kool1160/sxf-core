defmodule Sxf.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [Sxf.Repo] ++
        if Application.get_env(:sxf_core, :execution_coordinator_enabled, false) do
          [{Sxf.Execution.Coordinator, Application.fetch_env!(:sxf_core, :execution_coordinator)}]
        else
          []
        end

    Supervisor.start_link(children, strategy: :one_for_one, name: Sxf.Supervisor)
  end
end
