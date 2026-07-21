# SXF MODIFICATION NOTICE
# Modified from openai/symphony@633eae740f807de18007f5a9a25e2e0d206afdf4,
# original path elixir/config/config.exs. SXF default-denies host hooks and provider-native tools;
# upstream conformance tests explicitly enable them. This file remains Apache-2.0 licensed.

import Config

config :symphony_elixir,
  host_hooks_enabled: false,
  provider_native_tools_enabled: false

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

if config_env() == :test do
  config :symphony_elixir,
    workflow_file_path: Path.expand("../test/fixtures/startup_workflow.md", __DIR__),
    host_hooks_enabled: true,
    provider_native_tools_enabled: true
end
