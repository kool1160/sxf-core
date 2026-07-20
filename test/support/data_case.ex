defmodule Sxf.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Sxf.Repo
      import Ecto.Query
      import Sxf.TestFixtures
    end
  end

  setup _tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Sxf.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Sxf.Repo, {:shared, self()})
    :ok
  end
end
