# Shem Roadmap: Phases 28–36

## Product vision

Shem is a general-purpose AI agent platform — for coding, research, writing, security audits, and more. It competes with Hermes, OpenClaw, and similar tools by doing the same job better: real BEAM concurrency (no GIL, no asyncio), a built-in trust and safety layer, and a complete replayable audit trail that Python-based frameworks cannot replicate.

The target user is a developer or researcher who has used an AI agent tool before and wants something self-hosted, faster, and safer. "Do it better" is the thesis.

Shem is not just a coding tool. The same agent infrastructure that reviews code can synthesise research, draft documents, or audit a security posture. The presets and tool access change; the engine stays the same.

### Positioning

- **vs. Hermes / OpenClaw:** Same job, better engine. BEAM gives you real concurrency, fault recovery, and a timeline you can debug. Python gives you asyncio and hope.
- **vs. LangChain / CrewAI:** Not a framework you import. A platform you run. The MCP server means any MCP-compatible tool can use Shem as a backend — you don't need to rewrite anything.
- **For enterprise:** The event log is an immutable audit trail. Every agent decision, every tool call, every trust score — logged, replayable, exportable. That's a compliance story no other agent platform has.

### One-line hook (for README)

> The first AI agent platform you can actually debug.

---

## Roadmap

### Phase 28 — First-Run Experience (spec: `2026-06-08-phase-28-first-run-experience-design.md`)

Fix the front door. A new user launches Shem, sees a welcome screen, and immediately understands what it is and what to try first. The default agent is conversational (persistent context across messages, not a one-shot task runner). Shem automatically detects the working directory and injects project context. `/help` shows a searchable command list. Six built-in presets cover the main use cases out of the box.

**Why first:** None of the impressive infrastructure matters if the first five minutes are confusing.

---

### Phase 29 — README + Install Script

A compelling README that hooks the right audience and a one-liner install script (`curl -fsSL https://install.shem.sh | bash`) that gets someone running in under two minutes.

