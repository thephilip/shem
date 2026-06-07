# Phase 16 — Dockerfile & OTP Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package Shem as an OTP release, containerise it with a multi-stage Dockerfile and two-node Docker Compose cluster, and add `--headless` CLI flag + `SHEM_DATA_DIR` configurable data paths.

**Architecture:** Four independent tasks in dependency order: (1) runtime config changes that make prod-safe, (2) mix.exs release stanza + prod.exs, (3) Dockerfile + .dockerignore, (4) docker-compose.yml. All commits go directly to master. No new modules — this is pure config/infra.

**Tech Stack:** Elixir 1.19.5 / OTP 29, `mix release`, Docker multi-stage build (`hexpm/elixir:1.19.5-erlang-29-debian-bookworm-20250407-slim` builder, `debian:bookworm-slim` runtime), libcluster `Cluster.Strategy.DNSPoll`, Docker Compose v2.

---

## Context for All Tasks

**Key files:**
- `config/runtime.exs` — evaluated at VM startup, after all compile-time config; use for env-var-driven config
- `config/prod.exs` — compile-time production config; imported by `config/config.exs` via `import_config "#{config_env()}.exs"`
- `lib/shem/trust/store.ex` — reads `Application.get_env(:shem, :trust_store_path, @default_path)` in `init/1`
- `lib/shem/agent/preset_store.ex` — reads `Application.get_env(:shem, :preset_store_path, @default_path)` in `init/1`
- `test/exs` sets `config :shem, trust_store_path: "tmp/test_trust.dets"` — must not be overridden by runtime.exs

**DETS path override rule:** Only set `trust_store_path` / `preset_store_path` in `runtime.exs` when `SHEM_DATA_DIR` is explicitly set (non-nil). This avoids stomping on the test config.

**waf patch:** `mix.exs` aliases `deps.get` and `deps.compile` to copy `priv/waf` (waf 2.1.4) into `deps/ex_termbox/c_src/termbox/waf`. In the Dockerfile, `priv/` must be copied before `mix deps.get` so the patch can fire.

---

## Task 1: `runtime.exs` — headless flag + SHEM_DATA_DIR + cluster strategy

**Files:**
- Modify: `config/runtime.exs`

- [ ] **Step 1: Replace `config/runtime.exs` with the full updated content**

```elixir
import Config

# --headless CLI flag or SHEM_NO_TUI=1 disables the TUI
if System.get_env("SHEM_NO_TUI") == "1" or "--headless" in System.argv() do
  config :shem, start_tui: false
end

# SHEM_DATA_DIR overrides DETS file locations — only when explicitly set,
# so test config's trust_store_path is never clobbered.
case System.get_env("SHEM_DATA_DIR") do
  nil ->
    :ok

  data_dir ->
    config :shem,
      trust_store_path: Path.join(data_dir, "trust.dets"),
      preset_store_path: Path.join(data_dir, "preset_store.dets")
end

# Cluster topology — "dns" for Docker/K8s, default "gossip" for bare metal
topology =
  case System.get_env("LIBCLUSTER_STRATEGY", "gossip") do
    "dns" ->
      query = System.get_env("LIBCLUSTER_DNS_QUERY", "shem")

      [
        shem: [
          strategy: Cluster.Strategy.DNSPoll,
          config: [query: query, node_basename: "shem", polling_interval: 5_000]
        ]
      ]

    _ ->
      [
        shem: [
          strategy: Cluster.Strategy.Gossip,
          config: [port: 45892, multicast_addr: "230.1.1.251"]
        ]
      ]
  end

config :libcluster, topologies: topology
```

- [ ] **Step 2: Run the test suite to confirm no regression**

```bash
cd /home/philip/Downloads/_project/shem
mix test 2>&1 | tail -5
```

Expected: `554 passed` (or higher), 0 failures.

- [ ] **Step 3: Verify --headless flag works**

```bash
SHEM_NO_TUI=0 mix run --no-halt -- --headless &
sleep 2
kill %1
```

