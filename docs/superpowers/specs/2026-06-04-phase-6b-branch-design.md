# Phase 6b: Timeline Branching Design

**Date:** 2026-06-04
**Status:** Approved
**Scope:** Fork an existing session at any point, inject synthetic alternative LLM responses, run agent code, and compare outcomes across branches — zero marginal LLM cost.

---

## 1. Context and Goals

Phase 6a delivered deterministic full-session replay: given a recorded session, re-run agent code against the exact same LLM responses. Phase 6b extends this into branching: fork from a midpoint, replace responses after the fork with synthetic alternatives, and run the agent forward to see how it behaves under different conditions.

**Primary use cases:**

- **Regression hardening** — given a golden session, test agent behaviour against N synthetic response variations to surface fragile assumptions without paying LLM costs.
- **Debugging** — given a session where the agent went wrong, inject alternative responses at the failure point to explore recovery paths.

Both use cases share the same primitive. A regression harness is `Enum.map(alternatives, &Branch.branch_at(..., &1, agent_fn))`.

**What Phase 6b adds:**
- `Shem.LLM.Replay.Utils` — shared pipeline mechanics extracted from `Shem.LLM.Replay`
- `Shem.LLM.Branch` — `branch_at/4`, `branch_after_call/4`, `compare/2`
- `Replay` refactored to delegate to `Utils` (API and behaviour unchanged)

---

## 2. Architecture

```
Shem.LLM.Replay.Utils  — shared: run_with_pipeline/2, extract_llm_pairs/1, build_queue_from_pairs/1
Shem.LLM.Replay        — full-session replay; delegates to Utils; API unchanged
Shem.LLM.Branch        — branch_at/4, branch_after_call/4, compare/2
Shem.LLM.ReplayTransport        — unchanged
Shem.LLM.ReplayTransport.Server — unchanged
```

`ReplayTransport` and `ReplayTransport.Server` require no changes — they already serve an ordered queue without caring whether entries come from a recording or a caller. The pipeline swap mechanism (`Process.put(:shem_replay_pipeline, ...)`) is also unchanged.

**The core insight:** a branch is a replay where the queue is split — prefix entries come from the original session up to the fork point, alternative entries come from the caller. `ReplayTransport.Server` loads the concatenated queue.

```
branch_at("ses_original", "evt_ABC", alt_queue, fun)
    │
    ├── prefix queue  = recorded responses for calls before fork event
    ├── suffix queue  = alt_queue (caller-supplied, optionally labelled)
    └── full queue    = prefix ++ suffix  →  loaded into ReplayTransport.Server
```

---

## 3. Components

### 3.1 `Shem.LLM.Replay.Utils`

Private module (not in public API). Promotes three functions currently private in `Shem.LLM.Replay`:

- **`run_with_pipeline/2`** — `(queue, fun/1) → {:ok, session_id, result}`. Handles the full GenServer/pipeline/try-after lifecycle. Both `Replay.with_replay/2` and `Branch.branch_at/4` delegate to this.
- **`extract_llm_pairs/1`** — `(events) → [{started_event, completed_or_failed_event}]`. Pairs `:llm_call_started` with the next `:llm_call_completed` or `:llm_call_failed` in log order.
- **`build_queue_from_pairs/1`** — `(pairs) → [queue_entry]`. Maps event pairs to `%{prompt, content, tokens_used}` or `%{prompt, error}` entries.

`Replay.with_replay/2` is refactored to call these three functions in sequence. Public API and behaviour are unchanged.

### 3.2 `Shem.LLM.Branch`

