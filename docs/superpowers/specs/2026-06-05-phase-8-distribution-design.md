# Phase 8: Distribution Layer — Design Spec

**Date:** 2026-06-05
**Status:** Approved

---

## 1. Overview

Phase 8 adds a BEAM-native distribution layer to Shem. Three goals, one coherent design:

1. **Horizontal scaling** — agents run across a fleet of nodes; `Horde.DynamicSupervisor` places and balances them.
2. **Fault tolerance** — when a node dies, Horde restarts its agents on surviving nodes; `Agent.Server` reconstructs state from an EventLog checkpoint.
3. **Resource isolation** — the Lab sandbox (code execution) can be dispatched to a dedicated node via `:rpc.call`, keeping misbehaving user code away from the orchestrator.

New deps: `horde ~> 0.9`, `libcluster ~> 3.3`.

---

## 2. New Modules

### `Shem.Cluster`
GenServer. Owns all cluster-awareness.

- Starts as a supervised child in `Shem.Application`.
- Calls `:net_kernel.monitor_nodes(true)` in `init/1`.
- Handles `{:nodeup, node}` and `{:nodedown, node}`: resyncs Horde member lists via `Horde.Cluster.set_members/2` for both `Shem.Registry` and `Shem.AgentSupervisor`.
- Public API: `nodes/0` — returns `[Node.self() | Node.list()]`.

Disabled in test via `config :shem, start_cluster: false`.

### `Shem.Agent.Checkpoint`
Pure module. No side effects.

- `save(session_id, state)` — appends `:agent_checkpoint` to EventLog:
  `%{history: state.history, turn_count: state.turn_count, config: state.config}`
- `reconstruct(session_id)` — scans the session for the latest `:agent_checkpoint` event.
  Returns `{:ok, %{history, turn_count, config}}` or `:not_found`.

Reconstruction reads only the latest checkpoint — no fold over individual events. The checkpoint is canonical state; the fine-grained event trace is preserved for observability and branching.

---

## 3. Modified Modules

### `Shem.Application`
Adds three new supervised children:

```elixir
{Cluster.Supervisor, [topologies(), [name: Shem.Cluster.Supervisor]]},
{Horde.Registry, [name: Shem.Registry, keys: :unique]},
{Horde.DynamicSupervisor, [name: Shem.AgentSupervisor, strategy: :one_for_one]},
```

The existing local `Registry` child and `Shem.AgentSupervisor` child are removed.
`Shem.Cluster` is added as a supervised child (started after Horde processes).

Topology config is read from `Application.get_env(:libcluster, :topologies)`.
`start_cluster: false` (test) suppresses `Cluster.Supervisor` and `Shem.Cluster`.

### `Shem.AgentSupervisor`
Switches from `use DynamicSupervisor` to `use Horde.DynamicSupervisor`.

`start_agent/2` changes:

1. Generates `session_id` before starting the agent (moved out of `Agent.Server.init/1`).
2. Embeds `session_id` in the child spec args so Horde can pass it on redistribution.
3. Changes restart strategy from `:temporary` to `:transient` — allows Horde to redistribute on node death; won't restart on normal exit.

```elixir
def start_agent(name, %Config{} = config) do
  session_id = generate_session_id()
  via = Shem.ProcessRegistry.via_tuple(name)
  child_spec = %{
    id: name,
    start: {Shem.Agent.Server, :start_link, [{name, config, session_id, [name: via]}]},
    restart: :transient
  }
  Horde.DynamicSupervisor.start_child(__MODULE__, child_spec)
end
```

### `Shem.ProcessRegistry`
`via_tuple/1` is unchanged — Horde accepts the same `{:via, Horde.Registry, {Shem.Registry, name}}` format.

### `Shem.Agent.Server`
`init/1` receives `{name, config, session_id}` (session_id moved upstream).

On init, calls `Checkpoint.reconstruct(session_id)`:
- `:not_found` → fresh start; opens EventLog session via `EventLog.start_session(session_id)` — `EventLog` gains an arity-1 variant that accepts an external id rather than generating one.
- `{:ok, checkpoint}` → resume; uses checkpointed `history`, `turn_count`, and `config`; appends `:agent_resumed` event: `%{node: Node.self(), turn: checkpoint.turn_count}`.

`handle_info(:run_turn)` calls `Checkpoint.save(session_id, state)` at the **start** of each turn, before the LLM call. Worst-case data loss on node death: the in-flight turn. History through the previous turn is always checkpointed.