Expected: starts without TUI crash (no `RuntimeError` about missing TTY). May show cluster/MCP startup logs — that is fine.

- [ ] **Step 4: Commit**

```bash
git add config/runtime.exs
git commit -m "feat: runtime.exs — --headless flag, SHEM_DATA_DIR, config-driven cluster strategy"
```

---

## Task 2: OTP Release Config (`mix.exs` + `config/prod.exs`)

**Files:**
- Modify: `mix.exs` — add `releases:` stanza to `project/0`
- Create: `config/prod.exs`

- [ ] **Step 1: Add `releases:` to `mix.exs`**

In `project/0`, add `releases: releases()` to the keyword list:

```elixir
def project do
  [
    app: :shem,
    version: "0.1.0",
    elixir: "~> 1.19",
    start_permanent: Mix.env() == :prod,
    deps: deps(),
    aliases: aliases(),
    releases: releases()
  ]
end
```

Add a private `releases/0` function after `aliases/0`:

```elixir
defp releases do
  [
    shem: [
      include_executables_for: [:unix],
      applications: [runtime_tools: :permanent]
    ]
  ]
end
```

- [ ] **Step 2: Create `config/prod.exs`**

```elixir
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
```

- [ ] **Step 3: Verify prod compilation succeeds**

```bash
MIX_ENV=prod mix compile 2>&1 | tail -10
```

Expected: no errors. May show warnings about unused variables — that is fine.

- [ ] **Step 4: Build the OTP release**

```bash
MIX_ENV=prod mix release --overwrite 2>&1 | tail -15
```

Expected output ends with something like:
```
Release created at _build/prod/rel/shem
```

No errors. Warnings are fine.

- [ ] **Step 5: Smoke-test the release binary in headless mode**

```bash
SHEM_NO_TUI=1 _build/prod/rel/shem/bin/shem start &
sleep 3
_build/prod/rel/shem/bin/shem stop
```

Expected: starts without crash, `stop` exits cleanly.

- [ ] **Step 6: Run tests to confirm no regression**

```bash
mix test 2>&1 | tail -5
```

Expected: same pass count as before, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add mix.exs config/prod.exs
git commit -m "feat: OTP release config — mix.exs releases stanza + prod.exs"
```

---

## Task 3: `Dockerfile` + `.dockerignore`

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`

**Prerequisites:** Docker installed and daemon running (`docker info` must succeed).

- [ ] **Step 1: Create `.dockerignore`**

```
_build/
deps/
tmp/
.git/
test/
docs/
erl_crash.dump
run_qwen.sh
smoke_test.exs
OPENCODE_PROMPT.txt
*.md
```

- [ ] **Step 2: Create `Dockerfile`**

```dockerfile
# ── Builder ────────────────────────────────────────────────────────────────────
FROM hexpm/elixir:1.19.5-erlang-29-debian-bookworm-20250407-slim AS builder

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential git python3 && \
    rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# Copy mix files and priv/ first — priv/waf must exist before deps.get
# so the waf patch alias can fire after deps are downloaded.
COPY mix.exs mix.lock ./
COPY priv/ ./priv/

RUN MIX_ENV=prod mix deps.get --only prod

# Copy config before deps.compile (compile-time config is read during compilation)
COPY config/ ./config/

RUN MIX_ENV=prod mix deps.compile

COPY lib/ ./lib/

RUN MIX_ENV=prod mix release

# ── Runtime ────────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends libncurses6 libssl3 libstdc++6 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/_build/prod/rel/shem ./

# Always headless in a container; data goes in /data/shem (mount a volume here)
ENV SHEM_NO_TUI=1
ENV SHEM_DATA_DIR=/data/shem

VOLUME ["/data/shem"]

ENTRYPOINT ["/app/bin/shem", "start"]
```

- [ ] **Step 3: Build the Docker image**

```bash
docker build -t shem:local . 2>&1 | tail -20
```

Expected: `Successfully built <sha>` and `Successfully tagged shem:local`. No errors.

This will take several minutes on first run (downloading base images and deps). Subsequent builds are fast due to layer caching.

