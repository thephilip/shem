# Agent Memory / Knowledge Base

**Date:** 2026-06-08  
**Status:** Approved for implementation

## Overview

Agents gain a persistent, cross-session key-value memory store exposed as four built-in tools. Memory is written and read explicitly via tool calls — no passive injection into the system prompt. This keeps the prompt surface clean, avoids hallucination risk from stale auto-injected facts, and follows the same explicit, traceable data-flow pattern as every other built-in.

## Architecture & Components

### New module

**`Shem.Memory.Store`** — DETS-backed GenServer. Follows the exact structure of `Shem.Trust.Store`:
- Opens `~/.config/shem/memory.dets` on `init` (path configurable via `config :shem, :memory_store_path`)
- Closes DETS table on `terminate`
- DETS open failure → `{:stop, {:dets_open_failed, reason}}` (same as `Trust.Store`)
- Started in `Shem.Application` alongside `Trust.Store`

Public API:
```elixir
Memory.Store.put(key, value)         :: :ok
Memory.Store.get(key)                :: {:ok, String.t()} | {:error, :not_found}
Memory.Store.delete(key)             :: :ok | {:error, :not_found}
Memory.Store.all(prefix \\ "")      :: [{String.t(), String.t()}]  # sorted by key
Memory.Store.flush()                 :: :ok  # test teardown
```

### Modified module

**`Shem.Agent.ToolDispatch`** — four new entries added to `@builtins`, four new `dispatch_builtin` clauses. No other changes to any existing module.

## Data Model

DETS table type `:set`. One record per key:

```
{key :: String.t(), value :: String.t(), written_at :: DateTime.t()}
```

- **Keys** are plain strings. Agents namespace by convention: `"coding/preferred_style"`, `"user/name"`, `"global/last_project"`. The store has no concept of namespaces — scoping is the agent's responsibility.
- **Values** are strings. Agents may JSON-encode structured data if needed.
- **`written_at`** is stored at no extra cost; available for future TTL or audit features without a schema migration.

## Tool Interface

Four builtins added to `@builtins` in `ToolDispatch`:

| Tool | Args | Result |
|------|------|--------|
| `remember` | `key` (string), `value` (string) | `"stored: <key>"` |
| `recall` | `key` (string) | `"<value>"` or `"no memory at key: <key>"` |
| `forget` | `key` (string) | `"forgotten: <key>"` or `"no memory at key: <key>"` |
| `list_memories` | `prefix` (string, optional, default `""`) | `"<key> = <value>\n..."` or `"no memories found"` |

All four return `{:ok, String.t()} | {:error, String.t()}` — the same contract as every other builtin. `Turn` and `Agent.Server` require no changes.

`list_memories` output is sorted by key for stable, readable results.

## Error Handling

- DETS open failure crashes the GenServer/supervisor — acceptable for a local-first tool, same as `Trust.Store`.
- `recall`/`forget` on a missing key return a descriptive string result (not an error tuple) so agents can observe the miss and react in prose.
- `Memory.Store.get/1` and `delete/1` return `{:error, :not_found}`; `dispatch_builtin` converts this to `{:ok, "no memory at key: <key>"}` so the agent sees a readable string result, not an error tuple.
- Missing `args["key"]` or `args["value"]` in `dispatch_builtin` falls through to `{:error, "remember requires key and value"}`.
- No external boundary validation needed — these are internal tool calls from the agent loop.

## Testing

**Config:**
```elixir
# test.exs
config :shem, memory_store_path: "tmp/test_memory.dets"
```

**Setup:** each test touching memory calls `Memory.Store.flush()` in `setup`, consistent with `Trust.Store` and `PresetStore` test patterns.

**Coverage:**
- `Memory.Store` unit tests: `put/get/delete/all` with DETS, including `all/1` prefix filter and `written_at` field presence.
- `ToolDispatch` tests: all four builtins exercised via `execute/2` — happy path and missing-key cases. Follows existing builtin test structure.
- No integration tests needed; `Agent.Server` and `Turn` are unmodified.

## What This Is Not

- **Not a vector store.** No semantic search. Agents name keys intentionally.
- **Not injected into prompts.** No session-start digest, no system prompt mutation. Memory is always explicit.
- **Not scoped by agent identity.** The store is global; agents manage their own namespace via key conventions.
- **Not a replacement for EventLog.** EventLog records reasoning history; Memory stores durable facts agents choose to keep.
