defmodule Sxf.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Sxf.Repo], strategy: :one_for_one, name: Sxf.Supervisor)
  end
end
