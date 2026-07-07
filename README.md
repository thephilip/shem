<p align="center">
  <img src="shem.png" alt="Shem" width="480">
</p>

<h1 align="center">shem</h1>

<p align="center">
  <strong>Rewind, fork, and replay every agent run — with tamper-evident proof of what it did.</strong>
</p>

<p align="center">
  🚧 <em>Under construction — Shem is young and moving fast. APIs shift, docs lag reality in places. The <a href="ROADMAP.md">roadmap</a> says where it's headed.</em> 🚧
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
with a hash-chained, replayable event log — and offline-verifiable proof of what happened.

Works with Claude, ChatGPT, Ollama, llama.cpp, and any OpenAI-compatible API.
Or skip the LLM entirely and use Shem as a tool server for Claude Code.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/thephilip/shem/master/install.sh | bash
```

Supports Linux x86_64 and macOS Apple Silicon. No Elixir or Erlang installation required — the runtime is bundled.

Or with Docker:

```bash
docker run -it --rm \
  -v "$PWD":/workspace \
  -e SHEM_LLM_URL=http://host.docker.internal:11434 \
  ghcr.io/thephilip/shem:latest
```

## The flight recorder

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

Most frameworks hand you traces you read after the fact; a few can replay from
checkpoints, but re-run the model as they go. Shem replays *from the recorded
events* — deterministic — and the log is hash-chained, so a replay you trust
can't be quietly rewritten. It's a timeline you *re-run*, in the browser at
`/timeline`: **scrub** the
event log to any point, **fork** at any LLM turn, and watch the original and the fork
**diverge side by side** — the divergence point marked, each lane integrity-checked.
Choose **Fork & continue** and the branch *runs forward live* — the agent resumes from
your altered state and keeps going, driven by whatever brain you point at it (including
Claude over MCP, no local model needed). You literally watch the two runs split.

**What replay promises (and what it doesn't).** Replaying *from the log* is
deterministic: LLM turns and tool results come from the recorded events, so
the same session replays identically, every time. **Fork & continue** is
different by design — the continuation runs forward *live*, so new LLM calls
re-roll and side-effecting tools execute again. Deterministic evidence
behind you, live divergence ahead of you.

And because the log is sha256 hash-chained per session, each lane carries a live
**verify badge**: a retroactive edit is *detectable* (`GET /api/sessions/:id/verify`) —
the replay you trust can't be quietly rewritten.

Logs aren't kept forever by default: old segments are GC'd into a rollup
digest (`shem gc <session>`, or automatically on append once a session passes
`keep_events`, default 100,000). The digest stays in the hash chain, so
verification and attest bundles are unaffected — a verify report on a GC'd
session reads "events 1–N pruned, digest intact; N+1–now fully replayable."
The pruned prefix is genuinely gone, though: it's summarized, not archived, so
replay or fork *inside* the pruned range is refused.

## Why Shem?

**Real concurrency.** Built on the BEAM (Erlang VM). Agents run as supervised OTP processes. No GIL, no asyncio, no mystery crashes under load.

**Steerable.** Pause a running agent at its next turn boundary (`Space`), inject a course-correction, resume. Kill it outright (`Ctrl+K`). Fence it to a directory (`/fence <path>`). The agent is a process you control, not a request you wait on.

**Self-improving, with receipts.** Agents write and graduate their own tools in **Elixir, Python, JavaScript (Deno), or Go** — each tested before it's trusted (Python/Go in a container with `pytest`/`go test`, JavaScript in a container with `deno test`). Tools that prove invariants with property-based tests graduate clean; example-only tools graduate at reduced trust. A red-team agent hardens every graduated tool, and trust scores gate execution. Graduated Python, JavaScript, and Go tools run **container-sandboxed** at invocation — `--network=none` and a read-only source mount by default — with JavaScript additionally under Deno's deny-all permission model. Tools that genuinely need more (network, a custom image, a host mount) declare it in their pack manifest and get it only with an explicit per-tool grant at install — see [PACKS.md](PACKS.md). (Without a container runtime, default-profile tools fall back to the host with a warning; elevated-profile tools refuse to run.)
Elixir tools currently compile into the host BEAM behind a static safety
scan (pure compute only — no file, system, or network access); full parity
sandboxing for Elixir is on the roadmap ([Phase 6](ROADMAP.md)).

## Built on the BEAM

Shem isn't fighting its runtime — the runtime *is* the feature. The
[BEAM](https://www.erlang.org/) (Erlang's VM) was built for telecom systems that
can't go down, and those exact properties are what agent orchestration needs:

- **[Preemptive scheduling](https://www.erlang.org/blog/a-brief-beam-primer/).** The scheduler preempts every process (~every 4,000 reductions), so no single agent can starve the others — no cooperative `async`/`await` you can accidentally block. A Python event loop can't promise this.
- **Process isolation + supervision.** Every agent is an isolated [OTP](https://www.erlang.org/doc/design_principles/des_princ.html) process with its own heap and GC. One crashing agent can't corrupt another; a [supervision tree](https://hexdocs.pm/elixir/supervisor-and-application.html) restarts it and feeds the stack trace back into the self-correction loop. Millions of processes, ~2KB each, spawned in microseconds.
- **Distribution is native, not bolted on.** [Erlang distribution](https://www.erlang.org/doc/system/distributed.html) + [Horde](https://github.com/derekkraan/horde) give supervised, location-transparent processes across machines — so an agent survives its *node* dying, not just its process. No Redis, no broker, no external orchestrator.
- **Local-first persistence.** [DETS](https://www.erlang.org/doc/man/dets.html) (single-node) and [Mnesia](https://www.erlang.org/doc/man/mnesia.html) (clustered) are in the VM. The hash-chained event log, trust scores, and graduated tools persist with zero external database.
- **[Elixir](https://elixir-lang.org/) on top.** A modern, approachable language over all of it — pattern matching, `|>` pipelines, and a genuinely great toolchain ([Mix](https://hexdocs.pm/mix/), [Plug](https://hexdocs.pm/plug/) + [Bandit](https://hexdocs.pm/bandit/) serving the Web UI, [`:telemetry`](https://hexdocs.pm/telemetry/) for live metrics).

The short version: things other frameworks reimplement — schedulers, actor
libraries, process registries, distributed pub/sub, crash recovery — the BEAM
already did, decades ago, in production. Shem spends that inheritance instead of
rebuilding it. (Further reading: ["Your agent orchestrator is just a bad clone of Elixir"](https://georgeguimaraes.com/your-agent-orchestrator-is-just-a-bad-clone-of-elixir/).)

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
shem start     # serves MCP + REST + Web UI on :4000 in the background
claude mcp add --transport sse shem http://127.0.0.1:4000/mcp/sse
```