```elixir
@type alt_entry ::
        %{content: String.t(), tokens_used: non_neg_integer()}
        | %{content: String.t(), tokens_used: non_neg_integer(), label: String.t()}
        | %{error: String.t()}

@spec branch_at(String.t(), String.t(), [alt_entry()], (String.t() -> result)) ::
        {:ok, String.t(), result} | {:error, term()}
      when result: term()

@spec branch_after_call(String.t(), non_neg_integer(), [alt_entry()], (String.t() -> result)) ::
        {:ok, String.t(), result} | {:error, term()}
      when result: term()

@spec compare([{String.t(), String.t()}]) :: [diff_entry()] | {:error, term()}

@type diff_entry :: %{
        call_index: non_neg_integer(),
        type: :identical | :content_differs,
        branches: [%{label: String.t(), content: String.t() | nil, prompt: String.t()}]
      }
```

**`branch_at/4` steps:**
1. Read events from `original_session_id` — error if not found or no LLM events
2. Find the fork event by `event_id` — `{:error, :fork_event_not_found}` if missing
3. Extract LLM pairs; split into prefix (pairs whose `:llm_call_started` precedes fork event) and discard remainder
4. Build prefix queue via `Replay.Utils.build_queue_from_pairs/1`
5. Concatenate: `full_queue = prefix_queue ++ alt_queue`
6. Delegate to `Replay.Utils.run_with_pipeline(full_queue, fun)`

**`branch_after_call/4`:**
Resolves call index N to the event ID of the Nth `:llm_call_completed` event, then delegates to `branch_at/4`. Returns `{:error, :call_index_out_of_range}` if N ≥ total recorded calls.

**`compare/2`:**
Takes `[{label, session_id}]` — one per branch. Reads each session's event log, extracts LLM call summaries (prompt + content per call index), aligns across all branches. Returns a diff entry per call index:

- `type: :identical` — all branches produced the same prompt at this call index
- `type: :content_differs` — at least one branch differs; lists all branches with their label, prompt, and content

`compare/2` is a pure read over recorded event logs — no pipeline, no GenServer, no side effects.

---

## 4. Data Flow

**`branch_after_call/4` trace:**

```
original session "ses_A":
  evt_001  :llm_call_started   prompt: "what tools do you have?"
  evt_002  :llm_call_completed content: "I have search and calculator"
  evt_003  :llm_call_started   prompt: "use search for X"
  evt_004  :llm_call_completed content: "search result: ..."
  evt_005  :llm_call_started   prompt: "summarise"
  evt_006  :llm_call_completed content: "summary: ..."

Branch.branch_after_call("ses_A", 1, [%{content: "I only have calculator", tokens_used: 5}], fun)
    │
    ├── resolve call index 1 → fork event = evt_004
    ├── prefix pairs: [{evt_001, evt_002}]
    ├── prefix queue: [%{prompt: "what tools...", content: "I have search...", tokens_used: N}]
    ├── alt queue:    [%{content: "I only have calculator", tokens_used: 5}]
    ├── full queue:   prefix ++ alt  (2 entries)
    └── fun.("ses_branch_1")
          call 0 → served from prefix → "I have search and calculator"
          call 1 → served from alt    → "I only have calculator"
          call 2 → :replay_exhausted
```

**`compare/2` trace:**

```elixir
{:ok, sid_a, _} = Branch.branch_after_call("ses_A", 1, [%{content: "tool A", label: "A"}], agent)
{:ok, sid_b, _} = Branch.branch_after_call("ses_A", 1, [%{content: "tool B", label: "B"}], agent)
{:ok, sid_c, _} = Branch.branch_after_call("ses_A", 1, [%{content: "tool C", label: "C"}], agent)

Branch.compare([{"A", sid_a}, {"B", sid_b}, {"C", sid_c}])
# =>
[
  %{call_index: 0, type: :identical,
    branches: [
      %{label: "A", prompt: "what tools do you have?", content: "I have search and calculator"},
      %{label: "B", prompt: "what tools do you have?", content: "I have search and calculator"},
      %{label: "C", prompt: "what tools do you have?", content: "I have search and calculator"}
    ]},
  %{call_index: 1, type: :content_differs,
    branches: [
      %{label: "A", prompt: "use search for X", content: "tool A"},
      %{label: "B", prompt: "use search for X", content: "tool B"},
      %{label: "C", prompt: "use search for X", content: "tool C"}
    ]}
]
```

