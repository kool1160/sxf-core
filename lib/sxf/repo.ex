defmodule Sxf.Repo do
  use Ecto.Repo,
    otp_app: :sxf_core,
    adapter: Ecto.Adapters.SQLite3
end
