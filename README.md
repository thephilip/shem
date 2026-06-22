<p align="center">
  <img src="shem.png" alt="Shem" width="480">
</p>

<h1 align="center">shem</h1>

<p align="center">
  <strong>The first AI agent platform you can actually debug.</strong>
</p>

<p align="center">
  <a href="https://github.com/thephilip/shem/actions/workflows/ci.yml">
    <img src="https://github.com/thephilip/shem/actions/workflows/ci.yml/badge.svg" alt="CI">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" alt="Apache 2.0 License">
  </a>
</p>

---

Shem is a general-purpose AI agent platform that runs on your machine.
Ask it to review your code, research a topic, draft a document, or audit
a security posture — then watch exactly what it did and why, turn by turn,
with a hash-chained, replayable event log no Python-based framework can match.

Works with Claude, ChatGPT, Ollama, llama.cpp, and any OpenAI-compatible API.
Or skip the LLM entirely and use Shem as a tool server for Claude Code.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/thephilip/shem/master/install.sh | bash
```

Supports Linux x86_64, macOS Intel, and macOS Apple Silicon. No Elixir or Erlang installation required — the runtime is bundled.

Or with Docker:

```bash
docker run -it --rm \
  -v "$PWD":/workspace \
  -e SHEM_LLM_URL=http://host.docker.internal:11434 \
  ghcr.io/thephilip/shem:latest
```

## What no other agent framework does

Every agent run is a hash-chained event log you can **rewind, fork, and replay**.

Hit a bad answer at turn 7? Fork the session *at turn 6*, change one thing —
the prompt, a tool result, the model — and replay both timelines side by side.
The branch is deterministic: same inputs, same run. You're not re-rolling the
dice and hoping; you're isolating the variable that mattered.

```
session a3f ──┬── turn 6 ──● fork here
              │            └── turn 7 (gpt-4)    → wrong
              └── turn 6' ──── turn 7 (claude)   → right
```

Python-based frameworks can't do this — they log text you read after the fact.
Shem gives you a timeline you re-run. Open `/timeline`, click any event, fork it.

And because the log is sha256 hash-chained per session, a retroactive edit is
*detectable* (`GET /api/sessions/:id/verify`) — the replay you trust can't be
quietly rewritten.

## Why Shem?

**Real concurrency.** Built on the BEAM (Erlang VM). Agents run as supervised OTP processes. No GIL, no asyncio, no mystery crashes under load.

**Steerable.** Pause a running agent at its next turn boundary (`Space`), inject a course-correction, resume. Kill it outright (`Ctrl+K`). Fence it to a directory (`/fence <path>`). The agent is a process you control, not a request you wait on.

**Self-improving, with receipts.** Agents write and graduate their own tools. Tools that prove invariants with property-based tests graduate clean; example-only tools graduate at reduced trust. A red-team agent hardens every graduated tool, and trust scores gate execution.

## Quick start

```bash
shem setup     # one-time: pick an LLM backend (Ollama, llama.cpp, OpenAI, Anthropic...)
shem           # start in any project directory
```

Shem detects your project type automatically and injects the working directory
into the agent's context. Type anything to start a conversation.

```
> what does this project do?
> /preset security
> review the auth module for vulnerabilities
> /help
```

While an agent runs: `↑↓`/`Tab` switch between agents · `Space` pause/resume the focused agent (type while paused to steer it) · `Ctrl+K` kill · `Alt+Enter` newline in the prompt · `/` opens command autocomplete · `h` browse past sessions as readable transcripts.

## Use from Claude Code (no LLM required)

Shem doubles as an MCP tool server. Claude Code is the brain; Shem is the
self-extending tool backend and agent orchestrator:

```bash
shem start --headless
claude mcp add --transport sse shem http://127.0.0.1:4000/mcp/sse
```

Claude Code then gets eight tools:

| Tool | What it does |
|------|-------------|
| `execute_code` | Run scratch Elixir (nothing persists) |
| `graduate_tool` | Compile + test + register a permanent tool (property tests rewarded) |
| `list_tools` / `invoke_tool` | Discover and call graduated tools |
| `spawn_agent` | Start a Shem agent with a goal — returns immediately |
| `agent_status` | Poll an agent; works even after it finished |
| `list_agents` / `stop_agent` | See and stop what's running |

The self-extending pattern: Claude Code graduates a new tool once, then invokes
it in every future session. The parallel pattern: spawn several Shem agents for
independent subtasks and poll them concurrently.

## Presets

| Preset | Purpose |
|--------|---------|
| `general` | Conversational assistant. The default. |
| `coder` | Code reading, writing, refactoring, debugging. |
| `researcher` | Information synthesis, summarisation, structured notes. |
| `writer` | Drafting, editing, tone adjustment. |
| `security` | Vulnerability identification, threat modelling. Conservative tool access. |
| `explorer` | Codebase and filesystem exploration. Read-only. |

Switch mid-conversation: `/preset coder` · Create your own: `/hire <name> <role description>`

## Interfaces

Everything runs on one port (default `4000`):

- **TUI** — `shem` (dashboard with live host metrics, agent panel, streaming output)
- **Web UI** — `http://127.0.0.1:4000/` (chat) and `/timeline` (browse, inspect, and **fork** any session from any event)
- **REST API** — `/api` (agents, presets, sessions, routes, chain verification)
- **MCP** — `/mcp/sse` (see above)
- **Python SDK** — `sdk/python` (`Client`, `Agent`, `@tool` decorator)

## Configuration

`shem setup` writes `~/.config/shem/config.yaml`. Inspect or change anything:

```bash
shem config list
shem config get llm.default.model
shem config set llm.default.url http://localhost:11434
```

Other commands: `shem status` · `shem upgrade` · `shem version`.

## Build from source

Requires Elixir 1.19+ and OTP 29+.

```bash
git clone https://github.com/thephilip/shem
cd shem
mix deps.get
mix run --no-halt         # development
# or
MIX_ENV=prod mix release
./_build/prod/rel/shem/bin/shem start
```

## Roadmap

See [`docs/superpowers/specs/2026-06-12-roadmap-v2-design.md`](docs/superpowers/specs/2026-06-12-roadmap-v2-design.md).

Upcoming: the launch demo (multi-node cluster surviving node loss mid-task, timeline forking, red-team self-patching), human-in-the-loop approvals, and hive_mind trust-weighted consensus.

## License

Apache 2.0 — see [LICENSE](LICENSE).
