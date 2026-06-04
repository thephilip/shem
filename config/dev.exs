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
    {Shem.LLM.Middleware.OllamaTransport,
     [url: "http://localhost:11434"]}
  ],
  llm_models: %{default: "llama3:latest"},
  llm_ollama_url: "http://localhost:11434",
  llm_budget_limit: 500_000,
  llm_soft_threshold: 0.8
