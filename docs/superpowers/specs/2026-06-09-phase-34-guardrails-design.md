# Phase 34: Guardrails

**Date:** 2026-06-09
**Status:** Approved for implementation

## Overview

Two session-safety features: an instant kill keybinding that stops a running agent, and a scope fence that restricts which paths the agent can access. Together they make Shem safe to run on real work without fear of runaway behaviour.

Rollback (originally in the roadmap) is deferred — the EventLog/Branch design (Phases 2, 6a, 6b) is the right rollback mechanism, surfaced via the Timeline Viewer Fork button (Phase 32). `git reset` is not used. Travelling agent detection is deferred until after Phase 31 (Shadow Agent), which provides the confidence meter it depends on.

---

## Architecture

### New module: `Shem.Guardrails`

A pure module — no GenServer, no process. All guardrail logic lives here so that future features (travelling agent detection, etc.) have a single home.

```elixir
Shem.Guardrails.check_fence(fence, tool_name, args, opts \\ []) :: :ok | {:blocked, String.t()}
Shem.Guardrails.kill_session(session_id) :: :ok
```

`kill_session/1` is a thin wrapper over `Agent.stop/1`.

`check_fence/3` resolves the accessed path to absolute and checks it against the fence root. Returns `:ok` immediately when `fence` is `nil`. Returns `:ok` for the `shell` tool when `opts[:backend]` is `:container` (container boundary supersedes the fence for shell). `read_file` and `list_dir` check the fence regardless of backend.

### `Agent.Config` change

Add one field:

```elixir
fence: nil | String.t()   # absolute path; nil = no fence
```

Default `nil`. Resolved to absolute path at set-time (when the `/fence` command runs), not at check-time.

### Modified: `Shem.Agent.Server`

Add `set_fence/2` public API and a matching `handle_call` clause that updates `Agent.Config.fence` in the server state. This is how `/fence` applies mid-session without restarting the agent.

```elixir
Shem.Agent.set_fence(session_id, path_or_nil) :: :ok | {:error, :not_found}
```

### Modified: `Shem.Agent.ToolDispatch`

Before executing `read_file`, `list_dir`, or `shell`, call:

```elixir
Guardrails.check_fence(config.fence, tool_name, args, backend: resolved_backend())
```

On `{:blocked, reason}`, return `{:error, reason}` — the agent receives this as a tool error and can respond to it. No crash, no agent stop.

`resolved_backend/0` reads `Application.get_env(:shem, :resolved_executor_backend, Backend.Local)`. Container backend skips the fence — the container boundary is stronger than any path check.

---

## Kill

**Trigger:** `Ctrl+K` in the TUI.

**Behaviour:**
1. Calls `Guardrails.kill_session(active_session_id)` → `Agent.stop/1`
2. `Agent.Server` terminates. In-flight streaming response is cut immediately — `StreamSink` cleans up on the agent's `:EXIT`.
3. TUI status line updates to idle.
4. TUI flashes: *"Agent stopped — use `/history` to branch from a prior event."*

No confirmation prompt. Kill is instant. Nothing is lost — the EventLog has the full session audit trail.

If no agent is active when `Ctrl+K` is pressed, the keypress is a no-op.

---

## Scope Fence

### Setting and clearing

```
/fence src/auth          # restrict to src/auth (resolved to absolute at set-time)
/fence /home/user/proj   # absolute path also accepted
/fence clear             # remove fence
```

`/fence` without arguments shows the current fence (or "no fence active").

The fence applies immediately to the next tool call — including mid-conversation on an active agent. It does not require a session restart.

The active fence path is shown in the TUI status line alongside the preset name:
```
[coder] [fence: /home/user/proj/src/auth]
```

### Path matching

Both the fence root and the accessed path are resolved to absolute paths before comparison. The check is a prefix match:

```elixir
String.starts_with?(Path.expand(accessed_path), Path.expand(fence_root))
```

Symlinks in the accessed path are not followed — if an agent tries to access a symlink that points outside the fence, the symlink target is not resolved. The check operates on the literal path the agent provided. This is intentionally conservative.

Phase 34 does not implement glob patterns (`*`, `**`). Fence is a directory prefix only. Glob support can be added in a later phase if needed.

### Error returned to agent

When a tool call is blocked:

```
{:error, "blocked by scope fence: <accessed_path> is outside <fence_root>"}
```

The agent sees this as a tool error in its message history and can reason about it (e.g. ask the user to widen the fence or try a different path).

### Container backend

When `resolved_executor_backend` is `Backend.Container`, `check_fence/3` returns `:ok` for `shell` unconditionally. The container mount boundary is the fence for shell in that mode. `read_file` and `list_dir` still check the fence (they run on the host via `File.*` regardless of the executor backend).

---

## TUI changes

| Change | Detail |
|--------|--------|
| `Ctrl+K` keybinding | Calls `kill_session/1` on active agent; no-op if idle |
| `/fence` command | Set/clear/show fence; updates `Agent.Config.fence` on active agent |
| Status line | Shows `[fence: <path>]` when fence is active |
| Kill flash message | *"Agent stopped — use `/history` to branch from a prior event."* |

`CommandDispatch.commands/0` entry added for `/fence` so it appears in `/help`.

---

## Testing

**`Shem.Guardrails` unit tests** (pure, no process setup):
- Path inside fence → `:ok`
- Path outside fence → `{:blocked, _}`
- `fence: nil` → `:ok`
- Container backend → `:ok` (for shell; fence still applies to read_file/list_dir)
- Relative path accessed → expanded before check
- Symlink path → not resolved, checked literally

**`ToolDispatch` integration tests:**
- Blocked `read_file` returns `{:error, _}` tuple (not a crash)
- Blocked `list_dir` returns `{:error, _}` tuple
- Allowed `read_file` (inside fence) proceeds normally
- Shell on container backend: fence not applied

**TUI/`CommandDispatch` tests:**
- `/fence <path>` sets `Agent.Config.fence` on active agent
- `/fence clear` sets `fence: nil`
- `Ctrl+K` with active agent: agent stopped, status updates
- `Ctrl+K` with no active agent: no-op

---

## What this phase does NOT include

- Rollback (deferred to Phase 32 Timeline Viewer Fork + container workflow)
- Travelling agent detection (deferred to after Phase 31 Shadow Agent)
- Glob patterns in fence (prefix match only for Phase 34)
- REST/Web UI kill endpoint (TUI-only for Phase 34; REST `DELETE /api/agents/:id` already exists for programmatic stop)
