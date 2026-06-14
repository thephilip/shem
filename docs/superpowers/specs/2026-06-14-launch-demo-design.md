# Launch Demo Design
_2026-06-14 (rev 2 — post-advisor review)_

## Goal

Ship the Shem launch demo: a single `mix demo` command that proves the distributed runtime end-to-end. Four phases, narrated with ANSI color, completable in ~90 seconds. No external prerequisites beyond Erlang distribution (`--sname`).

---

## Running

```bash
elixir --sname shem_demo -S mix demo
```

The task starts the full Shem application, spins up real `:peer` BEAM nodes, and runs all four phases sequentially.

---

## Architecture

A single `Mix.Task` at `lib/mix/tasks/demo.ex`. It calls `Mix.Task.run("app.start", [])` to bring up the full supervision tree (Horde, EventLog, AgentSupervisor, Adversarial, Lab, etc.), then orchestrates the demo inline.

### Stub pipeline setup

`mix demo` runs in `:dev`, where the configured LLM pipeline may point to a real transport. The task must override this at startup:

1. Set `Application.put_env(:shem, :llm_pipeline, [{Shem.LLM.StubTransport, []}])` before `app.start`.
2. Start `Shem.LLM.StubTransport.Server` locally after `app.start`.

Peer nodes need the same: after each peer starts, the `start_peer/1` helper RPCs over the pipeline config and starts the stub server on the peer.

### MnesiaStore

Phase 2 recovery requires the agent checkpoint to survive node death — it must live in the shared Mnesia log, not local DETS. Set `Application.put_env(:shem, :force_mnesia, true)` before `app.start`, so `EventLog.init/1` selects `MnesiaStore` and Mnesia is already running when peers join.

### Stub response strategy

Agents on peer nodes read the *peer's* stub server — a single global push-queue on the orchestrator never reaches them. The correct approach is **per-node stub setup**:

- Each peer's `StubTransport.Server` is started via `:rpc.call` from `start_peer/1`.
- Responses are pushed to individual peer servers via `:rpc.call`, keyed to the node where each agent runs.
- Agents are pinned to known nodes (Phase 1–2) or to the local node (Phase 4), so the target server is always known before pushing.

---

## New Code Required

### `EventLog.scrub/2`

Deletes all events in a session written after a given event ID. Required for Phase 3.

| File | Change |
|---|---|
| `lib/shem/event_log.ex` | `def scrub(session_id, after_event_id)` public API + GenServer call |
| `lib/shem/event_log/store.ex` | `@callback scrub(session_id, after_event_id)` |
| `lib/shem/event_log/dets_store.ex` | Implementation using `:dets.select_delete` |
| `lib/shem/event_log/mnesia_store.ex` | Implementation using `:mnesia.transaction` + match/delete |
| `lib/shem/event_log/fake_store.ex` | Implementation filtering the in-memory list |

Unit tests for `scrub/2` go in `test/shem/event_log_test.exs` alongside existing tests.

### `lib/mix/tasks/demo.ex`

The demo task (~300 lines). Contains:
- `@shortdoc` and `@moduledoc` for `mix help demo`
- `run/1` entry point with `Node.alive?()` guard and startup configuration
- Private helpers per phase: `phase_1/2`, `phase_2/2`, `phase_3/2`, `phase_4/2` (second arg is the local stub server pid)
- ANSI narration helpers: `banner/1`, `step/1`, `ok/1`, `info/1`, `warn/1`
- `start_peer/1` — wraps `:peer.start` with `-pa` args + RPC stub pipeline setup
- `assert_eventually/3` — polls a condition with timeout (pattern from distributed tests)
- Inline `DemoTool` module definition for the buggy `word_count` tool

---

## Stub Response Plan (per node, per phase)

### Phase 1

`worker_alpha` is pinned to `peer_b`; `worker_beta` to `peer_c`. Push responses to each peer independently — no race, different queues:

```elixir
# peer_b — for worker_alpha (max_turns: 2)
:rpc.call(peer_b, StubTransport.Server, :push_response, [peer_b_pid, "Scanning task boundaries…"])
:rpc.call(peer_b, StubTransport.Server, :push_response, [peer_b_pid, "Checkpoint written. Awaiting next instruction."])

# peer_c — for worker_beta (max_turns: 1)
:rpc.call(peer_c, StubTransport.Server, :set_default, [peer_c_pid, "Parallel analysis running on shem_c…"])
```

### Phase 2

Before killing `peer_b`, seed both surviving nodes so the relocated agent gets a response regardless of where Horde places it:

