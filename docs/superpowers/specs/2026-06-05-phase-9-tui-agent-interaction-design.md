# Phase 9: TUI Agent Interaction — Design Spec

**Date:** 2026-06-05
**Status:** Approved

---

## 1. Overview

Phase 9 makes Shem usable as a daily driver. An agent can be started directly from the TUI, its progress is visible turn-by-turn via EventLog polling, and it has enough built-in tools (`read_file`, `write_file`, `list_dir`, `shell`) to do real work on a codebase. Named presets defined in Elixir config give agents personality and tool scoping with zero boilerplate.

---

## 2. New Modules

### `Shem.TUI.CommandDispatch`

Pure module. Parses the TUI command buffer on Enter and returns a tagged action tuple.

```elixir
CommandDispatch.parse("/agent coding fix the bug") → {:start_agent, "coding", "fix the bug"}
CommandDispatch.parse("fix the bug in foo.ex")     → {:start_agent, "general", "fix the bug in foo.ex"}
CommandDispatch.parse("/stop")                     → {:stop_agent}
CommandDispatch.parse("/agents")                   → {:list_agents}
CommandDispatch.parse("/unknown")                  → {:error, "unknown command: /unknown"}
```

Rules:
- Input not starting with `/` → `{:start_agent, "general", input}`
- `/agent <preset> <task>` → `{:start_agent, preset, task}`
- `/stop` → `{:stop_agent}` (acts on `focused_agent`)
- `/agents` → `{:list_agents}`
- Any other `/` command → `{:error, reason}`

### `Shem.TUI.AgentView`

Pure module. Translates a list of EventLog events into a display-ready struct. No GenServer, no side effects.

```elixir
defmodule Shem.TUI.AgentView do
  defstruct [
    :agent_name,
    :status,
    :turn_count,
    :max_turns,
    :current_reasoning,
    :last_tool_call,   # %{name, args, result} | nil
    :history,          # [%{turn, tool}] for completed turns
    :recent_events     # last ~10 event type atoms
  ]

  @spec build(String.t()) :: {:ok, t()} | :not_found
  def build(session_id)
end
```

`build/1` calls `EventLog.events(session_id)` and folds over the result:
- `:agent_started` → sets `max_turns`
- `:agent_turn_started` → increments `turn_count`
- `:llm_call_completed` → sets `current_reasoning` from payload content
- `:agent_tool_called` → sets `last_tool_call.name` and `last_tool_call.args`
- `:agent_tool_result` → sets `last_tool_call.result`
- `:agent_turn_completed` → appends to `history`
- `:agent_done` / `:agent_error` → sets `status`

`recent_events` is the last 10 event type atoms from the full event list.

### `Shem.Agent.Preset`

Pure module. Owns preset loading and resolution.

```elixir
@spec resolve(String.t()) :: {:ok, %{system_prompt: String.t(), tools: :all | [String.t()]}} | {:error, :not_found}
def resolve(name)

@spec all() :: [%{name: String.t(), system_prompt: String.t(), tools: :all | [String.t()]}]
def all()
```

Reads `Application.get_env(:shem, :agent_presets, @builtin_presets)`. User-defined presets replace built-ins entirely. Three built-in presets:

| Name | System Prompt Focus | Tools |
|------|---------------------|-------|
| `general` | Helpful assistant, broad tasks | `:all` |
| `coding` | Elixir/OTP coding assistant, reads and edits code | `:all` |
| `explore` | Read-only explorer, no writes | `["read_file", "list_dir", "shell"]` |

---

## 3. Modified Modules

### `Shem.TUI.App`

**New model fields:**

```elixir
%{
  # existing fields ...
  agents: [],          # [%{name, status, turn_count, session_id}]
  focused_agent: nil,  # name of agent whose turn card is shown
  agent_view: nil,     # %AgentView{} | nil, rebuilt each tick
  command_error: nil   # String.t() | nil, cleared on next keypress
}
```

**New key constants** added to `app.ex`: `@enter 13` (carriage return), `@tab 9`.

**Enter key handler** (new clause in `update/2`):

```elixir
{:event, %{key: @enter}} when model.command_buffer != "" ->
  case CommandDispatch.parse(model.command_buffer) do
    {:start_agent, preset_name, task} ->
      case start_agent_from_tui(preset_name, task) do
        {:ok, name} ->
          %{model | command_buffer: "", focused_agent: name, command_error: nil}
        {:error, reason} ->
          %{model | command_error: reason}
      end
    {:stop_agent} ->
      # stops focused_agent via Shem.Agent.stop/1
      %{model | command_buffer: "", command_error: nil}
    {:list_agents} ->
      # no-op in model; agents list already updated each tick
      %{model | command_buffer: "", command_error: nil}
    {:error, reason} ->
      %{model | command_error: reason}
  end
```

**`:tick` additions:**

```elixir
agents: safe_agent_list(),
agent_view: safe_agent_view(model.focused_agent)
```

**New private helpers:**

```elixir
defp start_agent_from_tui(preset_name, task)
defp safe_agent_list()          # AgentSupervisor.which_children + ProcessRegistry
defp safe_agent_view(nil)       # → nil
defp safe_agent_view(name)      # → looks up session_id → AgentView.build/1 → unwraps {:ok, view} | :not_found → %AgentView{} | nil
```

### `Shem.TUI.Views.Interactive`

Fully replaced. Renders from `model.agent_view`, `model.agents`, and `model.focused_agent`.

