import Config

config :shem, trust_gate_enabled: true
config :shem, progressive_hardening: true
config :shem, spawn_agent_timeout_ms: 300_000
config :shem, spawn_agent_max_depth: 3
config :shem, gc: [keep_events: 100_000]
config :shem, counterfactual: %{max_variants: 4, default_max_turns: 4, wall_clock_ms: 120_000}

config :shem,
  executor_backend: :auto,
  executor_image: "debian:12-slim",
  executor_network: :default

if File.exists?("config/user_presets.exs"), do: import_config("user_presets.exs")

import_config "#{config_env()}.exs"
