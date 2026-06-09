# Shem — Feature Ideas (Ranked by Impact)

Scores: 1–10. **Score = leverage on adoption and differentiation, not implementation effort.**

---

## Strategic Vision: "AI with Git"

### The thesis

Every AI assistant today — OpenClaw, Hermes, ChatGPT, Claude, every single one — is a black box. You give it a task, it does something, you see the result, and you have no idea how it got there. If it makes a mistake, you start over. If you want to try a different approach, you can't branch — you start over. If you want to understand why it did what it did, you read logs like a detective.

**Shem's event log changes the category.** Shem is to agents what git is to code — a complete, auditable, replayable, forkable record of *everything that happened and why.*

This is not a feature. It is a different category of product.

### The category: transparent agents

| Problem | Existing tools | Shem |
|---|---|---|
| "My assistant made a mistake and I don't know why" | Guess from the output | Rewind to the exact moment and inspect every LLM call and tool invocation |
| "I want to try a different approach but keep my current session" | Fork the conversation in your head | `/fork at event 42` — branch the timeline, try a different prompt, compare results |
| "My assistant did something unexpected" | Start over | Diff the two runs, see exactly where they diverged |
| "I need to prove what my assistant did for compliance" | Hope your logging is sufficient | Immutable, hash-chained event log, exportable as JSONL |
| "My assistant forgot something from earlier" | Re-explain or hope RAG catches it | Timeline memory — replay relevant moments from the event log into context |
| "I'm not sure I trust this tool" | Blind trust or block it | Trust-weighted governance with a full audit trail of every invocation |

### Why this goes viral

No existing assistant offers this. Not because they haven't thought of it — but because they're built on runtimes that *can't do it.* Python agent frameworks don't have preemptive concurrency, so they can't interleave event recording with execution without blocking. They don't have immutable state, so their logs are append-only text files, not structured timelines. They don't have transparent distribution, so multi-machine runs produce scattered, inconsistent traces.

Shem's BEAM foundation makes the timeline engine not just possible but natural. The event log isn't bolted on — it's the spine of the system.

**The viral hook:** A `/share` command that generates a link to your assistant's full reasoning chain in the web timeline viewer. "My AI just did something brilliant (or bizarre) — here's exactly how it got there." AI is normally a black box; this makes it shareable, teachable, debuggable. No other assistant can generate that link.

### What this means for the features below

The features in this document ladder up to one goal: **Shem as the transparent AI assistant that replaces black-box agents.** Not a framework for building agents — a product people use and love. The BEAM is the engine; the timeline is the interface; transparency is the moat.

To deliver this, Shem needs to:

1. **Be as easy to install as OpenClaw** — curl | bash, works from chat apps (WhatsApp, Telegram, iMessage)
2. **Be debuggable by default** — every action recorded, every session viewable, forkable, diffable
3. **Be trustworthy** — trust-weighted governance, human-in-the-loop handoffs, immutable audit trail
4. **Be extensible** — agents that write and graduate their own tools, a community registry
5. **Be adopted from Python** — the Python SDK so Shem is the reliable backend, not a replacement language

Everything below is ordered by how it serves this vision.

---

## 1. Python SDK (`shem-client` pip package) — Score: 10/10

**What:** A Python client wrapping Shem's MCP endpoint at `localhost:4000`.

```python
pip install shem-client

from shem_client import ShemClient
client = ShemClient("localhost:4000")
agent = client.agent("coder")
agent.run("refactor this function")
```

**Why:** Python is where the agent users are. MCP already exists. This is a protocol wrapper — ~200 lines of Python. Instantly makes Shem usable as a "reliable agent backend" without requiring Elixir knowledge. This is the conversion funnel for Python developers.

**Adoption leverage:** Huge. You don't need to convert anyone to Elixir — just let them use Shem from Python.

**Implementation sketch:**
- Thin synchronous/asynchronous client over the MCP SSE endpoint
- `ShemClient` class: connect, list_tools, invoke_tool, spawn_agent, get_status
- `Agent` handle: wraps a session_id, exposes `.run(prompt)`, `.tools()`, `.timeline()`, `.fork()`
- Optional: `asyncio` support with `AsyncShemClient`
- Error handling: reconnect on SSE disconnect, timeout per tool call
- Directory: `shem/clients/python/` in the Shem repo, published to PyPI via GitHub Actions
- Future: typed stubs (pyi), pydantic models for tool schemas

**Prerequisites:** MCP Server already runs on localhost:4000.

---

## 2. Web Timeline Viewer — Score: 10/10

**What:** A web UI that visualizes the event log as a navigable timeline. Two agent runs side-by-side with a scrubber to step through every LLM call, tool invocation, and state mutation. A "fork here" button that branches the timeline and re-runs from that point.

**Why:** The event-sourced timeline engine is Shem's genuine architectural moat — no other framework can do this. But it's invisible. A web viewer makes it tangible. This is the "holy shit" demo that makes people understand why BEAM matters for agents.

**Differentiation leverage:** Maximum. This is a feature Python frameworks cannot build, not just don't have.

**Implementation sketch:**
- Backend: Phoenix LiveView app (or simpler — just Plug + REST endpoints serving JSON, with a vanilla JS + D3 frontend). A full Phoenix app is overkill for a viewer.
- Endpoints needed:
  - `GET /api/sessions` — list all sessions (id, created_at, agent_name, event_count)
  - `GET /api/sessions/:id/events` — stream events as JSON array (or paginated)
  - `GET /api/sessions/:id/events/:event_id` — single event with full detail
  - `POST /api/sessions/:id/fork?at=<event_id>` — fork and return new session id
  - `GET /api/diff?left=<session_id>&right=<session_id>` — diff two timelines
- Frontend:
  - Left panel: session list
  - Center: timeline as a vertical event stream, color-coded by type (llm_call, tool_invoke, agent_turn, error)
  - Below each event: expandable detail (prompt, response, tool IO, token count, latency)
  - Scrubber: draggable handle to jump to any point in the session
  - Fork button per event: creates new session, redirects to it
  - Diff mode: two timelines side-by-side, divergences highlighted
  - Search/filter by event type, text content, tool name
