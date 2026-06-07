# Phase 16 — Dockerfile & OTP Release Design

## Goal

Package Shem as an OTP release, containerise it with a multi-stage Dockerfile, and provide a two-node Docker Compose cluster for local and cloud deployment. Add `--headless` as a convenient CLI flag alongside the existing `SHEM_NO_TUI=1` env var. Make persistent data paths configurable via `SHEM_DATA_DIR` for clean volume mounting.

---

## Context

Shem is an Elixir/OTP application on Elixir 1.19.5 / OTP 29, running on Garuda Linux (Arch). It uses:

- `ratatouille` / `ex_termbox` (TUI — NIF, compile-time only in headless mode)
- `libcluster` with Gossip strategy (UDP multicast) for bare-metal clustering
- `horde` for distributed registry and supervisor
- `bandit` / `plug` for the MCP HTTP server
- DETS files for persistent state (`trust.dets`, `preset_store.dets`) currently at `~/.config/shem/`
- `priv/waf` patch for ex_termbox's bundled waf 2.0.14 (incompatible with Python 3.11+)

Phase 15 added OpenAI and Anthropic transports, making cloud-pointed deployments genuinely useful.

---

## Design

### `--headless` Flag

`runtime.exs` gains a one-liner alongside the existing `SHEM_NO_TUI` check:

```elixir
if System.get_env("SHEM_NO_TUI") == "1" or "--headless" in System.argv() do
  config :shem, start_tui: false
end
```

This enables `mix run --no-halt -- --headless` for local dev convenience. OTP release users use `SHEM_NO_TUI=1` (env vars are the release convention — `System.argv()` is not reliable in release start scripts).

---

### `SHEM_DATA_DIR` — Configurable Persistent Data Path

`runtime.exs` reads the env var and sets an application config key:

```elixir
data_dir = System.get_env("SHEM_DATA_DIR", Path.join([System.user_home!(), ".config", "shem"]))
config :shem, data_dir: data_dir
```

`Shem.Trust.Store` and `Shem.Agent.PresetStore` currently resolve their DETS paths via `@default_path` module attributes (compile-time). These are changed to read from application config at runtime in `init/1`:

```elixir
defp dets_path do
  Path.join(Application.get_env(:shem, :data_dir, Path.join([System.user_home!(), ".config", "shem"])), "trust.dets")
end
```

The directory is created if it doesn't exist (`File.mkdir_p!/1`) before opening the DETS file.

**Backwards compat:** When `SHEM_DATA_DIR` is unset, the resolved path is identical to the current default — no change for existing bare-metal installs.

---

### OTP Release (`mix.exs`)

```elixir
releases: [
  shem: [
    include_executables_for: [:unix],
    applications: [runtime_tools: :permanent]
  ]
]
```

`config/prod.exs` is created with production-safe defaults:

```elixir
import Config

config :shem, start_tui: false
config :shem, start_mcp: true
config :shem, mcp_port: 4000
config :shem, start_cluster: true
config :shem, start_adversarial: true
config :shem, trust_gate_enabled: true
config :shem, adversarial_max_rounds: 5
config :shem, adversarial_agent_timeout_ms: 300_000
config :shem,
  llm_pipeline: [
    {Shem.LLM.Middleware.BudgetCheck, [budget_server: Shem.LLM.BudgetServer]},
    {Shem.LLM.Middleware.EventLogger, []},
    {Shem.LLM.Middleware.RouterTransport, []}
  ],
  llm_routes: %{default: {:llama_cpp, "qwen3.6-27b-uncensored-hauhaucs-balanced"}},
  llm_budget_limit: 500_000,
  llm_soft_threshold: 0.8
```

LLM routes, API keys, and node identity come from environment variables via `runtime.exs` in production — not hardcoded in `prod.exs`.

---

### Clustering — Config-Driven Strategy

`runtime.exs` selects the libcluster topology based on `LIBCLUSTER_STRATEGY`:

```elixir
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
```

| Environment | `LIBCLUSTER_STRATEGY` | Behaviour |
|---|---|---|
| Bare metal / LAN | unset (default `"gossip"`) | Existing Gossip UDP multicast — no change |
| Docker Compose | `"dns"` | DNSPoll on compose service name |
| K8s (Phase 17+) | `"dns"` | DNSPoll on headless service DNS |

**Why DNSPoll for Docker:** Docker Compose's internal DNS resolves the service name (e.g. `shem`) to all container IPs on the shared network. DNSPoll periodically queries this name and connects new nodes automatically. No multicast required.

---

### Dockerfile

Two-stage build.

