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
    {Shem.LLM.Middleware.RouterTransport, []}
  ],
  llm_routes: %{
    # Local, keyless: LM Studio / OpenAI-compatible server on :1234.
    default: {:openai, "qwen"}
    # Cloud (needs ANTHROPIC_API_KEY): default: {:anthropic, "claude-sonnet-4-6"}
  },
  llm_models: %{default: "qwen"},
  llm_openai_base_url: "http://localhost:1234",
  llm_openai_api_key: "lm-studio",
  llm_max_tokens: 4096,
  llm_budget_limit: 500_000,
  llm_soft_threshold: 0.8

config :libcluster,
  topologies: [
    shem: [
      strategy: Cluster.Strategy.Gossip,
      config: [port: 45892, multicast_addr: "230.1.1.251"]
    ]
  ]

config :shem, start_cluster: true
config :shem, budget_node_tokens: 500_000
config :shem, lab_executor_node: nil

config :shem,
  adversarial_max_rounds: 5,
  adversarial_agent_timeout_ms: 300_000

config :shem, shadow_agent_enabled: true
config :shem, shadow_agent_poll_ms: 2_000

config :shem,
  executor_image_python: "python:3.12-slim",
  port_pool_size: 2,
  start_port_pool: true
