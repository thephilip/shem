# /hire Command

**Date:** 2026-06-08  
**Status:** Approved for implementation

## Overview

`/hire <name> <role description>` generates a new agent preset via a single LLM call and saves it to `PresetStore`. The user describes a role in plain English; the LLM produces a concise system prompt; the preset is immediately available to `/agent` and `spawn_agent`. No new modules needed — three small changes to existing files.

## Command Syntax

```
/hire <name> <role description>
```

Examples:
```
/hire researcher summarises academic papers and extracts key findings
/hire devops reads logs and diagnoses production incidents
/hire reviewer checks pull requests for correctness and style
```

`name` is the first whitespace-delimited token. Everything after is the role description. Both are required — empty name or empty role returns `{:error, "usage: /hire <name> <role description>"}` from `CommandDispatch` before any LLM call is made.

## Architecture & Components

### Modified files

| File | Change |
|------|--------|
| `lib/shem/tui/command_dispatch.ex` | Add `["hire", name \| role_parts]` parse clause; add `{:hire, String.t(), String.t()}` to return type spec |
| `lib/shem/tui/app.ex` | Handle `{:hire, name, role}` in `update/2` (fire Task); handle `{:hire_complete, name, result}` message; add `hire_status` field to app state |

No new modules. No changes to `PresetStore`, `LLM`, or any other module.

## LLM Generation

A single `LLM.complete/2` call — no agent loop, no tools, no streaming.

Generation prompt:
```
You are writing a system prompt for an AI agent.
Role description: "<role>"
Write a concise system prompt (2-4 sentences) that describes the agent's purpose, approach, and any constraints.
Return ONLY the system prompt text. No explanation, no preamble, no quotes.
```

The response `content` field is used directly as the preset's `system_prompt`. Generated presets always receive `tools: :all`. Users can restrict tools later with `/preset add <name>`.

## Async Flow

`/hire` cannot block `App.update/2` — that freezes the TUI render loop. Flow:

1. `update/2` receives `{:hire, name, role}`.
2. Captures `tui_pid = self()`.
3. Fires `Task.start(fn -> ... send(tui_pid, {:hire_complete, name, result}) end)`.
4. Sets `app_state.hire_status = "hiring #{name}..."` and returns immediately.
5. On `{:hire_complete, name, {:ok, system_prompt}}`:
   - `PresetStore.put(name, %{system_prompt: system_prompt, tools: :all})`
   - `hire_status = "hired: #{name}"`
6. On `{:hire_complete, name, {:error, reason}}`:
   - `hire_status = "hire failed: #{inspect(reason)}"`

`hire_status` is displayed in the TUI footer/status area alongside other status messages and cleared on the next user command.

## TUI State

Add one field to app state:

```elixir
hire_status: nil   # nil | String.t() — shown in status line
```

Clear `hire_status` to `nil` when the user submits any new command.

## Error Handling

| Case | Behaviour |
|------|-----------|
| Empty name or role | `CommandDispatch` returns `{:error, "usage: /hire <name> <role description>"}` — no LLM call |
| LLM call fails | `{:hire_complete, name, {:error, reason}}` → `hire_status: "hire failed: ..."` — no preset stored |
| Name already exists | `PresetStore.put/2` silently overwrites — `/hire` is create-or-replace |
| Budget exhausted | LLM pipeline returns `{:error, :budget_exhausted}` — treated as LLM failure above |

## Testing

**`CommandDispatch` unit tests** (in `test/shem/tui/command_dispatch_test.exs`):
- `/hire researcher summarises papers` → `{:hire, "researcher", "summarises papers"}`
- `/hire` (no name) → `{:error, "usage: /hire <name> <role description>"}`
- `/hire researcher` (no role) → `{:error, "usage: /hire <name> <role description>"}`

**Integration test** (in `test/shem/tui/app_test.exs` or similar):
- Push a stub LLM response, send `{:hire, "mypreset", "does X"}` to the TUI app (or simulate via update/2), assert `PresetStore.get("mypreset")` returns the generated prompt after the Task completes.

## What This Is Not

- **Not interactive.** `/hire` is a single command — no multiline prompt like `/preset add`. The role is on the same line.
- **Not tool-restricted.** Generated presets always get `tools: :all`. Tool restriction is a manual step.
- **Not validated.** The generated system prompt is used as-is — no correctness checking. If the LLM returns garbage, the preset contains garbage.
