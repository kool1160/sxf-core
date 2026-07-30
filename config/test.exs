import Config

config :sxf_core, Sxf.Repo,
  database: Path.expand("../var/sxf_core_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

config :sxf_core, :evidence_store,
  root: Path.expand("../var/evidence_test", __DIR__),
  max_bytes: 1024 * 1024

config :logger, level: :warning
