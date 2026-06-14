# Phase 40 — Agent Failover, Evacuation & Placement Design Spec

**Date:** 2026-06-13
**Phase:** 40 of 41 (distributed mesh series)
**Status:** Approved, pending implementation plan

---

## Overview

Three capabilities that make agents resilient to node death and placement-aware:

1. **Crash recovery** — agents survive unplanned node death via Horde redistribution and Mnesia checkpoints
2. **Graceful evacuation** — SIGTERM triggers an explicit push-handoff: checkpoint flush → start on survivor → clean stop
3. **Node capability registry + placement** — nodes publish labels; agents declare placement preferences; resolution is soft by default, strict on demand

These build directly on Phase 39 (MnesiaStore): any surviving node can read any session's checkpoint without touching the dead node's filesystem.

---

## Section 1: Crash Recovery

### Restart strategy

Change `restart: :temporary` to `restart: :transient` in `AgentSupervisor.start_agent/3`'s child spec.

With Horde + `:transient`: abnormal exits (node death) trigger redistribution; clean stops (`:normal`, `:shutdown`) do not. Node death produces abnormal exits, so Horde automatically restarts affected agents on surviving nodes. `Agent.Server.init/1` already calls `Checkpoint.reconstruct` and handles the `:not_found` / `{:ok, checkpoint}` cases — no agent code changes needed beyond the checkpoint payload addition below.

### Checkpoint payload

Add `node: Node.self()` to the saved payload so the resumed instance can identify where the agent previously ran:

```elixir
# Checkpoint.save/2
%{
  history:     state.history,
  turn_count:  state.turn_count,
  config:      state.config,
  node:        Node.self()
}
```

### agent_resumed event

Update `Agent.Server.init/1` resume branch to include `prior_node`:

```elixir
EventLog.append(session_id, :agent_resumed, %{
  node:       Node.self(),
  prior_node: checkpoint.node,
  turn:       checkpoint.turn_count
})
```

### Tests

- Agent running on peer node A; kill A; assert agent restarts on local node with correct turn count
- `prior_node` in `:agent_resumed` event matches the dead node

---

## Section 2: Node Capability Registry

### Module: `Shem.NodeRegistry`

A GenServer backed by an ETS table. Maintains a live map of `node() → %{String.t() => String.t()}` labels for every node in the cluster.

**Why ETS, not Mnesia:** Node labels are ephemeral presence data. Persisting in Mnesia leaves stale entries from dead nodes. ETS + `:nodedown` cleanup is fast, correct, and self-healing.

### Label configuration

Nodes declare labels in config:

```elixir
config :shem, node_labels: %{
  "model" => "llama3",
  "gpu"   => "true"
}
```

Labels can also be updated at runtime via `NodeRegistry.set_labels/1` — useful for hot-loaded models or dynamic capability changes.

### Sync protocol

- **Startup:** `NodeRegistry` reads own labels from config and writes them to local ETS, then RPCs every node in `Node.list()` to fetch their labels (bootstrap). This covers nodes that were already connected before this node started — those nodes won't emit `:nodeup` to the newcomer.
- **`:nodeup`:** `Shem.Cluster` calls `NodeRegistry.sync_node(new_node)` — RPCs the new node for its labels, stores locally. Every existing node independently receives `:nodeup` and does the same, so the new node's labels propagate to the whole cluster without any additional coordination.
- **`:nodedown`:** `Shem.Cluster` calls `NodeRegistry.remove_node(node)` — entry deleted immediately, stale data never accumulates.

### API

```elixir
NodeRegistry.labels(node())                          # → %{String.t() => String.t()}
NodeRegistry.nodes_matching(%{"model" => "llama3"})  # → [node()] — superset match
NodeRegistry.set_labels(%{"gpu" => "true"})          # update own node's labels at runtime
NodeRegistry.all()                                   # → %{node() => labels} — full table
```

`nodes_matching/1` returns all nodes whose label map is a superset of the requested selector (all selector keys must be present with matching values).

### Tests

- Labels set in config appear in `NodeRegistry.labels(Node.self())`
- Peer node with labels joins; local `NodeRegistry.nodes_matching/1` returns it
- Peer node dies; its entry is removed from the table
- `set_labels/1` updates own entry; other nodes see the change via sync

---

## Section 3: Placement

### Agent.Config

Add a `placement` field (default `:any`):

```elixir
defstruct [..., placement: :any]

@type placement ::
        :any
        | {:node, node()}
        | {:labels, %{String.t() => String.t()}}
        | {:labels, %{String.t() => String.t()}, :required}
```

### Resolution

`AgentSupervisor` gains a private `resolve_placement/1` called before `start_child`:

| Placement | Behaviour |
|---|---|
| `:any` | Pass through; Horde distributes freely |
| `{:node, n}` | Verify `n` in `Node.list()`, error if not (always strict) |
| `{:labels, sel}` | `NodeRegistry.nodes_matching(sel)` → pick one at random; if no match, fall back to `:any` and log `:placement_miss` |
| `{:labels, sel, :required}` | Same lookup; if no match, return `{:error, :no_matching_node}` |

### Placement miss event

When a soft label placement falls back to `:any`, append to the EventLog:

```elixir
EventLog.append(session_id, :placement_miss, %{
  requested: selector,
  landed_on: chosen_node
})
```

Visible in the TUI history browser and queryable via the REST API.

### Horde Registry metadata

The resolved node is stored in Horde Registry metadata alongside the process registration:

```elixir
{via, %{node: resolved_node, placement: original_placement}}
```

This is the source of truth for Phase 41 TUI node badges and `GET /api/agents` `node` field.

### Tests

- `:any` — agent starts, no placement event logged
- `{:node, n}` — agent starts on node `n`; `{:node, unknown}` returns `{:error, :no_matching_node}`
- `{:labels, %{"model" => "x"}}` soft — matching node selected; no matching node falls back to `:any` and logs `:placement_miss`
- `{:labels, %{"model" => "x"}, :required}` — returns `{:error, :no_matching_node}` when no match

---

## Section 4: Graceful Evacuation

### SIGTERM interception

`Shem.Cluster.init/1` adds `Process.flag(:trap_exit, true)`. The `terminate/2` callback runs evacuation before the GenServer exits, blocking OTP shutdown until evacuation completes or times out.

### Agent.Server: flush_checkpoint

New `handle_call`:

```elixir
def handle_call(:flush_checkpoint, _from, state) do
  Checkpoint.save(state.session_id, state)
  {:reply, :ok, %{state | status: :evacuating}}
end
```

`:evacuating` status prevents `:run_turn` from firing between flush and termination. The status is intentionally not persisted — a resumed agent always starts `:running`.

### AgentSupervisor.evacuate_all/0

Finds all agents local to this node, processes them concurrently:

```
for each local agent (concurrent, evacuation_timeout_ms per agent):
  1. GenServer.call(pid, :flush_checkpoint)
  2. resolve target node — honor agent's placement labels among surviving nodes;
     fall back to :any if no match, log :placement_miss
  3. Horde.DynamicSupervisor.start_child(target_spec)
  4. wait for new instance in Horde.Registry (up to `evacuation_timeout_ms`)
  5. Horde.DynamicSupervisor.terminate_child(local_pid)
```

**Timeout:** `Application.get_env(:shem, :evacuation_timeout_ms, 5_000)` per agent. On timeout: log warning, proceed. The last checkpoint written to Mnesia at turn start remains recoverable.

**Partial failure:** If `start_child` on the target node fails, log `:evacuation_failed` event and continue with remaining agents. Node shutdown is not blocked by a single agent failure.

### Shem.Cluster.terminate/2

```elixir
@impl true
def terminate(_reason, _state) do
  Logger.info("Shem.Cluster: evacuating agents before shutdown")
  Shem.AgentSupervisor.evacuate_all()
end
```

### EventLog events added in this phase

| Event | Payload |
|---|---|
| `:agent_resumed` | `node`, `prior_node`, `turn` (prior_node is new) |
| `:placement_miss` | `requested` (selector), `landed_on` (node) |
| `:evacuation_failed` | `session_id`, `reason` |

### Tests

- SIGTERM (`:init.stop/0`) on node with running agent → checkpoint flushed → agent restarts on survivor with no turn regression
- Placement labels honored during evacuation; `:placement_miss` logged when no match
- Evacuation timeout: agent that hangs on `:flush_checkpoint` does not block node shutdown beyond `evacuation_timeout_ms`
- `AgentSupervisor.evacuate_all/0` completes even when one agent's handoff fails

---

## Files touched

| Action | Path |
|---|---|
| Create | `lib/shem/node_registry.ex` |
| Modify | `lib/shem/application.ex` — add `NodeRegistry` to supervision tree |
| Modify | `lib/shem/agent.ex` — add `placement` field to `Config` |
| Modify | `lib/shem/agent/checkpoint.ex` — add `node` to saved payload |
| Modify | `lib/shem/agent/server.ex` — add `:flush_checkpoint` handler, update `:agent_resumed` event |
| Modify | `lib/shem/agent_supervisor.ex` — change restart to `:transient`, add `resolve_placement/1`, add `evacuate_all/0` |
| Modify | `lib/shem/cluster.ex` — trap exits, add `terminate/2`, call `NodeRegistry.sync_node/1` and `NodeRegistry.remove_node/1` on node events |
| Create | `test/shem/node_registry_test.exs` |
| Create | `test/shem/distributed/failover_test.exs` |
| Modify | `test/shem/agent_supervisor_test.exs` — placement tests |
| Modify | `test/shem/cluster_test.exs` — evacuation tests |