Claude Code then gets these tools:

| Tool | What it does |
|------|-------------|
| `execute_code` | Run scratch Elixir (nothing persists) |
| `graduate_tool` | Compile + test + register a permanent tool (property tests rewarded) |
| `list_tools` / `invoke_tool` | Discover and call graduated tools |
| `spawn_agent` | Start a Shem agent with a goal — returns immediately |
| `agent_status` | Poll an agent; works even after it finished |
| `list_agents` / `stop_agent` | See and stop what's running |
| `install_pack` / `uninstall_pack` / `list_packs` | Manage git-distributed tool packs (see below) |
| `provide_turn` | Resume a client-brained agent with an action or response |

The self-extending pattern: Claude Code graduates a new tool once, then invokes
it in every future session. The parallel pattern: spawn several Shem agents for
independent subtasks and poll them concurrently.

### Client-brain agent loop (no local LLM)

Spawn an agent with `brain: "client"` to drive its turns from Claude Code:

```
spawn_agent({goal: "find bugs in auth.rs", brain: "client"})
→ agent_id (e.g., "sess_abc123")

agent_status(agent_id)
→ {status: "awaiting_turn", prompt: "Claude, please…", turn_token: "1:4782"}

provide_turn(agent_id, turn_token, "<Claude's action>")
→ {status: "awaiting_turn", prompt: "Next prompt…", turn_token: "2:9351"}
  (or {status: "done", output: "…"} when finished)

(repeat agent_status / provide_turn until done)
```

The loop is keyless (no LLM credentials), and the agent is forkable, replayable,
and crash-surviving like any Shem agent — the event log persists independent of
the brain.

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

