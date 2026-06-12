# Phase 37 — Honest Claims

## Why this phase exists

Three claims in `agent-framework.md` are written as if true but aren't (identified in the
2026-06-12 roadmap-v2 review):

1. **Pause-and-steer** (§3B): the manifest promises Spacebar pauses agent execution for
   mid-flight steering. What exists is a TUI display flag — agents keep running.
2. **Formal graduation gate** (§2A): the manifest requires property-based proofs. The actual
   gate runs whatever example test the agent wrote about itself.
3. **Cryptographic audit trail** (§4): events have causal `parent_id` links but no hash
   chain. The enterprise compliance story is aspirational.

This phase makes all three true before Phase 38 publishes them. Each section is
independently shippable.

Decisions made with the user (2026-06-12): pause scope = **focused agent only**;
property gate = **soft, seed trust :medium**; verify surface = **library + REST endpoint**.

---

## 1. Pause-and-Steer (focused agent)

### Server side

`Agent.Server` gains a `:paused` status. The ReAct loop already has the seam:
`handle_info(:run_turn, %{status: s} = state) when s != :running` silently drops the
message. Pause is therefore a status flip; any in-flight turn completes naturally and
pause takes effect at the next turn boundary (worst case one extra turn runs if a
`:run_turn` was already queued ahead of the pause call — acceptable and documented).

New public API on `Shem.Agent`:

| Function | Valid from | Effect |
|---|---|---|
| `pause(name)` | `:running` | status → `:paused`; `:agent_paused` event. Other statuses → `{:error, :not_running}` |
| `steer(name, text)` | `:paused` | appends `%{role: :user, content: text}` to history; `:agent_steered` event (payload `%{content: text}`). Other statuses → `{:error, :not_paused}` |
| `unpause(name)` | `:paused` | status → `:running`; `:agent_unpaused` event; `send(self(), :run_turn)`. The drop-guard guarantees no double-turn. Other statuses → `{:error, :not_paused}` |

Event names are distinct from the existing `:agent_resumed` (session resume).

Consequence, documented not "fixed": `await`/`await_result`/`spawn_agent` callers keep
blocking while an agent is paused; their timeouts can fire. Correct behavior.

`Agent.status/1` can now return `:paused`; downstream status consumers (TUI agent list,
MCP `agent_status`, REST) render it as a string like the others.

### TUI side

- SPACE (empty buffer, focused agent set) toggles: focused agent `:running` → `pause`;
  `:paused` → `unpause`. No focused agent → no-op.
- The display-only `model.paused` flag is **removed**. The PAUSED status bar / prompt
  states derive from the focused agent's real status (`:paused`).
- While the focused agent is paused, typing text + Enter sends a **steering** message
  (`Agent.steer/2`) instead of starting/continuing a conversation.
- The old Esc-sets-paused clause is removed (Esc in normal mode becomes a no-op).
- Agent list panel renders `:paused` with its own dot/color (`⏸`, yellow).

---

## 2. Property-Gated Graduation

- `stream_data` promoted from `only: :test` to a runtime dependency (pure Elixir, small).
- Tool test modules are plain `run/0` modules (not ExUnit), so property presence is a
  source scan: `test_source =~ ~r/check_all|StreamData\./`. The heuristic is acceptable
  because the property must also **pass** inside the gate — that is the substantive check.
- `GraduationGate.run/3` behavior after tests pass:
  - **Property present** → unchanged (tool starts `:unrated`).
  - **Property absent** → tool still graduates, but
    `Trust.Store.record(tool.id, %{outcome: :no_property_tests, rounds: 0})` seeds the
    score at **0.5** (`:medium` band) — usable immediately, visibly penalized, and
    adversarial hardening moves it from there. New outcome atom in the Trust.Store score
    formula: `:no_property_tests → 0.5`.
- `Tool.metadata` gains `property_tested: boolean`.
- MCP `graduate_tool` descriptor text updated: properties encouraged, consequence stated.

---

## 3. Hash-Chained EventLog

### Chain construction (at append time, per session)

- `Event` struct gains `hash: String.t() | nil` (nil on all legacy events — no migration).
- Genesis: `prev = sha256(session_id)`.
- Each event: `hash = sha256(prev <> :erlang.term_to_binary({id, session_id, type, payload, DateTime.to_iso8601(timestamp)}))`, hex-encoded.
- The EventLog GenServer tracks `last_hash` per active session. Reopening an existing
  session seeds `last_hash` from the last stored event's hash, or genesis if the last
  event is legacy (nil hash).

### Verification

`EventLog.verify_chain(session_id)` returns:

- `{:ok, :verified, n}` — all n events hash-chain correctly (mixed sessions verify from
  the first hashed event; the legacy prefix is tolerated)
- `{:ok, :legacy, n}` — no event has a hash (pre-Phase-37 session)
- `{:error, {:broken_at, event_id}}` — first event whose hash does not match recomputation
- `{:error, :not_found}` — unknown session

### Fork semantics (deliberate simplification)

Timeline-forked sessions (Branch) copy events with hashes **stripped**: the fork reads as
`:legacy` until its own appends start a fresh chain. Re-hashing copied history would
falsely attest events the fork did not witness.

### Surface

`GET /api/sessions/:id/verify` →
- `200 {"verified": true, "events": n}`
- `200 {"verified": false, "broken_at": "evt_..."}`
- `200 {"verified": "legacy", "events": n}`
- `404` unknown session

---

## What is NOT in scope

- Global pause-all (`/pauseall`) — focused-agent pause only
- Hard property requirement (refusing graduation) — soft gate per user decision
- TUI verified-badge for sessions — Phase 38 can add it on top of the REST endpoint
- Budget circuit-breaker rework (manifest §3C) — separate concern, later phase
- Re-hashing on fork — see fork semantics above

## Success criteria

- SPACE pauses the focused agent (its turns stop), typed input steers it, SPACE resumes
  it with the steering applied — observable in the EventLog as
  `:agent_paused → :agent_steered → :agent_unpaused`
- A tool graduated without a property test lands at trust `:medium` and shows so in
  `/tools`; one with a passing property starts `:unrated` as today
- `EventLog.verify_chain/1` returns `:verified` for new sessions, `:legacy` for old ones,
  and detects a tampered payload with `{:broken_at, ...}`
- `GET /api/sessions/:id/verify` exposes the same over REST
- Full suite green; no new compile warnings
