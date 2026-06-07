import Config

config :shem, start_tui: false
config :shem, mcp_port: 4000
config :shem, mcp_clients: []
config :shem, mcp_client_timeout_ms: 5_000
config :shem, start_cluster: true
config :shem, start_adversarial: true
config :shem, trust_gate_enabled: true
config :shem, adversarial_max_rounds: 5
config :shem, adversarial_agent_timeout_ms: 300_000
config :shem, budget_node_tokens: 500_000

config :shem,
  llm_pipeline: [
    {Shem.LLM.Middleware.BudgetCheck, [budget_server: Shem.LLM.BudgetServer]},
    {Shem.LLM.Middleware.EventLogger, []},
    {Shem.LLM.Middleware.RouterTransport, []}
  ],
  llm_routes: %{default: {:llama_cpp, "qwen3.6-27b-uncensored-hauhaucs-balanced"}},
  llm_models: %{default: "qwen3.6-27b-uncensored-hauhaucs-balanced"},
  llm_llama_cpp_url: "http://localhost:1234",
  llm_budget_limit: 500_000,
  llm_soft_threshold: 0.8
