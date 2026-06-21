# Project North Star
_Last updated: 2026-06-21_

## Core Goals
- Build an open-source, local-first, polyglot agent orchestration framework that earns adoption
  from users of Hermes and OpenClaw by delivering what those frameworks cannot: true preemptive
  concurrency, transparent fault recovery, distributed multi-node agent meshes, and deterministic
  time-travel debugging — without requiring external infrastructure.
- Self-evolving system: agents write, test, and graduate their own tools; the system grows more
  capable and uniquely tuned to each user's patterns the more it is used. Shem achieves this more
  safely than Hermes (https://github.com/nousresearch/hermes-agent), which pioneered the pattern.
- Ship the launch demo: agents running across multiple BEAM nodes → kill one node mid-task →
  work continues without interruption → scrub the event log → fork the timeline → red-team
  agent finds a flaw → agent patches itself → property tests prove correctness.

## Lead Differentiator
**Time-travel debugging is Shem's most unique capability** — no existing orchestration framework
(Hermes, LangGraph, CrewAI, etc.) offers forkable, replayable EventLog timelines. This should
lead the README narrative and demo story, not appear as a bullet point in a feature list.
The combination of distribution + self-evolution is the second differentiator: "your agents write
tools that survive node death." These two things together are what no competitor offers.

## Active Constraints
- The BEAM (Erlang VM) is the runtime substrate for agent orchestration. Elixir is preferred
  because it is the right tool for this domain. Other languages are used where they are the
  right tool: Python for data tasks, JS for web scraping, etc. No language dogma.
- Local-first: runs without any external services. DETS (single-node) and Mnesia (clustered)
  cover all persistence. No managed databases, no message brokers, no cloud dependencies required.
- "Multi-node" means BEAM nodes connected via Erlang distribution. Nodes can be bare metal, VMs,
  cloud instances, or K8s pods. No external orchestrator is required, but K8s is not precluded.
- TUI and Web UI are both first-class interfaces. The "equivalent capability, no feature gaps"
  goal is correct long-term but is a maintenance tax enforced too strictly at this stage. MCP is
  the most future-proof interface (editor integrations); REST is a thin programmatic layer; TUI
  is the interactive console. Parity enforcement is deferred until the system is more stable.
- Architectural elegance over familiarity. No premature rigidity. Systems built here should feel
  eloquent — unconventional approaches that fit the system well are preferred over familiar but
  mediocre ones.

## Closed Decisions
- BEAM/Erlang distribution for multi-node clustering — not Redis pub/sub, not a message broker.
- Horde (`AgentSupervisor`, `Shem.Registry`) for distributed process supervision.
- `EventLog.Store` behaviour: `DETSStore` (single-node) / `MnesiaStore` (clustered).
- Rollback = EventLog fork/branch. NOT git reset.
- `graduate_tool` is the self-extending primitive; property-based tests earn full trust.
- Container executor for sandboxed code generation.
- Travelling-agent / task-drift detection folds into `Shem.Shadow.Agent` — no separate detector.
- Currently committing directly to master; branching and PRs are welcome when appropriate.
- Tool authorship is delegated via `spawn_agent(preset: "<language>_toolsmith", task: "...")` —
  the delegation is explicit and visible in the EventLog, not hidden behind a wrapper builtin.
- `write_tool` builtin gains `description` (required string) and `schema` (optional JSON object,
  default empty) — stored in `tool.metadata`, surfaced in the tool manifest for future agents.
- Naming convention for language-specific tool-writing presets: `<language>_toolsmith`
  (e.g., `elixir_toolsmith`, `python_toolsmith`, `rust_toolsmith`). Convention established now;
  non-Elixir smiths are future work.
- Polyglot GraduationGate (language routing, non-Elixir executor backends) is COMPLETE in Phase 43a.
  `Tool.runtime` union, manifest persistence, PortPool, GraduationGate.Python, config-driven dispatch all shipped.
- Phase 43b (python_toolsmith preset) is next after 43a.
- **Progressive hardening**: `GraduationGate.run/3` will run a lightweight single-turn trust
  check on every graduated tool (does behavior match declared schema? do boundary inputs produce
  sensible errors?). The full adversarial red-team loop stays as an explicit opt-in primitive
  (`spawn_agent(preset: "red_team", ...)`), not wired into graduation automatically. This resolves
  the uncanny valley: hardening becomes a graduation gate, not a demo feature.
- **`Shem.Telemetry`**: `:telemetry` events for agent turn latency (p50/p99), EventLog append
  latency, PortPool round-trip time, and LLM call latency per transport. TUI dashboard surfaces
  these as live rolling stats. Forensic replay (EventLog) and real-time metrics (Telemetry) are
  complementary tools for different questions ("what happened?" vs. "is it on fire now?").
- **Maturity labeling**: README and docs distinguish distribution layer (stable, Phases 38–41)
  from self-evolution layer (experimental, Phases 42–43+). Defuses "two projects at once" concern
  without cutting scope.
- **Standalone binary**: Burrito or Bakeware packaging of `mix demo`. "Download one binary, run
  the demo in 90 seconds, zero Elixir install required" is the highest-leverage onboarding win.
- **EventLog GC + migration story**: append-only logs grow unbounded; Mnesia schema evolution
  needs a strategy before anyone runs a production cluster for more than a few days. Must be
  addressed before any production-readiness claim.

## Current Phase
**Phase 43a — Polyglot Tool Runtime**: COMPLETE (2026-06-17). 9 commits, 1057 tests passing.
`Tool.runtime` replaces `Tool.module` as `{:beam, Mod} | {:port, path}` union. `Workspace.graduate/1` writes `.json` manifest alongside source; `Registry.scan_graduated` reads manifests (legacy `.ex`-only fallback preserved). `GraduationGate.run/3` gains config-driven language dispatch (`@builtin_languages` map, overridable via app env); Elixir path extracted to `run_elixir/3`. New `GraduationGate.Python`: pytest-in-container graduation (volume-mounted temp dir), registers tool with `{:port, runtime_path}`. `Backend.Container` gains `mounts:` opt for `-v` flags. New `PortPool` GenServer (JSON lines stdio, crash-recovery, per-tool lazy-started via `PortPool.Supervisor`). `write_tool` builtin gains `language:` field (default `"elixir"`). All dispatch sites (`dispatch_lab`, MCP `invoke_tool`, `ensure_loaded`) updated to branch on `tool.runtime`. Phase 43b (python_toolsmith preset) is next.

**Phase 42 — Self-Evolution Loop (Toolsmith)**: COMPLETE (2026-06-16). 4 commits, 1041 tests passing.
`GraduationGate.run/3` takes keyword opts — `description:` and `schema:` stored in `tool.metadata` (string keys). `write_tool` builtin schema extended with `description` (required) + `schema` (optional), threaded through dispatch. New `elixir_toolsmith` builtin preset: restricted to `["write_tool", "run_code"]`, `max_turns: 8`, system prompt teaches full tool/test/graduation format including StreamData property tests and retry-on-failure. `general` and `coder` presets now point agents to `spawn_agent(preset: "elixir_toolsmith", ...)` when a capability is missing. `max_turns` plumbed from preset through `Preset.resolve/1` into `Agent.start_with_preset/3`. Loop is closed: agents can now create and immediately use new tools within a single session.

**Reasoning Visibility — COMPLETE** (2026-06-15). `reasoning_content` from qwen3 captured
in EventLog as `:agent_thinking` events; broadcast to TUI (`StreamSink`) and REST SSE
(`type: "thinking"`). 8 commits, 1028 tests passing.

**Real LLM wiring — COMPLETE** (2026-06-15). `OpenAITransport` pointed at LM Studio on
port 1234, model `"qwen"`, `llm_max_tokens: 4096`. End-to-end verified.

**Launch Demo — COMPLETE** (2026-06-15). `mix demo` runs end-to-end in ~90s.
Four phases: distributed Horde mesh (3 nodes, 2 agents) → node kill + Horde recovery in ~100ms → EventLog scrub + timeline fork → adversarial hardening loop (real rounds, trust score 0.85). All LLM responses scripted via StubTransport; no external services required. Run with `elixir --sname shem_demo -S mix demo`.

**Phase 41 — Node-aware TUI, Streaming & API**: COMPLETE (2026-06-14). Final distributed mesh phase (38–41).
`Shem.StreamRegistry` replaced by OTP `:pg` scope `:shem_streams` for cross-node token broadcast; TUI agent list shows `[node@host]` badge for remote agents; dashboard has per-node cluster strip; `GET /api/agents` list endpoint with `node` field; `GET /:id` adds `node`; MCP `list_agents` adds `node`; MCP `spawn_agent` adds `placement` arg (`any` / `node:X` / `labels:k=v`); 2 distributed streaming tests prove cross-node `:pg` membership. Non-distributed suite: 1018 pass, 9 pre-existing distributed failures (require `--sname`). All 12 distributed tests pass with `elixir --sname shem_test -S mix test --only distributed`.

**Phase 40 — Agent Failover, Evacuation & Placement**: COMPLETE (2026-06-14, 1001 non-distributed + 10 distributed tests). `:transient` restart strategy enables Horde crash recovery; `Shem.NodeRegistry` ETS-backed node label registry; `Agent.Config.placement` with soft/strict label matching; `AgentSupervisor.evacuate_all/0` implements push-handoff; `Shem.Cluster.terminate/2` wires evacuation to graceful shutdown. Key fix: removed `members: :auto` (NodeListener prevented crash recovery); explicit Horde membership lets `mark_dead` fire on `:DOWN`; `PlacementStrategy` filters to alive members only.

**Phase 39 — Distributed EventLog (MnesiaStore)**: COMPLETE. `Shem.EventLog.MnesiaStore` implements the `Store` behaviour over `:mnesia` dirty ops; `EventLog.init/1` auto-selects MnesiaStore when clustered or `:force_mnesia` set; `Shem.Cluster` onboards Mnesia on `:nodeup`; four distributed `:peer` tests pass (write/read cross-node, node death survival, new-node replication, single-node DETSStore fallback).

**Phase 38 — Cluster Wiring**: COMPLETE. `Shem.Cluster` is the lifecycle coordinator; `:nodeup`/
`:nodedown` emit EventLog system events and trigger explicit Horde member sync; `GET /api/cluster`
live; `GET /api/health` has `cluster_size`; distributed peer tests pass.

## Known Cleanup (from 2026-06-21 ponytail-audit)
Tactical debt, no architectural impact. Fix before any "production-ready" claim:
- ~~`shrink:` `BudgetCheck` and `EventLogger` each duplicate `call`/`stream` bodies~~ — DONE 2026-06-21
- ~~`yagni:` `Shadow.Supervisor` and `Adversarial.Supervisor` boilerplate files~~ — DONE 2026-06-21
- ~~`delete:` Identity `case` at end of `AgentCommon.find_by_session/1`~~ — DONE 2026-06-21
- ~~`delete:` Scratch files at repo root~~ — DONE 2026-06-21
- ~~`shrink:` `ConfigFile.format/1` hardcoded YAML template~~ — DONE 2026-06-21 (generic recursive serializer, roundtrip test added)
- ~~`shrink:` `LLM.Replay.diff/2` / `Branch.compare/1` duplication~~ — CLOSED: different operations (sparse 2-session diff vs dense N-session matrix); shared primitive already in `Utils.extract_llm_pairs`

## Off-Limits Paths
- Language dogma: the principle is always "right tool for the job."
- External message brokers for agent distribution when BEAM distribution solves it natively.
- Premature abstraction or rigidity that forecloses future elegant solutions.

## Graphify
Last run: 2026-06-17 — `graphify-out/` at project root.
1169 nodes · 1342 edges · 204 communities (code only; docs/html excluded via `.graphifyignore`).
God nodes: `Shem.TUI.App` (33), `Shem.EventLog` (21), `Mix.Tasks.Demo` (22), `Shem.Agent` (15), `Shem.Trust.Store` (14).
Run `graphify update .` after code changes (no API cost).
