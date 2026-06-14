# Launch Demo Design
_2026-06-14_

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

Peer nodes are started with `:peer` (identical pattern to the distributed tests). The stub transport's `push_response/2` queue is loaded with the full scripted response sequence at task startup, before any agent runs.

---

## New Code Required

### `EventLog.scrub/2`

Deletes all events in a session written after a given event ID. Required for Phase 3.

Add to 4 files:

| File | Change |
|---|---|
| `lib/shem/event_log.ex` | `def scrub(session_id, after_event_id)` public API + GenServer call |
| `lib/shem/event_log/store.ex` | `@callback scrub(session_id, after_event_id)` |
| `lib/shem/event_log/dets_store.ex` | Implementation using `:dets.select_delete` |
| `lib/shem/event_log/mnesia_store.ex` | Implementation using `:mnesia.transaction` + `match_object`/`delete` |
| `lib/shem/event_log/fake_store.ex` | Implementation filtering the in-memory list |

Unit tests for `scrub/2` go in `test/shem/event_log_test.exs` alongside existing tests.

### `lib/mix/tasks/demo.ex`

The demo task (~250 lines). Contains:
- `@shortdoc` and `@moduledoc` for `mix help demo`
- `run/1` entry point
- Private helpers per phase: `phase_1/1`, `phase_2/1`, `phase_3/1`, `phase_4/1`
- ANSI narration helpers: `banner/1`, `step/1`, `ok/1`, `info/1`
- `start_peer/1` — wraps `:peer.start` with `-pa` args (identical to distributed test helper)
- `assert_eventually/3` — polls a condition with timeout (copy from distributed tests)
- Inline `DemoTool` module definition for the buggy `word_count` tool

---

## Scripted Stub Sequence

Loaded into `StubTransport.Server` via `push_response/2` at task start:

| # | Consumer | Content |
|---|---|---|
| 1 | `worker_alpha` turn 1 | `"Scanning task boundaries…"` |
| 2 | `worker_alpha` turn 2 | `"Checkpoint written. Awaiting next instruction."` |
| 3 | `worker_beta` turn 1 | `"Parallel analysis running on shem_c…"` |
| 4 | `worker_alpha` resume | `"Recovered from checkpoint. Completing task."` |
| 5 | red-team round 1 | `"FAILURES_FOUND: crashes on empty string input"` |
| 6 | target agent | *(handled by `write_tool` call — content not parsed)* |
| 7 | red-team round 2 | `"NO_FAILURES_FOUND"` |
| default | any remaining | `"Task complete."` |

The stub transport pops responses in order; the default fires for any call after the queue is exhausted.

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
```

Steps:
1. `start_peer(:shem_b)` and `start_peer(:shem_c)` — start two `:peer` nodes with full ebin `-pa` args
2. `Horde.Cluster.set_members/2` for `AgentSupervisor` and `Registry` across all 3 nodes
3. Poll until both peers appear in Horde membership
4. Spawn `worker_alpha` with `placement: {:node, peer_b}`, `max_turns: 2`, stub transport configured
5. Spawn `worker_beta` with `placement: :any`, `max_turns: 1`
6. `Agent.await/2` on both; narrate node of each pid

### Phase 2 — Node Failure + Recovery

```
▶ PHASE 2: NODE FAILURE + RECOVERY
  Killing shem_b@localhost mid-task...
  :nodedown received. Horde marking shem_b dead...
  Waiting for worker_alpha to relocate...  ✓  (relocated to localhost in 1.2s)
  worker_alpha resumed: "Recovered from checkpoint. Completing task."
  ✓ Work continued without interruption.
```

Steps:
1. Start a fresh `worker_alpha` (1 turn completed, 1 pending) on `peer_b`
2. `:peer.stop(peer_b)` — kills the node
3. `assert_eventually` polls until `node(pid)` for `worker_alpha` is no longer `peer_b` (timeout 15s)
4. `Agent.await/2` on the relocated agent
5. Print elapsed time for relocation

### Phase 3 — Time-Travel (Scrub + Fork)

```
▶ PHASE 3: TIME-TRAVEL
  EventLog for worker_alpha: 7 events (2 dirty tail events after crash)
  Scrubbing dirty tail after event evt_...  ✓  (5 events remain)
  Forking timeline from turn 1 checkpoint...
  Fork session: ses_...
  Original: 5 events | Fork: 3 events (diverged at turn 1)
  ✓ Timeline forked. Two parallel histories now exist.
```

Steps:
1. `EventLog.events(session_id)` — list all events, identify the last `agent_checkpoint` event ID
2. `EventLog.scrub(session_id, checkpoint_event_id)` — delete dirty tail
3. Print before/after event counts
4. `Shem.LLM.Branch.branch_after_call(session_id, 0, [%{content: "Taking the alternate path…", tokens_used: 5}], fn fork_sid -> fork_sid end)`
5. Print both session IDs and their event counts

### Phase 4 — Adversarial Hardening

```
▶ PHASE 4: ADVERSARIAL HARDENING
  Graduating demo tool: word_count (with known bug)...  ✓
  Starting hardening job...
  Round 1 — red-team agent scanning word_count...
    → FAILURES_FOUND: crashes on empty string input
  Round 1 — target agent patching word_count...
    → write_tool called, new version graduated
  Round 2 — red-team agent verifying fix...
    → NO_FAILURES_FOUND
  Trust score: 1.0 (clean)
  ✓ Property tests prove correctness. Tool is trusted.

═══════════════════════════════════════════════════════════════
  SHEM LAUNCH DEMO COMPLETE
  Distributed mesh ✓  Node recovery ✓  Time-travel ✓  Self-healing ✓
═══════════════════════════════════════════════════════════════
```

Steps:
1. Define `word_count` tool inline with a deliberate bug: `String.split(text)` crashes when `text` is `nil`
2. `Lab.Registry.register(tool)` and `Lab.Workspace.graduate(tool)`
3. `Shem.Adversarial.start_hardening(tool_id)` — returns job name
4. `HardeningJob.await(pid, 30_000)` — polls until `status: :done`
5. `Shem.Trust.Store.get(tool_id)` — print outcome and score
6. Final banner

---

## Error Handling

Each phase is wrapped in `try/rescue`. On failure:

```
✗ PHASE N FAILED: <reason>
  Hint: <context-specific hint>
```

Then `System.halt(1)`.

Specific cases:
- **Peer startup fails**: "Ensure you ran with `elixir --sname shem_demo -S mix demo`"
- **Phase 2 timeout (15s)**: "Horde did not relocate worker_alpha within 15s — check Horde membership wiring"
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

# Fixed version (written by target agent via write_tool stub)
def run(%{"text" => nil}), do: {:ok, "0 words"}
def run(%{"text" => text}) do
  {:ok, "#{length(String.split(text))} words"}
end
```

The stub transport's response for the target agent does not need to contain the patched source literally — `write_tool` is called by the agent as a tool call, and the demo pre-registers the patched version directly after the target agent completes (the stub response signals completion; the demo task does the actual graduation).

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

---

## Constraints

- Requires `--sname` (Erlang distribution). The task checks `Node.alive?()` at startup and exits with a clear message if not.
- Uses `Shem.LLM.StubTransport` — no Ollama, no network.
- Peers require the same ebin `-pa` paths as the distributed tests.
- `HardeningJob` uses the global `StubTransport.Server`; no separate server needed per peer since the demo is single-orchestrator.