```elixir
StubTransport.Server.set_default(local_pid, "Recovered from checkpoint. Completing task.")
:rpc.call(peer_c, StubTransport.Server, :set_default, [peer_c_pid, "Recovered from checkpoint. Completing task."])
```

Then `:peer.stop(peer_b)`.

### Phase 4

Pin all `HardeningJob` agents to the local node, then push responses to the local stub server:

```elixir
Application.put_env(:shem, :adversarial_agent_placement, {:node, node()})
StubTransport.Server.push_response(local_pid, "FAILURES_FOUND: crashes on nil input")
StubTransport.Server.push_response(local_pid, "NO_FAILURES_FOUND")
StubTransport.Server.set_default(local_pid, "Task complete.")
```

---

## Phase Breakdown

### Phase 1 — Distributed Mesh

```
▶ PHASE 1: DISTRIBUTED MESH
  Starting peer nodes shem_b@localhost, shem_c@localhost...  ✓
  Wiring Horde membership across 3 nodes...  ✓
  Spawning worker_alpha → shem_b@localhost  ✓
  Spawning worker_beta  → shem_c@localhost  ✓
  worker_alpha turn 1: "Scanning task boundaries…"
  worker_beta  turn 1: "Parallel analysis running on shem_c…"
  worker_alpha turn 2: "Checkpoint written."
  ✓ Two agents ran concurrently across three BEAM nodes.
```

Steps:
1. Set `:force_mnesia` and stub pipeline env, then `Mix.Task.run("app.start", [])`
2. Start local `StubTransport.Server`
3. `start_peer(:shem_b)` and `start_peer(:shem_c)` — includes RPC stub setup, returns peer node + stub server pid
4. `Horde.Cluster.set_members/2` for `AgentSupervisor` and `Registry` across all 3 nodes
5. Poll until both peers appear in Horde membership
6. Push Phase 1 stub responses (see above)
7. Spawn `worker_alpha` with `placement: {:node, peer_b}`, `max_turns: 2`
8. Spawn `worker_beta` with `placement: {:node, peer_c}`, `max_turns: 1`
9. `Agent.await/2` on both; narrate node of each pid

### Phase 2 — Node Failure + Recovery

```
▶ PHASE 2: NODE FAILURE + RECOVERY
  Spawning worker_alpha on shem_b (max_turns: 2)...  ✓
  Seeding recovery response on surviving nodes...  ✓
  Killing shem_b@localhost mid-task...
  Waiting for worker_alpha to relocate...  ✓  (relocated in 1.4s)
  worker_alpha resumed: "Recovered from checkpoint. Completing task."
  ✓ Work continued without interruption.
```

Steps:
1. Spawn a fresh `worker_alpha` on `peer_b` with `max_turns: 2`; `assert_eventually` waits until turn 1 event is in EventLog
2. Seed recovery stub on local node + `peer_c` (see above)
3. `:peer.stop(peer_b)` — kills the node
4. `assert_eventually` polls until `Agent.node(worker_alpha)` ≠ `peer_b` (timeout 15s)
5. `Agent.await/2` on the relocated agent
6. Print elapsed time for relocation

### Phase 3 — Time-Travel (Scrub + Fork)

```
▶ PHASE 3: TIME-TRAVEL
  EventLog for worker_alpha: N events
  Last checkpoint event: evt_...
  Scrubbing events after checkpoint...  ✓  (M events remain)
  Forking timeline from turn 1 checkpoint...
  Original session: ses_AAAA...
  Fork session:     ses_BBBB...
  Two parallel histories now exist.
  ✓ Time-travel complete.
```

Steps:
1. `EventLog.events(session_id)` — list all events; find last `agent_checkpoint` event ID
2. Print event count before scrub
3. `EventLog.scrub(session_id, checkpoint_event_id)` — delete dirty tail
4. Print event count after scrub
5. `Shem.LLM.Branch.branch_after_call(session_id, 0, [%{content: "Taking the alternate path…", tokens_used: 5}], fn fork_sid -> fork_sid end)`
6. Print both session IDs. No fabricated event counts — `branch_after_call` replays the pipeline into a new session; the fork's event count is whatever the replay produces.

### Phase 4 — Adversarial Hardening (Scripted Loop)

```
▶ PHASE 4: ADVERSARIAL HARDENING
  Graduating demo tool: word_count (known bug: crashes on nil input)...  ✓
  Pinning hardening agents to local node...  ✓
  Starting HardeningJob...
  Round 1 — red-team agent scanning word_count...
    [stub] FAILURES_FOUND: crashes on nil input
  Round 1 — target agent patching word_count...
    [demo] patched version registered and graduated
  Round 2 — red-team agent verifying fix...
    [stub] NO_FAILURES_FOUND
  Trust score: 1.0 (clean)
  ✓ HardeningJob: real rounds, real EventLog, real trust store. LLM responses scripted.

═══════════════════════════════════════════════════════════════
  SHEM LAUNCH DEMO COMPLETE
  Distributed mesh ✓  Node recovery ✓  Time-travel ✓  Self-healing ✓
═══════════════════════════════════════════════════════════════
```

