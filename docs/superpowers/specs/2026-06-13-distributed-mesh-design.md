# Distributed Agent Mesh — Design Spec

**Date:** 2026-06-13  
**Phases:** 38 / 39 / 40 / 41  
**Status:** Approved, pending implementation plan

---

## Overview

Four sequential phases that build the distributed agent mesh from cluster wiring through full TUI parity. Each phase is shippable and testable independently.

```
Phase 38 — Cluster Wiring
Phase 39 — Distributed EventLog (MnesiaStore)
Phase 40 — Agent Failover, Evacuation & Placement
Phase 41 — Node-aware TUI, Streaming & API
```

**Architectural spine:**

- `Shem.EventLog.Store` behaviour (already exists) — `DETSStore` for single-node, `MnesiaStore` for cluster. No agent code changes across any phase.
- `Shem.StreamRegistry` (currently local `Registry`) → `:pg` scope in Phase 41. Consumption model unchanged.
- Horde (`members: :auto`) already wired on `AgentSupervisor` and `Shem.Registry`. Phase 38 verifies and hardens this.
- Distributed tests use OTP `:peer` to spin up real named BEAM nodes. No mocks for distribution.

---

## Phase 38 — Cluster Wiring

**Goal:** A second Shem node joins the cluster, agents started on either node are visible to both, and the health endpoint reflects real cluster membership.

### Shem.Cluster

Currently receives `:nodeup`/`:nodedown` and discards them. Becomes the cluster lifecycle coordinator:

- `:nodeup` — log event, emit `EventLog` system event (`:cluster_node_joined`), trigger explicit Horde member sync (see below).
- `:nodedown` — emit `:cluster_node_left`, initiate evacuation handshake (Phase 40).
- `Shem.Cluster.members/0` — returns all cluster nodes.
- `Shem.Cluster.agent_count/1` — per-node agent count via Horde.

### Horde member sync

`members: :auto` on `Horde.Registry` and `Horde.DynamicSupervisor` should join automatically when libcluster connects nodes. Phase 38 writes the test that proves it. If `:auto` has a race on fast node churn, add explicit `Horde.Cluster.set_members/2` in the `:nodeup` handler as the authoritative join.

### CLI startup check

If `Node.alive?/0` is false and `start_cluster: true`, log a clear warning rather than silently running single-node with Horde doing nothing. Clustered Shem requires `--sname` or `--name` at startup.

### REST

`GET /api/cluster` — `%{self: node(), nodes: [%{node: n, agents: count, status: :up}]}`.  
`GET /api/health` — adds `cluster_size` field.

### Tests (real `:peer` nodes)

- Two nodes connect → Horde Registry membership syncs within bounded time.
- Agent started on node A is visible in `Horde.Registry` from node B.
- Node B dies → `Shem.Cluster` emits `:cluster_node_left`.

---

## Phase 39 — Distributed EventLog (MnesiaStore)

**Goal:** Any node can read any session's events. Agent redistribution after node death finds its checkpoint without touching the dead node's filesystem.

### Schema

One Mnesia table: `:shem_events`.  
Key: `{session_id, event_id}` (composite, ordered).  
Type: `disc_copies` on every cluster node — full replica per node, no quorum math, any surviving node has everything.

### Shem.EventLog.MnesiaStore

Implements `Store` behaviour:

| Callback | Implementation |
|---|---|
| `open/2` | No-op — tables are global. Returns `{:ok, session_id}` as handle. |
| `append/2` | `:mnesia.dirty_write/1` — async, sufficient; hash chain provides integrity. |
| `read_all/1` | Range scan on `session_id`, sorted by timestamp. |
| `get/3` | Point lookup by `{session_id, event_id}`. |

### Backend selection

`EventLog` checks at init: if `Node.list() != []` or `:force_mnesia` config is set, select `MnesiaStore`; otherwise `DETSStore`. Single-node installs have zero config change.

### Node onboarding

When `Shem.Cluster` receives `:nodeup`:

1. `Mnesia.change_config(:extra_db_nodes, [existing_node])` — pull schema from existing node.
2. `Mnesia.add_table_copy(:shem_events, Node.self(), :disc_copies)` — register as full replica.
3. Mnesia replicates all existing data before node is marked ready.

Idempotent — `{:error, already_exists}` from `add_table_copy` is ignored.

### Existing DETS sessions

Sessions written before cluster join stay in DETS on the originating node, accessible locally via history views. New sessions after cluster join use Mnesia. No migration script.

### Tests

- Single-node: `DETSStore` selected automatically.
- Two `:peer` nodes: write events on A, read from B.
- Node A dies mid-session: node B reads the session from Mnesia.
- New node joins live cluster: replication completes before node marked ready.

---

## Phase 40 — Agent Failover, Evacuation & Placement

**Goal:** Agents survive node death transparently, shut down gracefully without losing progress, and can be targeted to nodes by capability.

