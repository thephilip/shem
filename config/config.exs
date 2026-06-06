import Config

config :shem, trust_gate_enabled: true

if File.exists?("config/user_presets.exs"), do: import_config("user_presets.exs")

import_config "#{config_env()}.exs"