- Offer as an optional web app alongside the TUI — `SHEM_START_WEB=1 mix run --no-halt`
- Serve on a configurable port (default 4001 to not conflict with MCP)

**Edge cases:**
- Sessions with 10k+ events need pagination or virtual scrolling
- Forking an in-progress session should snapshot current state
- Diffing sessions with different event counts — align by event index and by timestamp
- Large LLM responses (multi-token) should be truncated in the timeline with a "show full" toggle

**Prerequisites:** EventLog's replay/branch infrastructure already works. The viewer just needs to consume it.

---

## 3. LangChain-to-Shem Bridge — Score: 7/10

**What:** `pip install shem-bridge-langchain`. A drop-in adapter that replaces LangChain's runtime with Shem's BEAM backend. Existing LangChain code keeps working, but agents now run under supervision trees with fault recovery and distribution.

```python
# Before
from langchain.agents import AgentExecutor

# After
from shem_bridge import ShemAgentExecutor as AgentExecutor
```

**Why:** Lowest-friction path for existing LangChain users. No rewrite needed — just swap the import and suddenly your agents are fault-tolerant. Shem becomes "LangChain, but for production."

**Risks:**
- LangChain's API churn is severe. The bridge would pin to a specific LangChain version.
- LangChain abstractions (chains, tools, memory, callbacks) are leaky — the bridge can only cover what maps cleanly to Shem concepts.
- Best approached as: support LangChain's `AgentExecutor` and `Tool` abstractions, ignore the rest.

**Implementation sketch:**
- `ShemAgentExecutor` implements LangChain's `BaseAgentExecutor` interface
- Under the hood: calls MCP endpoint `invoke_tool` with the prompt, returns the result in LangChain's `AgentFinish` format
- `ShemTool` wraps Shem's graduated tools as LangChain `BaseTool` instances
- `ShemCallbackHandler` translates Shem events (token usage, tool calls) into LangChain callback events
- Memory bridge: `ShemTimelineMemory` implements LangChain's `BaseMemory` using the event log instead of a vector store (see feature #4)

**Alternatives:** Instead of a LangChain bridge, consider an **OpenAI-compatible API server** (`/v1/chat/completions` + function calling). Many tools (LangChain, AutoGen, CrewAI, Vercel AI SDK) support OpenAI-compatible endpoints natively. This captures the same audience with lower maintenance cost.

---

## 4. Timeline-Native Agent Memory — Score: 8/10

**What:** Replace vector DB memory with event-log replay. When an agent needs to "remember" something, instead of embedding and querying a vector store, it replays relevant segments of its own event log during inference. The agent re-experiences past sessions.

**Why:** No chunking, no embedding decay, no stale vectors, no external database. The event log already has every interaction as structured data. This is a fundamentally different (and better) memory architecture that only makes sense if you have a replayable event log — which Shem does and nobody else does.

**Implementation sketch:**
- New middleware in the LLM pipeline: `Shem.LLM.Middleware.TimelineMemory`
- Actively determines what to inject into the prompt context based on:
  - Recency: last N events from the current session
  - Relevance: event log entries whose prompts/ responses contain keywords from the current prompt (simple text match, no embeddings needed)
  - Explicit memory operations: `remember("key", "value")` tool call stores structured data in the event log
- The middleware prepends a "context" section to the prompt with:
  - Recent session history (last K turns)
  - Recalled memories (matched by keyword or tag)
  - A summary of the agent's current state (active tools, trust scores, budget remaining)
- Memory operations as tool calls:
  - `remember(keyword, content, ttl)` — store a fact in the event log
  - `recall(keyword)` — retrieve matching memories from event log
  - `forget(keyword)` — mark memories as stale
- Event log store: memories are events of type `:memory_store` with metadata tags. Replay filters by tag.

**Differentiation leverage:** Very high. Ties directly into the existing event log infrastructure.

**Edge cases:**
- Memory eviction: event log grows unbounded. Needs TTL-based pruning or summary compression.
- Agent agents sharing memory: cross-session recall across agents with matching tags.
- Overload: if every LLM call injects 50k tokens of memory history, budget gets eaten. Need smart truncation.

**Prerequisites:** EventLog, LLM middleware pipeline.

---

## 5. Live Observer Dashboard — Score: 6/10

**What:** A web wrapper around Erlang's `:observer.start()` — the BEAM's built-in introspection tool. Shows every running agent's state, message queue length, call history, live memory, and backpressure metrics. Updates in real time.

**Why:** Erlang's observer is the most powerful debugging tool most AI developers have never seen. It lets you inspect a running distributed system at the process level. Nothing in the Python agent world comes close. Shem with observer is "agents with strace/htop built in."

**Implementation sketch:**
- `Shem.ObserverBridge` — a GenServer that wraps `:observer_backend` API calls
- Exposes a WebSocket endpoint with periodic snapshots of:
  - System metrics: CPU, memory, binary heap, atom table
  - Process table: filtered to Shem-owned processes (agents, supervisors, event log)
  - Per-agent: message queue depth, reductions, memory, current call, state
  - ETS tables: Lab.Registry, Horde.Registry sizes
- Frontend: simple HTML page with auto-refreshing tables and sparklines (or embed in the Timeline Viewer as a tab)
- Alternative path: document how to attach `:observer` to a running Shem node for power users, skip the web wrapper

