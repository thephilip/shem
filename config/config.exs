import Config

config :shem, trust_gate_enabled: true

import_config "#{config_env()}.exs"