**Builder** — `hexpm/elixir:1.19.5-erlang-29-debian-bookworm-20250407-slim`:

1. Install build deps: `build-essential git python3`
2. Copy `mix.exs`, `mix.lock` → `mix deps.get` (triggers waf patch via alias)
3. Copy `config/` → `mix deps.compile` (triggers waf patch)
4. Copy full source → `MIX_ENV=prod mix release`

The `priv/waf` patch applies automatically via the existing `deps.get` / `deps.compile` aliases.

**Runtime** — `debian:bookworm-slim`:

1. Install runtime libs: `libncurses6 libssl3 libstdc++6` (for ex_termbox NIF and OpenSSL)
2. Copy `_build/prod/rel/shem` from builder
3. `SHEM_NO_TUI=1` set in image (containers never need a TUI)
4. `ENTRYPOINT ["/app/bin/shem", "start"]`

```dockerfile
FROM hexpm/elixir:1.19.5-erlang-29-debian-bookworm-20250407-slim AS builder

WORKDIR /app
RUN apt-get update && apt-get install -y build-essential git python3 && rm -rf /var/lib/apt/lists/*

COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
COPY priv/ ./priv/
RUN MIX_ENV=prod mix deps.get

COPY config/ ./config/
RUN MIX_ENV=prod mix deps.compile

COPY lib/ ./lib/
RUN MIX_ENV=prod mix release

FROM debian:bookworm-slim AS runtime

WORKDIR /app
RUN apt-get update && apt-get install -y libncurses6 libssl3 libstdc++6 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/_build/prod/rel/shem ./

ENV SHEM_NO_TUI=1
ENV SHEM_DATA_DIR=/data/shem
VOLUME ["/data/shem"]

ENTRYPOINT ["/app/bin/shem", "start"]
```

---

### Docker Compose

Two nodes. Same image, different node identities and separate data volumes. Both on a shared `shem` network so Docker's internal DNS resolves the service name.

```yaml
services:
  shem1:
    build: .
    environment:
      RELEASE_COOKIE: shem_cookie
      RELEASE_NODE: shem1@shem1
      LIBCLUSTER_STRATEGY: dns
      LIBCLUSTER_DNS_QUERY: shem
    volumes:
      - shem1_data:/data/shem
    networks: [shem]
    hostname: shem1

  shem2:
    build: .
    environment:
      RELEASE_COOKIE: shem_cookie
      RELEASE_NODE: shem2@shem2
      LIBCLUSTER_STRATEGY: dns
      LIBCLUSTER_DNS_QUERY: shem
    volumes:
      - shem2_data:/data/shem
    networks: [shem]
    hostname: shem2

volumes:
  shem1_data:
  shem2_data:

networks:
  shem: {}
```

`RELEASE_NODE` uses the hostname so OTP distribution addresses match container DNS. `RELEASE_COOKIE` must be identical across nodes.

---

### `.dockerignore`

```
_build/
deps/
tmp/
.git/
*.md
test/
docs/
```

Keeps build context small — no compiled artifacts, no test files, no git history.

---

## File Map

| File | Action |
|---|---|
| `Dockerfile` | Create |
| `docker-compose.yml` | Create |
| `.dockerignore` | Create |
| `config/prod.exs` | Create |
| `config/runtime.exs` | Modify — `--headless` flag, `SHEM_DATA_DIR`, `LIBCLUSTER_STRATEGY` |
| `mix.exs` | Modify — add `releases:` config |
| `lib/shem/trust/store.ex` | Modify — runtime `data_dir` resolution in `init/1` |
| `lib/shem/agent/preset_store.ex` | Modify — runtime `data_dir` resolution in `init/1` |

---

## Testing Strategy

- `mix release` must succeed in CI (or locally): `MIX_ENV=prod mix release`
- Full test suite still passes: `mix test` (no regression from runtime.exs or store changes)
- `SHEM_DATA_DIR=/tmp/shem_test` used in any store tests that exercise path resolution
- Docker build: `docker build -t shem .` must complete without error
- Compose smoke: `docker compose up -d && sleep 5 && docker compose logs` — both nodes start, no crash loops

---

## Future Work

- **CI Pipeline (Phase 17):** GitHub Actions runs `mix test` + `MIX_ENV=prod mix release` on push. Docker build step optional.
- **K8s executor (Phase 18):** `LIBCLUSTER_STRATEGY=dns` + `LIBCLUSTER_DNS_QUERY=<headless-service>` works without code changes. The K8s executor adds pod-spawning Lab backends on top.
- **Multi-arch build:** `docker buildx` for ARM64 (Apple Silicon, Raspberry Pi). Not needed now.
