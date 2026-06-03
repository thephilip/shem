import Config

config :shem, start_tui: false
config :shem, event_log_store: Shem.EventLog.FakeStore
config :shem, lab_dir: "tmp/test_lab"
config :shem, executor_timeout_ms: 200