## Tool packs

Share graduated tools as a git repo. Installing **re-runs every tool through the
graduation gate** before trusting it — third-party tools clear the same compile +
test bar as agent-authored ones, and anything that fails is reported, not
installed. Reinstalling a pack replaces the existing copy (no version churn).

Install, list, and remove from any of three surfaces:

| | Install | Remove | List |
|--|---------|--------|------|
| CLI | `shem-install <git-url> [subpath]` | `shem-uninstall <name>` | — |
| MCP | `install_pack {repo, path?}` | `uninstall_pack {name}` | `list_packs` |
| REST | `POST /api/packs {"repo":…,"path":…}` | `DELETE /api/packs/:name` | `GET /api/packs` |

```bash
shem-install https://github.com/you/my-shem-pack
shem-install file:///path/to/local/pack                          # local repo
shem-install https://github.com/you/monorepo packs/text-tools    # subdirectory
```

Shem ships a starter pack at [`packs/text-tools`](packs/text-tools) (`slugify` +
`word_count`, both property-tested) — install it straight from this repo:

```bash
shem-install file:///path/to/shem packs/text-tools
```

**Authoring a pack.** A pack is a git repo with a `pack.json` and a `tools/`
directory. Each tool is a manifest + source pair — the same shape Shem writes to
its own `graduated/` dir, so a pack is just a copy of those files:

```
pack.json
tools/
  mytool.json     # manifest
  mytool.ex       # source (.py for Python, .ts for JavaScript tools)
```

```jsonc
// pack.json
{ "name": "text-tools", "version": "0.1.0", "tools": ["mytool"] }
```
```jsonc
// tools/mytool.json
{
  "id": "mytool",
  "language": "elixir",
  "description": "increment x",
  "schema": {},
  "test_source": "defmodule MytoolTest do\n  def run do\n    %{\"y\" => 2} = Mytool.run(%{\"x\" => 1})\n    :ok\n  end\nend\n"
}
```
```elixir
# tools/mytool.ex
defmodule Mytool do
  def run(%{"x" => x}), do: %{"y" => x + 1}
end
```

`test_source` runs at install time — a tool whose test fails never lands. A
per-tool `sha256` of the installed source is recorded as provenance. Namespace
your module names per pack (e.g. `TextTools.MyTool`) to avoid cross-pack
collisions.

## Interfaces

Everything runs on one port (default `4000`):

- **TUI** — `shem` (dashboard with live host metrics, agent panel, streaming output)
- **Web UI** — `http://127.0.0.1:4000/` (chat) and `/timeline` — the visual time-travel debugger: **scrub** a session, **fork** any LLM turn, watch the original and fork **diverge side by side** (live, if you Fork & continue), each with a hash-chain **verify badge**
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

## Honest limits

No begging here — just what's true so you can decide for yourself.

- **Young and single-author.** Shem is early. APIs move, and the community is small. If you need a battle-tested framework with a big ecosystem today, this isn't it yet.
- **Not the only thing with time-travel.** LangGraph and others can rewind and fork from checkpoints. Shem's specific bet is *deterministic replay from a tamper-evident log* plus *offline-verifiable attestation* — evidence, not just traces — on the BEAM. That combination is the edge, not "debugging" as a category.
- **Elixir tools aren't sandboxed yet.** Python/JS/Go tools run container-sandboxed; Elixir tools compile into the host BEAM behind a static safety scan (pure compute only). Full parity is [Phase 6](ROADMAP.md).
- **Fork & continue re-rolls.** Replay *from the log* is deterministic. Forking forward runs live — new LLM calls re-roll and side-effecting tools execute again. That's by design, but it's not "replay."
- **Determinism has a boundary.** Only what's in the log replays deterministically. GC'd segments are summarized, not archived — replay or fork *inside* a pruned range is refused.

## Roadmap

Recently shipped: the visual time-travel debugger (scrub · fork · live side-by-side divergence · hash-chain verify badge) and container-sandboxed polyglot tools (Python/JS/Go). Upcoming: a browser **co-driver** (inject a running agent's next turn from the WebUI), human-in-the-loop approvals, and hive_mind trust-weighted consensus.

## License

Apache 2.0 — see [LICENSE](LICENSE).