### `Shem.LLM.BudgetServer`
Gains one new config key: `budget_node_tokens`. Read in `init/1` with fallback to existing `budget_total_tokens` for backwards compatibility.

Semantics: this node is authorised to spend up to `budget_node_tokens` tokens. No cross-node coordination. The global cap is expressed at configuration time — cluster operators divide the total budget across nodes by setting this key per node.

### `Shem.Lab.Executor`
`run/2` gains an optional `node:` key:

```elixir
Lab.Executor.run(source, node: :"shem_sandbox@localhost")
# nil / absent → local execution (existing behaviour unchanged)
```

When `node:` is set, dispatches via `:rpc.call/4` to the target node. Timeout, result format, and error shape are identical to the local path. `{:badrpc, reason}` is normalised to `{:error, reason}`.

`GraduationGate` reads `Application.get_env(:shem, :lab_executor_node)` and passes it through. No changes to `ToolDispatch` or `Agent.Server`.

### `Shem.TUI.Views.Dashboard`
Gains `Cluster: N nodes` line in the 500ms tick, calling `Shem.Cluster.nodes/0`.
Falls back to `"Cluster: 1 node (local)"` when clustering is disabled.
Existing `Agents: N running` line is unchanged — `DynamicSupervisor.count_children/1` works with Horde and counts only local agents.

---

## 4. Configuration

### `config/dev.exs`
```elixir
config :libcluster,
  topologies: [
    shem: [
      strategy: Cluster.Strategy.Gossip,
      config: [port: 45892, multicast_addr: "230.1.1.251"]
    ]
  ]

config :shem, budget_node_tokens: 10_000
config :shem, lab_executor_node: nil   # set to :"shem_sandbox@localhost" to enable
```

### `config/test.exs`
```elixir
config :shem, start_cluster: false
```

### Future: Kubernetes (`config/runtime.exs`)
```elixir
config :libcluster,
  topologies: [
    shem: [
      strategy: Cluster.Strategy.Kubernetes,
      config: [
        mode: :hostname,
        kubernetes_selector: "app=shem"
      ]
    ]
  ]
```

---

## 5. Migration Flow

```
Node A dies mid-turn 4
  → :nodedown received by Shem.Cluster on Node B
  → Horde.Cluster.set_members called — Horde detects orphaned agents
  → Horde.DynamicSupervisor restarts agent on Node B with original child spec
  → Agent.Server.init: Checkpoint.reconstruct(session_id) → {:ok, checkpoint}
  → history and turn_count restored through turn 3
  → :agent_resumed appended to EventLog
  → :run_turn sent — agent continues at turn 4
```

---

## 6. EventLog Events (additions)

| Event type          | Payload                                      |
|---------------------|----------------------------------------------|
| `:agent_checkpoint` | `%{history, turn_count, config}`             |
| `:agent_resumed`    | `%{node: atom(), turn: non_neg_integer()}`   |

---

## 7. Testing

### `Shem.Agent.Checkpoint` (pure unit tests)
- `save/2` appends `:agent_checkpoint` with correct payload (FakeStore).
- `reconstruct/1` returns `:not_found` on empty session.
- `reconstruct/1` returns latest checkpoint when multiple exist.
- Round-trip: save then reconstruct returns identical state.

### `Shem.Agent.Server` (integration tests)
- Fresh start: no checkpoint → `:not_found` path; session opens normally.
- Resume path: pre-seed EventLog with a checkpoint, start Server with same `session_id` → assert `turn_count` and `history` match checkpoint; assert `:agent_resumed` event appended.
- Checkpoint written before each turn: after N turns, EventLog has N `:agent_checkpoint` events.

### `Shem.Cluster` (unit tests, `start_cluster: false`)
- `nodes/0` returns `[Node.self()]` when no peers connected.
- `handle_info({:nodeup, node}, state)` calls `Horde.Cluster.set_members` (mock/stub).
- `handle_info({:nodedown, node}, state)` calls `Horde.Cluster.set_members` (mock/stub).

### `Shem.Lab.Executor` (unit tests)
- `node: nil` → local execution path (existing tests unchanged).
- `node: some_node` → `:rpc.call` dispatched (mock node, assert args).
- `{:badrpc, :nodedown}` → normalised to `{:error, :nodedown}`.

---

## 8. Out of Scope (Phase 9+)

- Streaming LLM responses
- Multi-agent coordination / trust-weighted consensus
- Named agent presets from app config
- Timeline Mode TUI view for agent runs
- Mnesia-backed distributed EventLog
- Runtime budget rebalancing across nodes
- Red-team adversarial agents