### Crash recovery

Structurally correct after Phase 39 — Horde redistributes the child spec, `Agent.Server.init/1` calls `Checkpoint.reconstruct/1`, Mnesia has the data. Phase 40 adds:

- Checkpoint payload gains `node: Node.self()` field.
- Post-restart logs `:agent_resumed` with `%{node: Node.self(), prior_node: prior_node}` so the audit trail shows the migration.

### Graceful evacuation

Signal: SIGTERM (systemd, K8s pod termination, `:init.stop/0`).

Flow:
1. `Shem.Cluster` traps exits, intercepts shutdown signal.
2. Calls `Shem.AgentSupervisor.evacuate_all/0` — for each local agent, forces immediate checkpoint flush to Mnesia, marks agent `:evacuating`.
3. Normal OTP shutdown proceeds; Horde sees processes exit cleanly, restarts on survivors.
4. Survivors find freshly-flushed checkpoints and resume mid-turn.

**Key invariant:** checkpoint flush happens before any agent process exits during graceful shutdown. If mid-LLM-call, checkpoint captures history up to the previous turn; resumed agent re-issues the current turn (LLM calls are idempotent from the agent's perspective).

**Timeout:** `evacuation_timeout_ms` (default 5000ms per agent). On timeout, checkpoint what exists and proceed.

### Placement hints

`Agent.Config` gains:

```elixir
placement: :any                    # default — Horde chooses
         | {:node, node()}         # explicit node
         | {:model, model_name}    # route to node running this model
```

`AgentSupervisor.start_agent/2` resolves placement before `start_child`:
- `:any` — no change.
- `{:node, n}` — custom `Horde.DistributionStrategy` that pins to `n`.
- `{:model, m}` — queries each cluster node's `llm_routes` config, resolves to `{:node, matching_node}`.

Resolved node stored in Horde Registry metadata — used by Phase 41 TUI and REST.

### Tests

- Crash recovery: agent on node A (`:peer`), kill A, assert agent resumes on B with correct turn count.
- Graceful evacuation: SIGTERM node A, assert checkpoint flush before exit, no turn regression on B.
- Placement `{:model, m}`: agent starts on node whose config matches the model.
- Placement `{:node, n}`: agent starts on specified node; fails fast if node not in cluster.

---

## Phase 41 — Node-aware TUI, Streaming & API

**Goal:** The TUI and API present the full cluster as a unified surface. Remote agent tokens stream to the local TUI with identical fidelity to local agents.

### Cross-node streaming via `:pg`

`Shem.StreamRegistry` (local `Registry, keys: :duplicate`) replaced by `:pg` scope `:shem_streams`.

`{:pg, :shem_streams}` added to `Shem.Application` children.

Two call sites change:

- `Agent.Server` — `:pg.get_members(:shem_streams, session_id) |> Enum.each(&send(&1, {:stream_token, session_id, token}))`. Agent is location-unaware.
- `Shem.TUI.StreamSink` — `:pg.join(:shem_streams, session_id, self())`. Sink receives tokens regardless of agent node.

`:pg` removes dead node members automatically on node death. No additional cleanup needed.

### TUI

**Agent list:** Each row gets a node badge (`[shem_a@host]`, dimmed) when the agent is remote. Sourced from Phase 40 Horde Registry metadata.

**Cluster panel:** New strip in dashboard showing connected nodes, agent count per node, node health (`:up` / `:partitioned`). Replaces current system stats strip; system stats move inline.

**Pause/steer on remote agents:** No change — `GenServer.call(via_tuple(name), :pause)` is already location-transparent via Horde Registry.

### REST & MCP

`GET /api/cluster` (new) — `%{self: node(), nodes: [%{node: n, agents: count, status: :up}]}`.

`GET /api/agents` — adds `node` field per agent (from Phase 40 registry metadata). Already queries `Horde.DynamicSupervisor.which_children` which is cluster-wide.

MCP `list_agents` — adds `node` to each result. `spawn_agent` gets optional `placement` argument mapping to Phase 40 placement hints.

### Tests

- Two `:peer` nodes: agent on A, `StreamSink` on B receives all tokens in order.
- Node A dies mid-stream: sink on B receives `:stream_done` from resumed agent on B.
- TUI renders node badge for remote agents (unit test on view render function).
- `GET /api/cluster` returns both nodes when clustered, just self when single-node.
- `:pg` scope starts cleanly in test env with `start_cluster: false`.

---

## Cross-cutting concerns

**Roadmap/memory updates:** After each phase lands, update `agent-framework.md` to mark the phase live, update `MEMORY.md` project entry, and bump the version.

**Demo sequence (Section 7 of agent-framework.md):** Phases 38–41 collectively enable the full demo: cluster of agents → kill one node → work continues → scrub EventLog → fork timeline. Phases 40 and 41 are what make it cinematic.
