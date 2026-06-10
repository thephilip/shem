import Config

config :shem, start_tui: false
config :shem, start_mcp: false
config :shem, event_log_store: Shem.EventLog.FakeStore
config :shem, lab_dir: "tmp/test_lab"
config :shem, executor_timeout_ms: 200
config :shem, mcp_port: 4001
config :shem, mcp_clients: []
config :shem, mcp_client_timeout_ms: 200

config :shem, start_llm_stub: true

config :shem,
  llm_pipeline: [
    {Shem.LLM.Middleware.BudgetCheck,
     [budget_server: Shem.LLM.BudgetServer]},
    {Shem.LLM.Middleware.EventLogger, []},
    {Shem.LLM.StubTransport, [server: Shem.LLM.StubTransport.Server]}
  ],
  llm_models: %{default: "llama3:latest"},
  llm_budget_limit: 100_000,
  llm_soft_threshold: 0.8

config :shem,
  llm_routes: %{
    default: {:llama_cpp, "llama3:latest"}
  }

config :shem, start_cluster: false
config :shem, lab_executor_node: nil

config :shem, start_adversarial: false
config :shem, adversarial_max_rounds: 3
config :shem, adversarial_agent_timeout_ms: 5_000

config :shem, trust_store_path: "tmp/test_trust.dets"
config :shem, memory_store_path: "tmp/test_memory.dets"

config :shem, trust_gate_enabled: false
config :shem, spawn_agent_timeout_ms: 5_000
config :shem, spawn_agent_max_depth: 2

config :shem, executor_backend: :local

config :shem, shadow_agent_enabled: false