**Note:** This is a show-off feature. High differentiation, moderate adoption leverage (observer is most impressive after you're already invested in BEAM).

**Prerequisites:** BEAM distribution must be enabled (it already is).

---

## 6. OpenAI / Anthropic Transports — Score: 9/10

**What:** Native HTTP transports for OpenAI and Anthropic APIs, alongside the existing Ollama/llama.cpp transports. Just works out of the box.

**Why:** Almost nobody runs local LLMs in production. Shem can't be a daily-driver without cloud LLM support. This is table stakes — but it's missing, so it's blocking everything else.

**Implementation sketch:**
- `Shem.LLM.Middleware.OpenAITransport` — minimal module implementing `Shem.LLM.Middleware` behaviour
- POST to `https://api.openai.com/v1/chat/completions` with the request prompt, stream response
- Handle: authentication (API key from config/env), rate limiting (429 responses), token counting (tiktoken or approximate), streaming vs non-streaming
- `Shem.LLM.Middleware.AnthropicTransport` — same pattern, Anthropic's Messages API
- Config in `config/dev.exs` / `config/runtime.exs`:
  ```elixir
  config :shem, :llm_models,
    default: {:openai, "gpt-4o"},
    fast: {:openai, "gpt-4o-mini"},
    cheap: {:anthropic, "claude-3-haiku"}
  ```
- For streaming SSE support, use Bandit's built-in WebSocket/SSE capabilities (already a dep)

**Config schema:**
```elixir
config :shem, :llm_transport,
  openai: [api_key: {:system, "OPENAI_API_KEY"}, organization: nil],
  anthropic: [api_key: {:system, "ANTHROPIC_API_KEY"}]
```

**Effort:** Low. The LLM middleware pipeline is already clean; adding a new transport is a single module.

---

## 7. Dockerfile & Release Configuration — Score: 8/10

**What:** A multi-stage Dockerfile for building an OTP release, plus `docker-compose.yml` for multi-node clusters.

**Why:** No deployment story means no production use. An OTP release is the BEAM's native deploy artifact — self-contained, hot-upgradeable, no Erlang/Elixir runtime required on the target machine. Without this, Shem is a development tool, not a platform.

**Implementation sketch:**
- Dockerfile stages:
  1. `elixir:1.19-slim` — fetch deps, compile
  2. Same image — build release with `mix release`
  3. `debian:bookworm-slim` or `scratch` — copy release artifact only
- Waf patching: the `patch_waf` in `mix.exs` needs the `priv/waf` binary to exist. The Dockerfile must COPY it before `mix deps.compile`.
- TUI: releases ship without a terminal by default. The release entrypoint should check if stdin is a TTY before starting TUI (already guarded by `SHEM_NO_TUI`). Default to headless in Docker.
- Multi-node via docker-compose:
  ```yaml
  services:
    shem-node-1:
      build: .
      environment:
        - SHEM_NODE_NAME=shem1@hostname
        - SHEM_COOKIE=mysecret
    shem-node-2:
      build: .
      environment:
        - SHEM_NODE_NAME=shem2@hostname
        - SHEM_COOKIE=mysecret
        - SHEM_JOIN_CLUSTER=shem1@hostname
  ```
- Docker Compose profiles: dev, single-node, cluster
- Health check: `CMD curl -f http://localhost:4000/mcp/health || exit 1`

**Edge cases:**
- The waf binary in `priv/waf` is compiled for the host arch. Docker build may target `linux/amd64` — ensure the binary is compatible or compile it in the Dockerfile.
- Release config disables TUI automatically (no TTY in Docker). Test that MCP server still starts.
- DETS files in `~/.config/shem/` need a persistent volume mount, or they're lost on container restart.

**Effort:** Moderate. Mix releases are well-documented but some deps (ex_termbox, waf) complicate the build.

---

## 8. CI Pipeline (GitHub Actions) — Score: 7/10

**What:** `.github/workflows/ci.yml` with:
- `mix test` on push/PR
- Credo (linting)
- Dialyzer (type checking)
- Format check
- Smoke test

**Why:** Missing CI is a red flag for open source contributors. Makes the project look abandoned even when it isn't. Also prevents regressions as the codebase grows.

**Implementation sketch:**
```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        elixir: ['1.19']
        otp: ['27']
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: ${{ matrix.elixir }}
          otp-version: ${{ matrix.otp }}
      - run: mix deps.get
      - run: mix format --check-formatted
      - run: mix credo
      - run: mix test
      - run: mix dialyzer
```

**Notes:**
- The waf patch in `mix deps.get` and `mix deps.compile` should work in CI, but test it — CI runners may have different Python versions.
- Smoke test needs an LLM server. For CI, add a step that runs Ollama in the background (or use the stub transport and test against that).
- `SHEM_NO_TUI=1` must be set for CI.

**Effort:** Low-medium. Standard Elixir CI setup.

---

## 9. OpenTelemetry / Structured Logging — Score: 5/10

**What:** Instrument the agent pipeline, LLM calls, tool dispatches, and event log with OpenTelemetry spans. Export to Jaeger, Grafana, or any OTLP endpoint.

**Why:** Production observability. Trace a user request through LLM calls, tool executions, and sub-agent spawns across nodes. The BEAM already has excellent OpenTelemetry support (`:opentelemetry_erlang`).

**Implementation sketch:**
- Add `:opentelemetry_erlang` and `:opentelemetry_exporter` to deps
- Key spans to create:
  - `shem.agent.turn` — wraps a single agent turn (prompt → LLM → tool calls)
  - `shem.llm.call` — per LLM request (model, tokens_used, latency_ms)
  - `shem.tool.invoke` — per tool invocation (tool_name, duration, success/failure)
  - `shem.event_log.append` — per event write
  - `shem.adversarial.round` — per red-team hardening round
- Attributes on spans: agent_name, session_id, tool_name, model, token_count, error_type
- Export config via environment variables: `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`

**Adoption leverage:** Moderate. Important for enterprise adoption but not a differentiator.

**Prerequisites:** No code changes needed to the core — spans are added as middleware wrappers or via `:telemetry` events (which Elixir libraries already emit).

---

## 10. Capability Marketplace / Tool Registry — Score: 4/10 (today)

**What:** A registry of signed, versioned "graduated tools" that users can publish and consume. Tools are self-contained code packages that pass the lab's graduation gate (tests + property tests).

**Why:** Network effects. The more tools in the registry, the more valuable the platform. But this is a post-adoption feature — you need users first.

**Implementation sketch (future reference):**
- Tool manifest format: `tool.toml` with name, version, description, author, deps, entrypoint
- Signing: ed25519 signatures via `:crypto` (Erlang's built-in crypto). Author publishes a public key, signs their tool manifest.
- Registry backend: could be a simple git repo (like Homebrew), a Hex-style package server, or IPFS for fully decentralized distribution
- `shem tool install <name>` — downloads, verifies signature, runs graduation gate, promotes to graduated tools
- `shem tool publish` — signs and uploads the tool manifest
- Version resolution: semver, dependency hell management (like Hex does)

**Effort:** High (registry infrastructure, signing, versioning, dependency resolution). Premature before adoption.

---

## 11. Multi-Agent Orchestration Patterns — Score: 7/10

**What:** Built-in orchestration primitives for multi-agent workflows: DAG-based pipelines, fan-out/fan-in, map-reduce, supervisor/worker, debate/consensus.

**Why:** Many agent use cases require multiple agents coordinating. Currently, users would need to build this themselves on top of the GenServer API. Offering first-class patterns makes Shem competitive with CrewAI and AutoGen, but with the BEAM's actual concurrency instead of Python's asyncio.

**Implementation sketch:**
- `Shem.Orchestrator` — a GenServer that manages a workflow of agents
- Workflow definition as a data structure:
  ```elixir
  workflow = %Shem.Orchestrator.DAG{
    nodes: [
      {:researcher, %{prompt: "...", tools: [:web_search]}},
      {:analyst, %{prompt: "...", deps: [:researcher]}},  # waits for researcher
      {:writer, %{prompt: "...", deps: [:researcher, :analyst]}}
    ]
  }
  Shem.Orchestrator.run(workflow)
  ```
- Built-in patterns as functions:
  - `Shem.Orchestrator.fan_out(agents, task)` — all agents run the same task in parallel
  - `Shem.Orchestrator.fan_in(results, aggregator_agent)` — merge parallel results
  - `Shem.Orchestrator.supervisor_worker(supervisor, workers, task)` — one agent delegates to sub-agents
  - `Shem.Orchestrator.debate(agents, question, rounds)` — agents debate, produce consensus
- Each agent in the workflow gets its own session_id in the event log. The orchestrator session is the parent, with child links.
- Failure handling: if one agent in a fan-out crashes, options: abort all, ignore and continue, retry N times.

**Differentiation:** CrewAI and AutoGen do this but with asyncio. Shem's agents are truly concurrent — no event loop, no GIL, no "one agent blocks the world."

**Prerequisites:** Agent.Server, EventLog, Horde distribution.

---

## 12. Tool Hot-Reloading — Score: 6/10

**What:** Update graduated tools without restarting agents or the Shem VM. Agents notice new tool versions and use them on the next turn.

**Why:** The Lab's graduation gate already compiles and registers tools atomically. Hot-reloading makes the dev loop tighter — write a tool, graduate it, use it immediately. Also enables live-updating tools in production.

**Implementation sketch:**
- The Lab.Registry (ETS) already supports runtime updates — `Registry.put_tool/1` replaces a tool atomically
- The change is in `ToolDispatch` — currently, agents load their tool list at startup. Add a `:check_for_updates` option that re-queries the registry before each turn.
- Code unloading: BEAM supports `:code.delete/1` and `:code.purge/1` for module hot-swapping. After the ETS registry is updated, purge the old module version.
- Safety: if a tool is in use when updated, the current invocation finishes with the old version; new invocations use the new version (BEAM's module versioning handles this naturally).
- MCP layer: `list_tools` returns the latest version; add a `tool_updated` SSE event to notify connected clients

**Edge cases:**
- Tool removed while agent is running: graceful error in tool dispatch, not a crash.
- Version mismatch across cluster nodes: eventually consistent via Horde gossip.

**Prerequisites:** Lab.Registry (already ETS-backed), ToolDispatch.

---

## 13. Human-in-the-Loop Handoff — Score: 7/10

**What:** A protocol for agents to pause and request human input. The agent suspends, a notification fires, the human provides input (via TUI, web, or API), and the agent resumes from the same state.

**Why:** Autonomous agents still need guardrails. A formal handoff protocol is better than "pray the LLM doesn't do something destructive." It enables approval workflows, manual override, and interactive debugging.

**Implementation sketch:**
- Agent.Server gets a new state: `:awaiting_human`
- Tool call `request_human_input(prompt, context)` transitions the agent to `:awaiting_human` and emits an event
- The event is picked up by any connected interface:
  - TUI: flash a notification, show the prompt, accept input
  - Web: SSE event to the Timeline Viewer, web form appears
  - API: `POST /api/agents/:id/respond` with `{input: "..."}`
- `Shem.Agent.Server.respond(agent_pid, input)` — resumes the agent with the input injected into the next LLM call
- Timeout: if no response within N seconds, configurable action (retry, abort, use default)
- Event log records the handoff as `:human_input_requested` and `:human_input_received` events

**Edge cases:**
- Multiple handoffs in sequence (multi-turn approval workflow)
- Human disconnects mid-handoff — agent waits indefinitely unless timeout is set
- Security: authenticate the human response (who approved what)

**Prerequisites:** Agent.Server state machine, EventLog.

---

## 14. Agent-as-a-Service (HTTP API Server) — Score: 7/10

**What:** A REST/JSON API for managing agents remotely. Spawn agents, send prompts, check status, stream responses, list sessions — all over HTTP.

**Why:** Let any language or tool interact with Shem agents. The MCP server already provides some of this, but a dedicated, documented HTTP API is more accessible to non-MCP clients. Enables integration with web apps, Slack bots, CI pipelines, etc.

**Implementation sketch:**
- `Shem.API.Router` — a Plug router (Bandit already a dep) on a configurable port
- Endpoints:
  - `POST /api/agents` — spawn an agent with config
  - `GET /api/agents` — list running agents
  - `POST /api/agents/:id/prompt` — send a prompt, return response (blocking or async)
  - `GET /api/agents/:id/status` — status, session_id, budget remaining
  - `DELETE /api/agents/:id` — stop an agent
  - `GET /api/sessions` — list sessions
  - `GET /api/sessions/:id/events` — get event log for a session
  - `GET /api/tools` — list graduated tools
  - `WS /api/agents/:id/stream` — WebSocket for streaming agent responses
- The MCP server already runs on port 4000. The API server should be a separate port (e.g., 4002) or merged into the MCP server with additional routes. Consider adding the REST routes directly to the MCP server to keep a single entry point.
- Request logging: log all API calls, include `X-Request-Id` for tracing

**Prerequisites:** MCP.Server (add routes to it rather than a separate server).

---

## 15. Prometheus Metrics Endpoint — Score: 5/10

**What:** A `/metrics` endpoint exposing Shem-specific metrics in Prometheus format: active agents, LLM calls/minute, token usage, tool invocations, error rates.

**Why:** Production monitoring. If Shem runs in production, ops teams need metrics. This is table stakes for deployment alongside the Dockerfile.

**Implementation sketch:**
- Use `prometheus_elixir` or `prom_ex` library (lightweight)
- Gauge: `shem_agents_active` — number of running agents
- Counter: `shem_llm_calls_total` — with labels: model, success/failure
- Counter: `shem_tokens_total` — with label: model
- Counter: `shem_tool_invocations_total` — with label: tool_name, status
- Histogram: `shem_llm_latency_ms` — LLM response latency
- Gauge: `shem_budget_remaining` — per-agent remaining token budget
- Endpoint: `GET /metrics` on the HTTP API server port

**Effort:** Low (library + ~50 lines of Elixir).

**Prerequisites:** API HTTP server (feature #14) or merge into existing MCP server.

---

## 16. Event Log Export / Compliance Audit — Score: 4/10

**What:** Export session event logs as JSON, JSONL, or CSV for external analysis, audit, or compliance. Include an "audit mode" that logs all interactions (including full LLM I/O) to an append-only file.

**Why:** Enterprise adoption requires audit trails, especially in regulated industries (finance, healthcare, legal). This unlocks those sales.

**Implementation sketch:**
- `Shem.EventLog.export(session_id, format: :jsonl)` — dump all events to stdout or file
- `Shem.EventLog.export_all(format: :jsonl, since: ~D[2026-01-01])` — bulk export
- Audit mode: `config :shem, audit_log_path: "/var/log/shem/audit.jsonl"` — every event is also written synchronously to the audit file with a hash chain (each entry contains the SHA256 of the previous entry, making tampering detectable)
- Export hook: webhook that fires on each new event (for SIEM integration)

**Prerequisites:** EventLog (the data model is already clean; this is a serialization concern).

---

## 17. Agent Preset Templates ("Blueprints") — Score: 5/10

**What:** A library of pre-built agent configurations for common roles: code reviewer, documentation writer, data analyst, web scraper, test generator, PR reviewer, security auditor.

**Why:** Most users don't want to configure agents from scratch. A `shem new blueprint` command that drops them into a working agent makes the "time to first agent" seconds instead of hours. Also serves as a teaching tool for how to configure agents.

**Implementation sketch:**
- Define blueprints in `priv/blueprints/` as `.exs` files
- Each blueprint exports a function `blueprint/0` that returns a `Shem.Agent.Preset` struct
- `Shem.CLI` command: `shem new agent --from=code_reviewer` — creates a new agent config
- `shem list blueprints` — list available blueprints
- Built-in blueprints:
  - `code_reviewer`: coding preset + read_file/write_file tools, focused on PR review
  - `data_analyst`: python + shell tools, focused on data analysis
  - `web_scraper`: shell + read_file tools, focused on web scraping
  - `documentation_writer`: write_file + read_file tools, focused on docs generation  
  - `security_auditor`: shell + read_file tools, locked-down tool permissions
  - `explorer`: the default exploration agent (already exists as builtin preset)
- Blueprints can be distributed as graduated tools via the Capability Marketplace (#10)

**Prerequisites:** Agent.Preset (3-layer resolution already exists — this adds a "blueprint" layer above builtins).

---

## 18. Semantic Search Over Event Logs — Score: 6/10

**What:** Full-text and semantic search across all session event logs. Find "that time the agent tried to delete a file" or "when did we last call the graduation gate?"

**Why:** As session logs accumulate (hundreds or thousands of sessions), finding a specific interaction becomes impossible without search. This makes the event log a usable long-term memory, not just a debugging tool.

**Implementation sketch:**
- Option A (lightweight): grep-style text search using Elixir's `:binary.match` across DETS entries. Scans all sessions, returns matches with context. Good enough for small-to-medium installs.
- Option B (full-text index): build an inverted index in a secondary ETS/DETS table. On each event append, extract keywords and update the index. Search is O(1) lookup.
- Option C (embeddings-based): generate embeddings for each event (or batch of events) using the LLM transport. Store in an ETS table. Query by cosine similarity. This is overkill for most use cases but could be useful for the timeline memory feature (#4).
- API: `Shem.EventLog.search("graduation gate failed", session_id: nil, limit: 20, before: ~U[2026-06-01])`

**Edge cases:**
- DETS has a 2GB limit. Large installs may outgrow it. Full-text index may help but the underlying storage still needs to scale. This is a long-term concern — the Mnesia or SQLite migration (feature #20) is the real fix.

**Prerequisites:** EventLog.

---

## 19. Sandbox Container Isolation — Score: 5/10

**What:** Run lab code execution inside lightweight containers (OCI runtimes like Podman/Docker) instead of raw BEAM remote nodes. Provides stronger security isolation and support for non-Elixir runtimes.

**Why:** The current Lab executor uses BEAM remote nodes for sandboxing, which is great for Elixir code but doesn't isolate Python, Node, or shell commands at the OS level. Container-level isolation is needed for production safety, especially if untrusted users can submit tools.

**Implementation sketch:**
- `Shem.Lab.Executor.OCI` — a new executor backend alongside the existing remote-node executor
- Interface: `Shem.Lab.Executor` behaviour with `run/2` returning `{:ok, result}` or `{:error, reason}`
- OCI executor: spawns a Podman/Docker container, copies code in, runs it, captures stdout/stderr/exit code, destroys container
- Container image with pre-installed runtimes: Elixir, Python, Node, gcc, etc.
- Configurable container image, resource limits (CPU, memory, network access), timeout
- Falls back to remote-node executor when container runtime is unavailable

**Edge cases:**
- Container startup latency (cold start: ~1-2s for Podman). Cache warm containers.
- Side-channel attacks between containers sharing a kernel
- Network access: some tools need it (web scraping), others shouldn't have it (data processing)

**Prerequisites:** Lab executor infrastructure.

---

## 20. Mnesia / SQLite Backend for Event Log — Score: 6/10

**What:** Replace the DETS-backed event log with Mnesia (distributed in-memory/disk DB built into Erlang) or SQLite (via `sqlitex` or `exqlite`). Enables larger storage, cross-machine replication, and SQL queries.

**Why:** DETS has a 2GB table limit and is single-node. Mnesia is distributed across the BEAM cluster by nature. SQLite gives you SQL queries for analysis. Either backend unlocks production-scale session storage.

**Implementation sketch:**
- The `Shem.EventLog.Store` behaviour already abstracts storage. A new `Shem.EventLog.MnesiaStore` or `Shem.EventLog.SQLiteStore` implements the same callbacks.
- Session store, event store, index all backed by the new backend
- Mnesia: tables with `{disc_copies, [node()]}` for persistence across restarts, `{ram_copies, []}` for performance
- SQLite: single-file DB per node, or a shared file on NFS (not recommended — SQLite is not a network DB)
- Migration: `Shem.EventLog.migrate_store(:dets, :mnesia)` copies all data. Should be a mix task.

**Edge cases:**
- Mnesia can be complex to configure correctly (table definitions, schema merging across nodes).
- SQLite write contention under high throughput (serialized writes). Mitigation: batch writes, WAL mode.

**Prerequisites:** EventLog.Store behaviour (already abstracted).

---

## 21. Agent Checkpoint / Restore Across Restarts — Score: 7/10

**What:** When Shem restarts, agents automatically resume from their last checkpoint — including their event log, tool state, budget position, and in-progress turn.

**Why:** Currently, restarting Shem loses all running agents. Checkpoints already exist in the codebase (`Shem.Agent.Checkpoint`) but may not be wired into the lifecycle for full resume. This is critical for production: machines reboot, deployments happen, agents should pick up where they left off.

**Implementation sketch:**
- On graceful shutdown: each agent writes a checkpoint with its full state (session_id, event log position, turn history, budget spent, tool state)
- On startup: `AgentSupervisor` scans for checkpoint files, restores agents via `Shem.Agent.Server.restore/1`
- The event log persists (it's DETS-backed) — the session survives restart. The agent just needs to reconnect to its session.
- In-progress LLM call: on restore, the agent sees the last event is an `:llm_call_started` without a matching `:llm_call_completed`. It can re-issue the call or ask the user for guidance.
- Checkpoint format: Erlang term serialized to a file in `~/.config/shem/checkpoints/<agent_name>.checkpoint`

**Edge cases:**
- Agent was in the middle of a tool call when shutdown happened. The tool might have side effects. Restoring needs to detect this and either re-run or skip.
- Multiple agents with the same name on different nodes in a cluster — checkpoint must include the node name to avoid collisions.

**Prerequisites:** Agent.Checkpoint (already exists, may need integration), EventLog.

---

## 22. Configuration as Code (Config Files) — Score: 5/10

**What:** Define Shem agents, presets, tool permissions, and trust policies in YAML/TOML files. Hot-reloadable without restarting the VM.

**Why:** Declarative configuration is easier to version-control, review, and deploy than Mix config or runtime API calls. Enables GitOps workflows for agent infrastructure.

**Implementation sketch:**
- Config file location: `~/.config/shem/agents.d/*.{yaml,yml,toml}`
- File watcher: `FileSystem` library monitors the directory, reloads on change
- Agent definition example:
  ```yaml
  agents:
    code-reviewer:
      preset: coding
      tools:
        - read_file
        - write_file
      trust_gate: true
      budget: 100000
      model: gpt-4o
  ```
- Tool permission example:
  ```yaml
  tools:
    shell:
      allowed_hosts: ["localhost"]
      blocked_commands: ["rm -rf /", "sudo"]
  ```
- Loader GenServer: on startup, reads all files and merges with existing config. On file change, re-reads and applies diff.
- Conflict resolution: file config overrides Mix config, which overrides defaults.

**Prerequisites:** None. This is a new module, reads config at startup.

---

## 23. WASM-Based Tool Execution — Score: 4/10

**What:** Run user-submitted tools inside a WebAssembly sandbox (via Extism, Wasmtime, or similar) for language-agnostic, safe, portable tool execution.

**Why:** WASM provides stronger isolation than BEAM remote nodes and is more portable than OCI containers. Tools written in any language (Rust, Go, C, AssemblyScript) can run in the same sandbox. This is speculative but potentially important for multi-tenant scenarios.

**Implementation sketch:**
- `Shem.Lab.Executor.WASM` — implements the executor behaviour using Extism PDK
- Tool authors compile their code to WASM, Shem runs it with configurable permissions (wasi, network, file system)
- Trade-off: WASM runtimes are fast to start (<1ms) but have limited system call access (no arbitrary shell commands, no GPU access)
- Integration with the graduation gate: tools must compile to WASM and pass tests

**Prerequisites:** Lab executor infrastructure. This is experimental — not a priority.

---

## 24. Github/GitLab Bot Integration — Score: 6/10

**What:** A bot that sits on GitHub/GitLab repos as a webhook receiver. On issues, PRs, or `/shem` commands, it spawns a Shem agent to investigate, comment, create PRs, or run code.

**Why:** This is the most visible use case for autonomous agents — AI that participates in actual development workflows. It's a great demo, a genuine productivity tool, and a way to dogfood Shem on Shem itself.

**Implementation sketch:**
- `Shem.Integration.GitHub` — a GenServer that listens for webhooks via the MCP/API server
- Endpoint: `POST /webhooks/github` — validated via GitHub's HMAC signature
- Event handling:
  - `issue_comment.created` — if comment starts with `/shem`, extract the instruction and spawn an agent
  - `pull_request.opened` / `pull_request.synchronize` — auto-review the PR diff
  - `push` — run tests, report results
- Agent spawned with tools: `read_file`, `write_file`, `shell` (for git operations), and optionally `github_api` tool
- The agent can:
  - Post comments on issues/PRs
  - Create PRs with changes (via the GitHub API)
  - Request changes on PRs
  - Run tests and report results
- Security: the agent needs a GitHub token scoped to the repo. Running `shell` on the repo is dangerous — consider a read-only mode for untrusted repos.
- GitLab: same pattern, different API endpoints

**Prerequisites:** API server (feature #14), tool dispatch.

---

## 25. Shem REPL / CLI Tool (`shem` command) — Score: 6/10

**What:** A standalone `shem` command-line tool (installed via Homebrew, `pip`, or direct download) that wraps the MCP/HTTP API. Lets users interact with Shem agents from any terminal without the TUI.

**Why:** Not everyone wants or can use a Ratatouille TUI (SSH sessions, CI, headless servers, tmux panes). A simple CLI tool that reads from stdin and writes to stdout makes Shem usable in pipes, scripts, and remote sessions.

**Implementation sketch:**
- Language: Elixir (as an escript or Mix release), or Python (alongside the SDK in #1)
- Commands:
  ```
  shem agent spawn --name=coder --preset=coding
  shem agent run "explain this error"    # send prompt, print response
  shem agent attach                      # interactive stdin/stdout session
  shem session list                      # list recent sessions
  shem session view <id>                 # print session timeline
  shem tool list                         # list graduated tools
  shem tool install <name>               # install from registry
  shem config show                       # show current configuration
  ```
- Interactive mode: `shem agent attach` gives a prompt-like interface where each line is sent as a prompt and the response streams to stdout
- Pipes: `echo "refactor this code" | shem agent run --preset=coding` — reads from stdin, writes to stdout
- Config: `~/.config/shem/cli.toml` for default settings (server URL, default agent)
- Connects to a running Shem server (local or remote) via the MCP or HTTP API

**Prerequisites:** MCP/HTTP API server.

---

## 26. Mermaid Diagram Generation from Event Logs — Score: 3/10

**What:** Export agent timelines as Mermaid.js sequence diagrams. Each LLM call, tool invocation, and agent communication becomes a participant or message in the diagram.

**Why:** Makes timelines visual and shareable in Markdown docs, PRs, and presentations. Low effort, high "wow" for documentation.

**Implementation sketch:**
- `Shem.EventLog.to_mermaid(session_id)` — generates a Mermaid sequence diagram string
- Each event type maps to a Mermaid element:
  - Agent turn → `Agent->>LLM: prompt` / `LLM-->>Agent: response`
  - Tool call → `Agent->>Tool: invoke(name, args)` / `Tool-->>Agent: result`
  - Branch/fork → alt/else blocks
- Output can be pasted into any Mermaid renderer (GitHub Markdown, docs, etc.)
- Bonus: add a "copy as Mermaid" button to the web timeline viewer

**Prerequisites:** EventLog.

---

## 27. Shem-to-Shem Federation — Score: 5/10

**What:** Connect multiple Shem instances across the internet (not just LAN) via authenticated BEAM distribution. A Shem instance at `shem.company-a.com` can spawn agents on `shem.company-b.com` transparently.

**Why:** The BEAM's distribution protocol can work over the internet, but it's not secure by default (no TLS, cookie-based auth only). Wrapping it in TLS with mutual authentication enables inter-organization agent meshes. This is the "ultimate" version of the distributed agent mesh — agents that can run across organizational boundaries.

**Implementation sketch:**
- Use BEAM distribution over TLS (`-proto_dist inet_tls`) with client certificates
- `Shem.Federation` — a GenServer that manages remote node connections
- Federation config: list of remote nodes with their TLS certificates and allowed operations
- Permission model: each remote connection has a scope of allowed operations (e.g., "can spawn agents, but only with `read_file` tools, never `shell`")
- Agents spawned on remote nodes are supervised by the remote's AgentSupervisor but report events back to the origin's EventLog

**Prerequisites:** Cluster infrastructure (already in place via libcluster).

---

## 28. Built-in Web Search Tool — Score: 5/10

**What:** A first-party `web_search` tool that agents can use out of the box. No configuration, no API key needed for basic DuckDuckGo/Lite search.

**Why:** Web search is the most requested tool for autonomous agents. Making it a built-in (alongside the existing read_file/write_file/shell) removes the first friction point users hit.

**Implementation sketch:**
- `Shem.Tools.WebSearch` — implements the existing tool dispatch interface
- Backend: DuckDuckGo's lite API (no API key), configurable to Google Programmable Search / Bing Search API
- Rate limiting: DDG has aggressive rate limits. Use a simple token bucket per agent.
- Result format: title, URL, snippet. Optional: fetch full page content for further processing.
- Config: `config :shem, :web_search, backend: :duckduckgo, rate_limit: 10` or `backend: :google, api_key: ...`

**Edge cases:**
- Content filtering: search results may contain unsafe content. Use the same trust-gating as other tools.
- Legal: scraping search results may violate ToS. DuckDuckGo's lite endpoint is generally tolerated for non-commercial use but document the risks.

**Prerequisites:** ToolDispatch (already handles built-in tools).

---

## 29. Performance Benchmark Suite — Score: 4/10

**What:** A formal benchmark suite that measures agent throughput, LLM call latency, tool dispatch overhead, event log write throughput, and cluster scaling efficiency. Published as a GitHub action that runs on every release.

**Why:** The BEAM thesis needs evidence. "Shem is faster than LangChain for concurrent agents" is a claim — benchmarks make it provable. Also catches regressions.

**Implementation sketch:**
- `bench/` directory with Benchee-based benchmarks
- Benchmarks:
  - Agent spawn throughput (agents/second)
  - Concurrent agent throughput (10, 50, 100, 500 agents)
  - LLM call latency (with stub transport, measure middleware overhead)
  - Event log write throughput (events/second)
  - Tool dispatch latency
  - Cluster message latency (two nodes, same machine)
  - Memory usage per agent
  - Recovery time: kill an agent, measure time to restart under supervision
- Published as a standalone `benchee` report, also as a GitHub Action check on PRs

**Prerequisites:** None. This is measurement-only.

---

## 30. Blog Post / Demo Video Series — Score: 8/10

**What:** A series of short (2–5 min) demo videos + accompanying blog posts showing:
1. "Run 50 agents concurrently — no GIL, no asyncio"
2. "Time-travel debugging: rewind, fork, and diff your agent's reasoning"
3. "Kill a node mid-task — agents redistribute automatically"
4. "Adversarial red teaming: agents that break and fix themselves"
5. "LangChain user? Here's your agents on BEAM in 5 minutes"

**Why:** Shem's differentiators are invisible from code. A video of the timeline viewer (feature #2) or a live cluster demo makes the BEAM advantage tangible. LangChain has mindshare backed by good documentation and demos. Shem needs the same to compete.

**Implementation notes:**
- Each video should show a single, clear, surprising thing that Python frameworks can't do
- Screencast the TUI or web UI
- Show the event log replay with branching — this is the killer demo
- Publish on YouTube, link from README

**Prerequisites:** At minimum, the timeline viewer web UI.

---

## Product Concept: "Shem" — The Transparent AI Assistant

### One-line positioning

> The first AI assistant you can debug.

### What it is

Shem is a personal AI assistant accessible from chat apps (WhatsApp, Telegram, iMessage) or the terminal — like OpenClaw — but with one thing no other assistant offers: **a complete, replayable, forkable timeline of everything it did and why.**

### How it works from a user's perspective

```
You (via WhatsApp): /shem deploy the site

Shem: Starting deployment. I'll:
        1. Run tests           → passed (142 tests, 0 failures)
        2. Build the app       → done
        3. Deploy to staging   → done
        4. Run smoke tests     → 2 failures detected — pausing for review

       /timeline — see exactly what happened
       /fork at 3 — try a different deploy target
       /diff with last deploy — see what changed

You: /timeline
     [Web browser opens showing the full event timeline — every step, every
      tool call, every LLM reasoning trace, expandable and searchable]
```

### Why people switch from OpenClaw / Hermes

| Reason | Detail |
|---|---|
| **"Show your work"** | Every action is recorded. You can see *why* it did something, not just *what* it did. |
| **Mistakes are fixable, not fatal** | Fork at the mistake, correct the prompt, resume. No starting over. |
| **Audit trail** | Every tool invocation logged with timestamps and reasoning. Useful for compliance, trust, and learning. |
| **Trust scores you can see** | Tools earn trust through successful use. You can inspect the score and block low-trust tools. |
| **Shareable timelines** | A link to your assistant's full reasoning chain. "Here's how I built this." |
| **Self-improving** | Agents write, test, and graduate their own tools under adversarial pressure. |
| **Truly concurrent** | Run 5 agents at once without anything blocking. Fan-out, map-reduce, debate — real parallelism. |

### Core product milestones

**Phase 0 — "Infrastructure" (score: prerequisite)**
- OpenAI/Anthropic transports, Dockerfile, CI
- The table-stakes stuff Shem needs to be installable at all

**Phase 1 — "Shem for yourself" (score: 10/10 — the product)**
- `curl -fsSL https://shem.sh/install.sh | bash` — one-command install
- Works from WhatsApp and Telegram out of the box
- Web Timeline Viewer with `/timeline`, `/fork`, `/diff`, `/share`
- Built-in web search tool, built-in code reading/writing
- Cloud LLM support (OpenAI, Anthropic) configured via environment variables

**Phase 2 — "Shem for teams" (score: 8/10)**
- Human-in-the-loop handoff protocol
- Multi-agent orchestration (fan-out, DAG workflows)
- Trust-weighted governance dashboard
- Event log export for compliance
- Multi-node deployment via docker-compose

**Phase 3 — "Shem for developers" (score: 7/10)**
- Python SDK — use Shem as a reliable backend from any Python app
- GitHub bot integration — `/shem` on issues and PRs
- Tool hot-reloading and custom tool development
- LangChain bridge (or OpenAI-compatible API server)

**Phase 4 — "The network" (score: 5/10)**
- Capability Marketplace for community tools
- Shem-to-Shem federation across organizations
- Agent blueprint library

## Prioritized Roadmap

| Tier | Features | Why together |
|---|---|---|
| **Phase 0 — Now** | OpenAI/Anthropic transports, Dockerfile, CI | Table stakes — needed before anyone can install |
| **Phase 1 — Next** | curl\|bash install, Chat app integration, Web Timeline Viewer, Web search, Cloud LLM support | The product launch — transparent assistant that people actually use |
| **Phase 2 — Soon** | HITL handoff, Multi-agent orchestration, Trust dashboard, Audit export, docker-compose cluster | Team-grade features |
| **Phase 3 — Later** | Python SDK, GitHub bot, Tool hot-reload, OpenAI-compat server | Developer ecosystem |
| **Phase 4 — Much later** | Marketplace, Federation, Blueprints | Network effects |

---

## Scoring Summary

| # | Feature | Score | Tier |
|---|---|---|---|
| 1 | Python SDK | 10 | Next |
| 2 | Web Timeline Viewer | 10 | Next |
| 30 | Demo videos | 8 | Next |
| 6 | OpenAI/Anthropic transports | 9 | Now |
| 7 | Dockerfile & Release | 8 | Now |
| 8 | CI Pipeline | 7 | Now |
| 4 | Timeline-native memory | 8 | Soon |
| 11 | Multi-agent orchestration | 7 | Soon |
| 13 | Human-in-the-loop handoff | 7 | Soon |
| 21 | Checkpoint/restore across restarts | 7 | Soon |
| 25 | CLI tool (`shem` command) | 6 | Soon |
| 3 | LangChain bridge | 7 | Later |
| 5 | Observer dashboard | 6 | Later |
| 9 | OpenTelemetry | 5 | Later |
| 12 | Tool hot-reloading | 6 | Later |
| 14 | HTTP API server | 7 | Later |
| 15 | Prometheus metrics | 5 | Later |
| 18 | Semantic search over logs | 6 | Later |
| 20 | Mnesia/SQLite backend | 6 | Later |
| 22 | Config as code | 5 | Later |
| 24 | GitHub/GitLab bot | 6 | Later |
| 27 | Shem-to-Shem federation | 5 | Later |
| 28 | Web search tool | 5 | Later |
| 10 | Capability Marketplace | 4 | Later |
| 16 | Event log export / audit | 4 | Later |
| 17 | Agent blueprints | 5 | Later |
| 19 | Container sandbox | 5 | Later |
| 23 | WASM execution | 4 | Later |
| 26 | Mermaid diagram export | 3 | Later |
| 29 | Benchmark suite | 4 | Later |

---

*Last updated: 2026-06-06*