---

## 5. Error Handling

| Condition | Behaviour |
|---|---|
| `original_session_id` not found | `{:error, :session_not_found}` — no branch session created |
| Original session has no LLM events | `{:error, :no_llm_events}` |
| `fork_event_id` not found in session | `{:error, :fork_event_not_found}` |
| Fork event precedes all LLM calls | Prefix queue is empty; alt queue is the entire queue. Valid — not an error. |
| Call index out of range in `branch_after_call` | `{:error, :call_index_out_of_range}` |
| Alt queue exhausted during branch run | `:replay_exhausted` event appended; `{:error, :replay_exhausted}` returned from that LLM call |
| `fun` raises | `try/after` cleans up process dict and stops server; exception re-raised; branch session preserved |
| `compare/2` with unknown session ID | `{:error, :session_not_found}` propagated from EventLog |

**Fork event before all LLM calls is valid.** Passing an event that precedes the first LLM call yields an empty prefix — equivalent to a fully synthetic run from scratch using only the alt queue. This is a deliberate feature, not an edge case.

---

## 6. New Event Types

No new event types. Branch sessions reuse the existing event vocabulary:
- `:llm_call_started`, `:llm_call_completed`, `:llm_call_failed` — recorded by `EventLogger` as normal
- `:llm_call_diverged` — appended by `ReplayTransport` when prompt differs from recorded (prefix calls only; alt calls have no recorded prompt to compare against)
- `:replay_exhausted` — appended by `ReplayTransport` when queue runs out

A new session-level metadata event is added to mark branch provenance:

| Type | Appended by | Payload |
|---|---|---|
| `:branch_created` | `Branch.branch_at/4` | `%{original_session_id, fork_event_id, alt_count}` |

This event is appended to the branch session immediately after `EventLog.start_session()`. It makes branch sessions self-describing and queryable — you can find all branches of a session without external bookkeeping.

---

## 7. Testing

**`Shem.LLM.Replay`** — existing 12 tests pass unchanged. No new tests; `Utils` extraction is covered implicitly.

**`Shem.LLM.Branch`** (`async: false`, ~18 new tests in `test/shem/llm/branch_test.exs`):

*`branch_at/4`:*
- Happy path: prefix served from recording, alt served from caller queue
- Fork at first event: empty prefix, full alt queue
- Fork at last LLM event: full prefix, single alt entry
- `fun` receives a fresh session ID distinct from original
- Branch session contains `:branch_created` event with correct provenance
- Process dict cleaned up after normal call
- Process dict cleaned up when `fun` raises
- `{:error, :session_not_found}` for unknown original
- `{:error, :no_llm_events}` for session with no LLM calls
- `{:error, :fork_event_not_found}` for unknown event ID

*`branch_after_call/4`:*
- Resolves call index 0 (fork after first call)
- Resolves call index N-1 (fork after last call)
- `{:error, :call_index_out_of_range}` when index ≥ total calls
- Delegates correctly to `branch_at/4` (verified via branch session contents)

*`Branch.compare/2`:*
- Single branch, all calls identical → all entries `type: :identical`
- Two branches, one diverges at call 1 → diff entry at call 1, identical at call 0
- Three branches, all differ at alt call → all listed under `branches:`
- Branch with fewer calls → shorter branch produces `nil` content in diff
- Unknown session ID → `{:error, :session_not_found}`

**Full suite target:** 247 → ~265 passing.

---

## 8. Out of Scope (Phase 6b)

- Fork + continue live (real LLM calls after the fork point) — Phase 6c or later
- TUI branch visualiser / scrubber
- Partial replay starting from event N (not session start) within `with_replay/2`
- Cross-session diff beyond `compare/2` (e.g. diff of more than N branches)
- Replay of non-LLM events (tool calls, state mutations)
- Persistent branch trees / branch registries
