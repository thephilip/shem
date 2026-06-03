# Event Log Engine — Phase 2 Design

**Date:** 2026-06-03
**Phase:** 2 of Shem
**Status:** Approved

---

## Goal

Build the append-only Event Log Engine: durable per-session event storage with causal linking, a swappable storage abstraction, and fold-based state reconstruction. This is the foundational audit and replay infrastructure that all future agent activity writes into.

---

## Scope

**In scope:**
- Event struct with causality (`parent_id`, `session_id`)
- `Store` behaviour for swappable backends
- `DETSStore` — DETS-backed implementation, one file per session
- `Shem.EventLog` GenServer — public API, serialized writes, session lifecycle
- `Shem.EventLog.Replay` — pure fold-based state reconstruction and causal chain extraction
- Lab directory scaffolding (`~/.config/shem/lab/events/`)
- Dashboard TUI update: live session/event count via `EventLog.stats/0`

**Out of scope (future phases):**
- Live re-execution replay (mocking LLM calls from log)
- Timeline fork / branching
- Mnesia backend
- Cryptographic hash chaining (Glass Box audit trail)
- TUI Timeline Mode (scrubbing/visualization)

---

## Architecture

Six modules, each with one responsibility:

```
lib/shem/event_log.ex               GenServer — public API, session lifecycle, serialized writes
lib/shem/event_log/event.ex         Event struct and ID generation
lib/shem/event_log/session.ex       Session struct and ID generation
lib/shem/event_log/store.ex         Store behaviour (swappable backend interface)
lib/shem/event_log/dets_store.ex    DETS implementation of Store
lib/shem/event_log/replay.ex        Pure fold-based reconstruction and causal chain
```

The `Shem.EventLog` GenServer is the only entry point for all callers. No module outside `event_log/` touches the Store directly.

---

## Event Schema

```elixir
defmodule Shem.EventLog.Event do
  @type t :: %__MODULE__{
    id:         String.t(),       # "evt_" <> 16-char hex
    session_id: String.t(),       # "ses_" <> 16-char hex
    parent_id:  String.t() | nil, # causal link to triggering event
    type:       atom(),           # :llm_call | :tool_invoked | :state_changed | etc.
    payload:    map(),            # type-specific data, unvalidated at this layer
    timestamp:  DateTime.t()
  }
end
```

IDs are generated as `"evt_" <> Base.encode16(:crypto.strong_rand_bytes(8))`. Sessions use `"ses_"` prefix with the same generation. `payload` is intentionally untyped — the log layer does not need to understand event contents, only record them. Type-specific validation belongs in the agents that emit events.

---

## Session Schema

```elixir
defmodule Shem.EventLog.Session do
  @type t :: %__MODULE__{
    id:          String.t(),    # "ses_" <> 16-char hex
    started_at:  DateTime.t(),
    ended_at:    DateTime.t() | nil,
    event_count: non_neg_integer()
  }
end
```

---

## Store Behaviour

```elixir
defmodule Shem.EventLog.Store do
  @callback open(session_id :: String.t(), path :: Path.t()) ::
              {:ok, handle :: term()} | {:error, term()}

  @callback append(handle :: term(), event :: Event.t()) ::
              :ok | {:error, term()}

  @callback read_all(handle :: term()) ::
              {:ok, [Event.t()]} | {:error, term()}

  @callback get(handle :: term(), event_id :: String.t()) ::
              {:ok, Event.t()} | {:error, :not_found}

  @callback close(handle :: term()) :: :ok
end
```

`handle` is an opaque term owned by the backend. `DETSStore` uses a DETS table name (atom). Swapping to Mnesia in Phase 5 requires only a new module implementing this behaviour — no callers change.

---

## DETSStore

- Storage path: `~/.config/shem/lab/events/<session_id>.dets`
- The lab directory is created on first `open/2` call if it doesn't exist
- DETS table type: `:set`, keyed on `event_id`
- Events are stored as native Erlang terms (no serialization overhead)
- `read_all/1` returns events ordered by insertion via `:dets.traverse/2`
- Handle is the DETS table name, derived from session ID as `:"shem_events_<session_id>"`

---

## Public API (`Shem.EventLog` GenServer)

```elixir
# Session lifecycle
start_session()                                          → {:ok, session_id}
end_session(session_id)                                  → :ok
list_sessions()                                          → {:ok, [%Session{}]}
stats()                                                  → %{sessions: n, total_events: n}

# Writing (serialized through GenServer)
append(session_id, type, payload)                        → {:ok, %Event{}}
append(session_id, type, payload, parent_id)             → {:ok, %Event{}}

# Reading
events(session_id)                                       → {:ok, [%Event{}]}
event(session_id, event_id)                              → {:ok, %Event{}} | {:error, :not_found}

# Replay
reconstruct(session_id, reducer, initial_state)          → {:ok, state}
reconstruct_at(session_id, event_id, reducer, initial)   → {:ok, state} | {:error, :event_not_found}
```

**GenServer state:**

```elixir
%{
  sessions: %{session_id => {handle, %Session{}}},
  store: module()   # DETSStore by default, injectable for testing
}
```

The `store` module is configurable via `Application.get_env(:shem, :event_log_store, Shem.EventLog.DETSStore)` — tests inject a lightweight in-memory fake.

---

## Replay Module

Pure functions, no processes:

```elixir
# Fold all events through a reducer — reducer is (state, event) → state
Replay.fold(events, initial_state, reducer)
→ final_state

# Reconstruct state at a specific event ID (fold stops after that event)
Replay.state_at(events, event_id, initial_state, reducer)
→ {:ok, state} | {:error, :event_not_found}

# Extract causal chain — all ancestors of event_id, in causal order
Replay.causal_chain(events, event_id)
→ [%Event{}]
```

`causal_chain/2` walks `parent_id` links backward from the target event to the root, then reverses. This is the primitive for Phase 4 fork: take a causal chain, replay it with a mutation at step N, diverge from there.

The reducer signature `(state, event) → state` is identical to `Enum.reduce/3`. Callers own the shape of `state` entirely — the Replay module imposes no constraints on it.

---

## TUI Integration

`Dashboard.render/1` gains a live event count via `Shem.EventLog.stats/0`:

- "Active loops: 0" → "Sessions: N  Events: N"
- Called on each render tick — `stats/0` is a GenServer call returning a small map, negligible overhead

---

## Storage Layout

```
~/.config/shem/
└── lab/
    └── events/
        ├── ses_<id1>.dets
        ├── ses_<id2>.dets
        └── ...
```

---

## Testing Strategy

- `DETSStore` tests use a temp directory (`:os.cmd('mktemp -d')` or `System.tmp_dir!/0`), cleaned up in `on_exit`
- `Shem.EventLog` GenServer tests inject a `Shem.EventLog.FakeStore` (ETS-backed, in-memory) via `Application.put_env` in test setup — no disk I/O in unit tests
- `Replay` tests are pure — just lists of `%Event{}` structs, no process or storage involvement
- All event log tests run `async: false` where they touch the GenServer (shared process), `async: true` for pure Replay tests

---

## Forward Compatibility Notes

`causal_chain/2` and `reconstruct_at/4` are the two primitives Phase 4 (fork) will build on. The event schema's `parent_id` field is load-bearing — every event emitted by Phase 3 agents must set it correctly for the causal chain to be walkable.
