# Project North Star
_Last updated: 2026-06-13 (Phase 39 complete)_

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

## Active Constraints
- The BEAM (Erlang VM) is the runtime substrate for agent orchestration. Elixir is preferred
  because it is the right tool for this domain. Other languages are used where they are the
  right tool: Python for data tasks, JS for web scraping, etc. No language dogma.
- Local-first: runs without any external services. DETS (single-node) and Mnesia (clustered)
  cover all persistence. No managed databases, no message brokers, no cloud dependencies required.
- "Multi-node" means BEAM nodes connected via Erlang distribution. Nodes can be bare metal, VMs,
  cloud instances, or K8s pods. No external orchestrator is required, but K8s is not precluded.
- TUI and Web UI are both first-class interfaces: equivalent capability, interchangeable, no
  feature gaps between them.
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

## Current Phase
**Phase 40 — Agent Failover, Evacuation & Placement**: Third of four distributed mesh phases (38–41).
Goal: agents survive node death transparently, shut down gracefully without losing progress, and can be targeted to nodes by capability.
Spec: `docs/superpowers/specs/2026-06-13-distributed-mesh-design.md`.

**Phase 39 — Distributed EventLog (MnesiaStore)**: COMPLETE. `Shem.EventLog.MnesiaStore` implements the `Store` behaviour over `:mnesia` dirty ops; `EventLog.init/1` auto-selects MnesiaStore when clustered or `:force_mnesia` set; `Shem.Cluster` onboards Mnesia on `:nodeup`; four distributed `:peer` tests pass (write/read cross-node, node death survival, new-node replication, single-node DETSStore fallback).

**Phase 38 — Cluster Wiring**: COMPLETE. `Shem.Cluster` is the lifecycle coordinator; `:nodeup`/
`:nodedown` emit EventLog system events and trigger explicit Horde member sync; `GET /api/cluster`
live; `GET /api/health` has `cluster_size`; distributed peer tests pass.

## Off-Limits Paths
- Language dogma: the principle is always "right tool for the job."
- External message brokers for agent distribution when BEAM distribution solves it natively.
- Premature abstraction or rigidity that forecloses future elegant solutions.

## Graphify
Last run: 2026-06-13 — `graphify-out/` at project root.
1034 nodes · 1127 edges · 194 communities (code only; docs/html excluded via `.graphifyignore`).
God nodes: `Shem.TUI.App` (32), `Shem.EventLog` (17), `Shem.Agent` (15), `Shem.Trust.Store` (14).
Run `graphify update .` after code changes (no API cost).
