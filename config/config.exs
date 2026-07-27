import Config

config :sxf_core,
  ecto_repos: [Sxf.Repo]

config :sxf_core, Sxf.Repo,
  database: Path.expand("../var/sxf_core.db", __DIR__),
  default_transaction_mode: :immediate,
  journal_mode: :wal,
  synchronous: :normal,
  foreign_keys: :on,
  busy_timeout: 5_000,
  pool_size: 5

# The durable coordinator is wired for explicit startup, but remains disabled until a caller
# supplies approved backend modules. Imported Symphony is never supervised as a workflow owner.
config :sxf_core, execution_coordinator_enabled: false

# Imported Symphony is compile-time foundation code only. These defense-in-depth switches remain
# false until a later SXF integration supplies durable authorization and a Linux-container worker.
config :symphony_elixir,
  host_hooks_enabled: false,
  provider_native_tools_enabled: false

import_config "#{config_env()}.exs"
