import Config

config :sxf_core, Sxf.Repo,
  database: Path.expand("../var/sxf_core_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

config :logger, level: :warning
