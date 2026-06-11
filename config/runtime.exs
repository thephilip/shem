import Config

# ── Headless mode ──────────────────────────────────────────────────────────────
if System.get_env("SHEM_NO_TUI") == "1" or "--headless" in System.argv() do
  config :shem, start_tui: false
end

if System.get_env("SHEM_NO_SHADOW") == "1" do
  config :shem, shadow_agent_enabled: false
end

# ── Load user YAML config (~/.config/shem/config.yaml) ────────────────────────
# Guarded by RELEASE_NAME: only applies inside an OTP release. During `mix test`
# this env var is absent, so the user's personal config never overrides test.exs.
if System.get_env("RELEASE_NAME") do
  yaml_path = Path.join([System.user_home!(), ".config", "shem", "config.yaml"])

  user_config =
    case File.read(yaml_path) do
      {:ok, content} ->
        Application.ensure_all_started(:yamerl)
        case YamlElixir.read_from_string(content) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end
      _ ->
        %{}
    end

  # Apply LLM config from YAML
  with %{"llm" => %{"default" => llm}} <- user_config,
       backend_str when is_binary(backend_str) <- Map.get(llm, "backend"),
       backend_atom <- String.to_atom(backend_str),
       model when is_binary(model) <- Map.get(llm, "model") do

    config :shem, llm_routes: %{default: {backend_atom, model}}

    case backend_atom do
      :ollama ->
        url = Map.get(llm, "url", "http://localhost:11434")
        config :shem, llm_ollama_url: url
      :llama_cpp ->
        url = Map.get(llm, "url", "http://localhost:1234")
        config :shem, llm_llama_cpp_url: url
      _ ->
        :ok
    end

    # Inject api_key into env var so existing transports pick it up
    api_key = Map.get(llm, "api_key", "")
    if api_key != "" do
      env_var = case backend_atom do
        :anthropic -> "ANTHROPIC_API_KEY"
        :openai    -> "OPENAI_API_KEY"
        _          -> nil
      end
      if env_var, do: System.put_env(env_var, api_key)
    end
  end

  # Apply server config from YAML
  with %{"server" => server} <- user_config do
    if port = Map.get(server, "port"), do: config(:shem, mcp_port: port)
    if host = Map.get(server, "host"), do: config(:shem, mcp_host: host)
  end

  # Apply tui config from YAML (only if not already set by --headless)
  if Map.has_key?(user_config, "tui") and
     not (System.get_env("SHEM_NO_TUI") == "1" or "--headless" in System.argv()) do
    config :shem, start_tui: Map.get(user_config, "tui", true)
  end

  # Apply executor config from YAML
  with %{"executor" => executor} <- user_config do
    if backend = Map.get(executor, "backend"),
      do: config(:shem, executor_backend: String.to_atom(backend))
    if image = Map.get(executor, "image"),
      do: config(:shem, executor_image: image)
  end

  # Apply data_dir from YAML (overrides default paths)
  with %{"data_dir" => data_dir} <- user_config,
       expanded <- Path.expand(data_dir),
       true <- File.dir?(expanded) or (File.mkdir_p!(expanded) && true) do
    config :shem,
      trust_store_path:   Path.join(expanded, "trust.dets"),
      preset_store_path:  Path.join(expanded, "preset_store.dets"),
      memory_store_path:  Path.join(expanded, "memory.dets"),
      event_log_path:     Path.join(expanded, "lab/events")
  end
end

# SHEM_DATA_DIR env var overrides YAML data_dir (higher priority, works in all envs)
case System.get_env("SHEM_DATA_DIR") do
  nil -> :ok
  data_dir ->
    config :shem,
      trust_store_path: Path.join(data_dir, "trust.dets"),
      preset_store_path: Path.join(data_dir, "preset_store.dets"),
      memory_store_path: Path.join(data_dir, "memory.dets"),
      event_log_path: Path.join(data_dir, "lab/events")
end

# ── First-run detection ────────────────────────────────────────────────────────
# Skip in test env (no RELEASE_NAME) and when running eval subcommands.
is_eval = "eval" in System.argv()

unless is_eval or System.get_env("SHEM_SKIP_CONFIG_CHECK") == "1" or
       System.get_env("RELEASE_NAME") == nil do
  llm_routes = Application.get_env(:shem, :llm_routes, %{})
  has_env_key =
    System.get_env("ANTHROPIC_API_KEY") not in [nil, ""] or
    System.get_env("OPENAI_API_KEY") not in [nil, ""]

  configured = llm_routes != %{} or has_env_key

  unless configured do
    IO.puts("""

    ✦ Shem is not configured yet.

      Run `shem setup` to configure your LLM backend, or set
      ANTHROPIC_API_KEY (or OPENAI_API_KEY) in your environment
      and re-run `shem start`.

      Docs: https://github.com/thephilip/shem
    """)
    System.halt(1)
  end
end

# ── Cluster topology ───────────────────────────────────────────────────────────
topology =
  case System.get_env("LIBCLUSTER_STRATEGY", "gossip") do
    "dns" ->
      query = System.get_env("LIBCLUSTER_DNS_QUERY", "shem")
      [shem: [strategy: Cluster.Strategy.DNSPoll,
              config: [query: query, node_basename: "shem", polling_interval: 5_000]]]
    _ ->
      [shem: [strategy: Cluster.Strategy.Gossip,
              config: [port: 45892, multicast_addr: "230.1.1.251"]]]
  end

config :libcluster, topologies: topology
