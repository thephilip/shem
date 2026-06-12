# Phase 35 — TUI: Make It Real

## Why this phase exists

Hermes Agent leads with its TUI as a flagship feature: multiline editing, slash-command
autocomplete, streaming output, live agent status. Shem's TUI was built in Phase 1 as a
skeleton and never filled in — the dashboard shows hardcoded zeroes and placeholder strings.
This phase closes that gap. All the underlying data exists (EventLog, AgentSupervisor,
Trust.Store, StreamRegistry); it just isn't wired to the display.

The goal is not to match every Hermes feature — it's to make Shem's TUI something you'd
actually want to use instead of the web UI.

---

## What changes

### Dashboard — live data

Replace all hardcoded placeholder labels with live values polled on `:tick`:

| Label (current) | Live source |
|---|---|
| `"Agents: 0 active"` | `Horde.DynamicSupervisor.which_children(Shem.AgentSupervisor)` count |
| `"CPU: --   MEM: --   GPU: --"` | `:cpu_sup` / `:memsup` from `os_mon`; GPU optional/omitted if unavailable |
| `"$0.0000 session / $0.0000 lifetime"` | `LLM.BudgetServer` session + lifetime spend |
| `"MCP: localhost:4000 — 0 connected"` | Use configured `mcp_host`; `MCP.SessionRegistry` count |

### Agent panel — streaming output

The interactive view already has a streaming buffer (`AgentView.streaming_buffer`) wired to
`StreamSink`. What's missing is a proper agent list panel showing all running agents, their
status, and the active agent's streaming output in real time.

- Left column: list of active agents (name, status dot, turn count)
- Right column: streaming output of the focused agent
- Arrow keys to switch focus; `Ctrl+K` to kill (already implemented in Phase 34)

### Slash-command autocomplete

On `/` keypress, show an inline overlay listing available commands with one-line descriptions.
Arrow keys to navigate, Tab/Enter to complete. Commands already defined in
`CommandDispatch.commands/0` — this is purely a render addition.

### Multiline input

Replace the single-line input buffer with a multiline editor. `Enter` submits; `Shift+Enter`
inserts a newline. Required to send multi-paragraph prompts without workarounds.

### Session history in the history view

`TUI.Views.History` exists but the detail pane shows raw event structs. Replace with a
human-readable conversation replay: user messages and agent responses rendered as a chat
transcript, with tool calls collapsed to a one-line summary.

---

## What does NOT change

- The Ratatouille runtime supervisor and app loop — no architectural changes
- The `ex_termbox` waf patch — leave it alone
- Web UI — separate concern, not touched here

---

## Files likely touched

- `lib/shem/tui/views/dashboard.ex` — live data wiring
- `lib/shem/tui/app.ex` — model fields for agent list, autocomplete state, multiline buffer
- `lib/shem/tui/views/interactive.ex` — multiline input, autocomplete overlay, agent list panel
- `lib/shem/tui/views/history.ex` — conversation replay rendering
- `lib/shem/tui/command_dispatch.ex` — expose `commands/0` for autocomplete (may already exist)

---

## Success criteria

- Dashboard shows live agent count, spend, and MCP connection count — no hardcoded values
- Typing `/` shows an autocomplete overlay; Tab completes
- Shift+Enter inserts newlines in the input buffer
- Running agents are listed with status; focused agent's output streams in real time
- History view shows a readable conversation transcript, not raw structs
