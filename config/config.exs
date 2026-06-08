import Config

config :shem, trust_gate_enabled: true
config :shem, spawn_agent_timeout_ms: 300_000
config :shem, spawn_agent_max_depth: 3

config :shem,
  executor_backend: :auto,
  executor_image: "debian:12-slim",
  executor_network: :default

if File.exists?("config/user_presets.exs"), do: import_config("user_presets.exs")

import_config "#{config_env()}.exs"
