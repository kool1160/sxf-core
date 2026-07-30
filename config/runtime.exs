import Config

if config_env() == :prod do
  config :sxf_core, Sxf.Repo, database: System.fetch_env!("SXF_DATABASE_PATH")

  config :sxf_core, :evidence_store, root: System.fetch_env!("SXF_EVIDENCE_PATH")
end