The README leads with what Shem does for the user (not how it's built), shows a concrete terminal session, and links to the key differentiators: conversational mode, trust gating, and the timeline. It is not a feature list — it is a story.

The install script handles: downloading the appropriate OTP release binary for the user's platform, placing it in `~/.local/bin/shem`, running a smoke test, and printing "You're ready. Run `shem` to start."

**Why second:** The experience has to be right before you tell the world about it.

---

### Phase 30 — Web UI Polish

The Web UI reaches parity with the TUI: streaming token-by-token output, preset management (create, edit, delete presets from the browser), and the conversational chat layout introduced in Phase 28. The Web UI becomes a first-class interface, not an afterthought.

---

### Phase 31 — hive_mind + Shadow Agent

Two safety features that make Shem meaningfully better than single-agent tools:

**hive_mind (The Council):** For any task, spawn N agents with different presets. They each produce an output independently. A consensus round picks the best answer (or flags disagreement for human review). The number of agents and presets used are configurable. Token cost is real — this is opt-in, not default.

**Shadow Agent:** A silent agent that runs in parallel with every session. It never produces visible output. It watches for security issues, hallucinated APIs, out-of-scope behaviour, and flags them as a confidence score in the TUI/Web UI. When the score drops below a threshold, it surfaces a warning. Lightweight by design — uses a fast/cheap model, reads outputs only, does not call tools.

**Confidence meter:** A small indicator in the TUI and Web UI showing the Shadow Agent's current confidence score for the session. Green/yellow/red. Clicking it shows the Shadow Agent's reasoning.

---

### Phase 32 — Timeline Viewer

The "holy shit" demo. A web UI that makes the event log navigable:

- All sessions listed with metadata (agent name, preset, duration, event count)
- Session detail: a vertical timeline of every LLM call, tool invocation, and agent turn
- Each event is expandable — see the full prompt, response, tool input/output, token count, latency
- **Fork button** on any event: branch the timeline from that point, try a different prompt, compare results
- **Diff view:** two sessions side-by-side, divergences highlighted
- **Share:** generate a read-only link to a session timeline (for local network sharing initially)

This is Shem's moat made visible. No Python framework can build this — it requires a replayable, structured event store and a runtime that can fork a running process.

---

### Phase 33 — Human-in-the-Loop Handoff

A protocol for agents to pause and request human approval before proceeding. The agent calls a built-in tool `request_approval(action, reason)` — the TUI/Web UI shows a notification, the user approves or denies, and the agent resumes or aborts.

Useful for: destructive file writes, running shell commands, sending external requests, or any action the user configured as requiring approval. Configurable per-preset and per-tool.

---

### Phase 34 — Guardrails

Three safety features addressing the "travelling agent" problem:

**Kill + rollback:** A single keystroke (`Ctrl+K` in TUI, a button in Web UI) that stops all running agents immediately and runs `git reset --hard HEAD` to undo any file changes made during the session. Requires git. Confirmation prompt before rollback.

**Scope fence:** Declare a boundary at session start: "only touch files under `/src/auth`." If an agent attempts to read or write outside the declared scope, it is automatically paused and a warning is shown. The fence is defined as a glob pattern in the session config or via `/fence <pattern>`.

**Travelling agent detection:** Monitor for agents that have drifted from their stated task — tool calls unrelated to the original task, repetitive loops, or escalating token usage without progress. Configurable thresholds. Surface as a warning in the confidence meter.

---

### Phase 35 — Python SDK

`pip install shem-client` — a thin Python wrapper over Shem's MCP endpoint. Lets Python developers use Shem as a reliable agent backend without writing Elixir.

```python
from shem_client import ShemClient
client = ShemClient("localhost:4000")
agent = client.agent("coder")
result = agent.run("refactor this function for readability")
```

Supports sync and async (`asyncio`) usage. Exposes session timeline access, preset management, and streaming responses.

---

### Phase 36 — Headroom Integration (Token Compression)

An optional `Shem.LLM.Middleware.Headroom` module that routes LLM calls through a locally-running [headroom](https://github.com/chopratejas/headroom) proxy. Headroom compresses tool outputs, file reads, and logs before they reach the context window — 60–95% token reduction with lossless retrieval on demand (originals stored locally, LLM calls `headroom_retrieve` if it needs them).

This is the answer to token drain in Phase 31's hive_mind and Shadow Agent: running 3–5 agents simultaneously is expensive without compression. Headroom is opt-in middleware — Shem works without it, but enabling it cuts multi-agent costs dramatically.

Integration approach: headroom runs as a local proxy (`headroom proxy --port 8787`); Shem detects it via config or env var and routes its LLM transport through it. No hard dependency on Python — headroom is a sidecar, not a library import.

---

### Phase 37 — GitHub Bot

A webhook receiver that makes Shem participate in GitHub workflows:

- `POST /webhooks/github` — validated via HMAC signature
- On PR open/update: automatically runs the `security` or `explorer` preset against the diff, posts a review comment
- On issue comment `/shem <instruction>`: spawns an agent with the instruction, posts the result as a reply
- Configurable per-repo: which preset runs on PRs, which tools are allowed, whether the bot can create PRs

This turns Shem into a persistent team member on any repo it's installed on.

---

## Items documented for future consideration

The following ideas from the brainstorming session are noted here for later phases. None are scheduled yet.

- **OpenAI-compatible API server** (`/v1/chat/completions`) — lets any tool that speaks OpenAI's wire format use Shem as a backend
- **Timeline-native agent memory** — replace vector DB memory with event-log replay; agents re-experience past sessions instead of querying embeddings
- **Checkpoint/restore across restarts** — agents resume from last checkpoint after Shem restarts
- **Config as code** — YAML/TOML files for agent definitions, hot-reloadable
- **Mermaid diagram export** — export session timelines as Mermaid sequence diagrams
- **Shem-to-Shem federation** — connect multiple Shem instances across the internet via TLS BEAM distribution
- **BEAM Observer dashboard** — web wrapper around Erlang's `:observer` for process-level debugging
- **Prometheus metrics endpoint** — `/metrics` for production monitoring
- **Capability Marketplace** — community-contributed presets and tools with trust scores
- **Agent blueprints** — pre-built configurations for common roles (code reviewer, data analyst, etc.)
- **Web search built-in tool** — DuckDuckGo search with no API key required
- **Performance benchmark suite** — Benchee-based benchmarks proving the BEAM concurrency advantage