Steps:
1. Define `DemoTool` (`word_count`) with deliberate bug
2. `Lab.Registry.register(tool)` and `Lab.Workspace.graduate(tool)`
3. `Application.put_env(:shem, :adversarial_agent_placement, {:node, node()})` — pin agents locally
4. Push Phase 4 stub responses onto local server
5. `Shem.Adversarial.start_hardening(tool_id)` → job name + pid
6. `HardeningJob.await(pid, 30_000)` — polls until `status: :done`
7. After `{:target_done, _}` fires inside HardeningJob: demo task registers the patched `DemoTool` version and calls `Lab.Workspace.graduate/1` (narrated as `[demo]`)
8. `Shem.Trust.Store.get(tool_id)` — print outcome and score
9. Final banner

**Implementation note on the target agent:** The stub response for the target agent is plain text (signals completion). The demo task monitors `HardeningJob` status and performs the actual graduation directly. The narration uses `[demo]` brackets to be honest about who did what.

**Note on `adversarial_agent_placement`:** `HardeningJob.red_team_config/1` and `target_config/2` produce `Agent.Config` structs. The `placement` field defaults to `:any`. To honour the env override, `HardeningJob` must be updated to read `Application.get_env(:shem, :adversarial_agent_placement, :any)` when building configs.

---

## Error Handling

Each phase is wrapped in `try/rescue`. On failure:

```
✗ PHASE N FAILED: <reason>
  Hint: <context-specific hint>
```

Then `System.halt(1)`.

Specific cases:
- **Not alive**: "Ensure you ran with `elixir --sname shem_demo -S mix demo`"
- **Phase 2 timeout (15s)**: "Horde did not relocate worker_alpha within 15s — check Horde membership"
- **Phase 4 timeout (30s)**: "Hardening job did not complete — check stub transport queue"

---

## Demo Tool

`word_count` — graduated inline in Phase 4:

```elixir
# Buggy version (round 1)
def run(%{"text" => text}) do
  words = String.split(text)   # crashes when text is nil
  {:ok, "#{length(words)} words"}
end

# Fixed version (registered by demo task after round 1 — labelled [demo])
def run(%{"text" => nil}), do: {:ok, "0 words"}
def run(%{"text" => text}), do: {:ok, "#{length(String.split(text))} words"}
```

---

## File Map

| File | Action |
|---|---|
| `lib/mix/tasks/demo.ex` | Create |
| `lib/shem/event_log.ex` | Add `scrub/2` |
| `lib/shem/event_log/store.ex` | Add `scrub/2` callback |
| `lib/shem/event_log/dets_store.ex` | Implement `scrub/2` |
| `lib/shem/event_log/mnesia_store.ex` | Implement `scrub/2` |
| `lib/shem/event_log/fake_store.ex` | Implement `scrub/2` |
| `test/shem/event_log_test.exs` | Add `scrub/2` tests |
| `lib/shem/adversarial/hardening_job.ex` | Read `adversarial_agent_placement` env for `Config.placement` |

---

## Constraints

- Requires `--sname`. Task checks `Node.alive?()` at startup and exits with a clear message if not.
- Uses `Shem.LLM.StubTransport` — no Ollama, no network calls.
- Peers require the same ebin `-pa` paths as the distributed tests.
- Stub responses are scoped to individual peer stub servers — no global push-queue.
- `HardeningJob` agents are pinned to the local node via env override.
- `MnesiaStore` is forced at startup so Phase 2 checkpoints survive node death.
- Phase 4 narration uses `[stub]` and `[demo]` labels to be honest about what is scripted vs. runtime.

---

## What This Demo Proves (Honestly)

| Capability | How demonstrated | Honest label |
|---|---|---|
| Multi-node agent mesh | Real `:peer` nodes, real Horde distribution | Real |
| Node failure + continuation | `:peer.stop/1` kills a live node; Horde relocates | Real |
| EventLog scrub | `scrub/2` deletes real events from MnesiaStore | Real |
| Timeline fork | `branch_after_call/4` creates a real divergent session | Real |
| Hardening loop (rounds, EventLog, Trust.Store) | `HardeningJob` runs real rounds | Real |
| LLM responses | StubTransport — scripted | `[stub]` |
| Target patch execution | Demo task graduates patched tool directly | `[demo]` |
