import Config

if config_env() == :prod do
  config :sxf_core, Sxf.Repo, database: System.fetch_env!("SXF_DATABASE_PATH")
end
