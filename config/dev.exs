import Config

config :shem, start_tui: true
config :shem, mcp_port: 4000
config :shem, mcp_clients: []
config :shem, mcp_client_timeout_ms: 5_000

config :shem,
  llm_pipeline: [
    {Shem.LLM.Middleware.BudgetCheck,
     [budget_server: Shem.LLM.BudgetServer]},
    {Shem.LLM.Middleware.EventLogger, []},
    {Shem.LLM.Middleware.LlamaCppTransport,
     [url: "http://localhost:8080"]}
  ],
  llm_models: %{default: "gemma4"},
  llm_llama_cpp_url: "http://localhost:8080",
  llm_budget_limit: 500_000,
  llm_soft_threshold: 0.8
