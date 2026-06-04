import Config

# Allow headless runs (smoke tests, CI) without a real TTY
if System.get_env("SHEM_NO_TUI") == "1" do
  config :shem, start_tui: false
end