Layout (locked in design):
- **2/3 width** — structured turn card (agent name + status bar, reasoning/last-tool-call split, history footer)
- **1/3 width** — event log panel (last ~10 event type atoms, yellow)
- **Agent switcher row** — one chip per agent (active/done/error); `Tab` cycles focus between agents
- **Prompt row** — command buffer with error display below if `command_error` set

When `model.agent_view` is nil: render the existing placeholder text ("No active session. Start an agent to stream output here.").

### `Shem.Agent.ToolDispatch`

Four new entries added to `@builtins`:

```elixir
%{name: "read_file",  description: "Read a file. Args: path (string).", source: :builtin},
%{name: "write_file", description: "Write a file. Args: path (string), content (string).", source: :builtin},
%{name: "list_dir",   description: "List a directory. Args: path (string).", source: :builtin},
%{name: "shell",      description: "Run a shell command. Args: cmd (string), timeout_ms (integer, optional).", source: :builtin}
```

New `dispatch_builtin` clauses:

```elixir
defp dispatch_builtin("read_file", %{"path" => path}) do
  case File.read(path) do
    {:ok, contents} -> {:ok, contents}
    {:error, reason} -> {:error, "read_file failed: #{reason}"}
  end
end

defp dispatch_builtin("write_file", %{"path" => path, "content" => content}) do
  case File.write(path, content) do
    :ok -> {:ok, "written #{byte_size(content)} bytes to #{path}"}
    {:error, reason} -> {:error, "write_file failed: #{reason}"}
  end
end

defp dispatch_builtin("list_dir", %{"path" => path}) do
  case File.ls(path) do
    {:ok, entries} -> {:ok, Enum.join(entries, "\n")}
    {:error, reason} -> {:error, "list_dir failed: #{reason}"}
  end
end

# TODO(phase-9b): route shell through K8s executor once available
defp dispatch_builtin("shell", args) do
  cmd = args["cmd"] || ""
  timeout = args["timeout_ms"] || 10_000
  [executable | cmd_args] = String.split(cmd, " ", trim: true)
  task = Task.Supervisor.async_nolink(Shem.Lab.TaskSupervisor, fn ->
    System.cmd(executable, cmd_args, stderr_to_stdout: true)
  end)
  case Task.yield(task, timeout) do
    {:ok, {output, 0}} -> {:ok, output}
    {:ok, {output, code}} -> {:error, "exit #{code}: #{output}"}
    nil ->
      Task.shutdown(task, :brutal_kill)
      {:error, "timeout after #{timeout}ms"}
  end
end
```

### `Shem.Agent` (public API)

`start/1` gains a companion that accepts a preset name:

```elixir
@spec start_with_preset(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
def start_with_preset(preset_name, task) do
  with {:ok, preset} <- Preset.resolve(preset_name) do
    config = %Config{
      task: task,
      system_prompt: preset.system_prompt,
      tools: if(preset.tools == :all, do: [], else: preset.tools),
      max_turns: 20
    }
    start(config)
  end
end
```

---

## 4. Configuration

### `config/dev.exs`

```elixir
# Optional: override or extend built-in presets
# config :shem, agent_presets: [
#   %{name: "coding", system_prompt: "You are an Elixir expert...", tools: :all},
#   %{name: "explore", system_prompt: "Read and summarise.", tools: ["read_file", "list_dir"]},
#   %{name: "general", system_prompt: "You are a helpful assistant.", tools: :all}
# ]
```

No config required — built-in presets work out of the box.

---

## 5. Data Flow: Starting an Agent from TUI

```
User types "fix the bug in event_log.ex" → Enter
  → CommandDispatch.parse/1 → {:start_agent, "general", "fix the bug..."}
  → Preset.resolve("general") → {:ok, %{system_prompt: ..., tools: :all}}
  → Agent.Config built
  → AgentSupervisor.start_agent(name, config)
  → model.focused_agent = name
  → next :tick → safe_agent_view(name)
    → EventLog.events(session_id)
    → AgentView.build(session_id)
    → model.agent_view = %AgentView{...}
  → Interactive.render(model) → turn card visible
```

---

## 6. Testing

### `Shem.TUI.CommandDispatch` (pure unit tests)
- Free text → `{:start_agent, "general", text}`
- `/agent coding task` → `{:start_agent, "coding", "task"}`
- `/stop` → `{:stop_agent}`
- `/agents` → `{:list_agents}`
- Unknown slash command → `{:error, _}`
- Empty input → `{:error, _}` or ignored

### `Shem.TUI.AgentView` (unit tests with FakeStore)
- Empty session → `:not_found`
- Session with `:agent_started` + one completed turn → correct `turn_count`, `history`
- Session with in-progress turn → `current_reasoning` and `last_tool_call` populated
- `recent_events` capped at 10 items

### `Shem.Agent.Preset` (pure unit tests)
- `resolve("general")` returns built-in
- `resolve("coding")` returns built-in
- `resolve("unknown")` returns `{:error, :not_found}`
- User-defined presets via `Application.put_env` override built-ins

### `Shem.Agent.ToolDispatch` (integration tests)
- `read_file` returns file contents
- `read_file` on missing file returns `{:error, _}`
- `write_file` writes and returns byte count
- `list_dir` returns newline-joined entries
- `shell` returns stdout for successful command
- `shell` returns exit code error for failing command
- `shell` returns timeout error when exceeded

---

## 7. Out of Scope (Phase 9b / 10+)

- `shell` sandboxed via K8s executor (Phase 9b — K8s executor)
- Scrollable turn history (current design shows latest turn only)
- Agent-to-agent coordination
- Timeline Mode TUI view
- `/agent` tab-completion for preset names
- Per-preset `max_turns` override in config
