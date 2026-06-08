import Config

config :shem, trust_gate_enabled: true

config :shem,
  executor_backend: :auto,
  executor_image: "debian:12-slim",
  executor_network: :default

if File.exists?("config/user_presets.exs"), do: import_config("user_presets.exs")

import_config "#{config_env()}.exs"