- [ ] **Step 4: Verify the image runs headlessly**

```bash
docker run --rm -e RELEASE_COOKIE=test_cookie -e RELEASE_NODE=shem@localhost shem:local &
sleep 4
docker stop $(docker ps -q --filter ancestor=shem:local)
```

Expected: container starts, prints OTP boot logs, no crash. `docker stop` exits it cleanly.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile .dockerignore
git commit -m "feat: Dockerfile — multi-stage OTP release build"
```

---

## Task 4: `docker-compose.yml`

**Files:**
- Create: `docker-compose.yml`

**Prerequisites:** Task 3 complete (`shem:local` image built successfully).

- [ ] **Step 1: Create `docker-compose.yml`**

```yaml
services:
  shem1:
    build: .
    hostname: shem1
    environment:
      RELEASE_COOKIE: shem_cookie
      RELEASE_NODE: shem1@shem1
      LIBCLUSTER_STRATEGY: dns
      LIBCLUSTER_DNS_QUERY: shem
    volumes:
      - shem1_data:/data/shem
    networks:
      - shem

  shem2:
    build: .
    hostname: shem2
    environment:
      RELEASE_COOKIE: shem_cookie
      RELEASE_NODE: shem2@shem2
      LIBCLUSTER_STRATEGY: dns
      LIBCLUSTER_DNS_QUERY: shem
    volumes:
      - shem2_data:/data/shem
    networks:
      - shem

volumes:
  shem1_data:
  shem2_data:

networks:
  shem: {}
```

**Why `hostname: shem1`:** OTP distribution requires the node name's hostname part to resolve to the container. Docker Compose sets each container's hostname to its service name by default, but specifying it explicitly is more resilient. `RELEASE_NODE=shem1@shem1` matches the hostname `shem1`.

**Why `LIBCLUSTER_DNS_QUERY: shem`:** Docker's internal DNS resolves the network alias `shem` (the network name) to all container IPs on that network. DNSPoll queries this every 5 seconds and connects new nodes automatically.

- [ ] **Step 2: Start the cluster**

```bash
docker compose up -d
```

Expected: both services start (`shem1` and `shem2` show as `Started`).

- [ ] **Step 3: Verify both nodes are running**

```bash
sleep 5
docker compose logs --tail=30
```

Expected: logs from both `shem1` and `shem2`. Look for OTP boot messages and libcluster connection lines like `[libcluster] Connected nodes: [:"shem2@shem2"]` in shem1's logs (or vice versa). No crash loops (no repeated "Restarting" messages).

- [ ] **Step 4: Tear down**

```bash
docker compose down
```

Expected: both containers stopped and removed.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: docker-compose — two-node Shem cluster with DNS-based libcluster"
```

---

## Self-Review Checklist (coordinator use only — do not implement)

- [x] `--headless` flag — Task 1
- [x] `SHEM_DATA_DIR` env var → `trust_store_path` + `preset_store_path` — Task 1
- [x] Test config not clobbered (nil guard) — Task 1
- [x] `LIBCLUSTER_STRATEGY=dns` → DNSPoll; default → Gossip — Task 1
- [x] `releases:` stanza in `mix.exs` — Task 2
- [x] `config/prod.exs` — Task 2
- [x] `MIX_ENV=prod mix release` verified — Task 2
- [x] Multi-stage Dockerfile (builder + runtime) — Task 3
- [x] `priv/` copied before `mix deps.get` (waf patch order) — Task 3
- [x] `python3` in builder stage — Task 3
- [x] `libncurses6 libssl3 libstdc++6` in runtime stage — Task 3
- [x] `SHEM_NO_TUI=1` + `SHEM_DATA_DIR=/data/shem` in image ENV — Task 3
- [x] `.dockerignore` — Task 3
- [x] `docker-compose.yml` with two nodes, shared network, named volumes — Task 4
- [x] `hostname` matches `RELEASE_NODE` — Task 4
- [x] `LIBCLUSTER_DNS_QUERY: shem` — Task 4
