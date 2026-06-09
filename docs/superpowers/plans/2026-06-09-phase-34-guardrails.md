# Phase 34: Guardrails Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two session-safety features — a `Ctrl+K` kill keybinding that instantly stops the active agent, and a `/fence <path>` scope fence that blocks `read_file`, `list_dir`, and local `shell` calls outside the declared directory.

**Architecture:** `Shem.Guardrails` is a new pure module (no GenServer) with `check_fence/4` and `kill_session/1`. `Agent.Config` gains a `fence` field. `ToolDispatch.execute/3` gains a config argument and calls `Guardrails.check_fence/4` before fenced tools. The TUI wires `Ctrl+K` to `kill_session/1` and `/fence` to `Agent.set_fence/2` (new `Agent.Server` handle_call). The container executor backend bypasses the fence for `shell` — the container boundary is stronger.

**Tech Stack:** Elixir/OTP, Ratatouille TUI. No new dependencies.

---

## File map

| File | Action | Purpose |
|------|--------|---------|
| `lib/shem/guardrails.ex` | Create | Pure module: `check_fence/4`, `kill_session/1` |
| `test/shem/guardrails_test.exs` | Create | Unit tests for Guardrails |
| `lib/shem/agent.ex` | Modify | Add `fence: nil` to Config struct; add `set_fence/2` public API |
| `lib/shem/agent/server.ex` | Modify | Add `handle_call({:set_fence, path}, ...)` clause; thread config into `execute_tool_calls/5` |
| `lib/shem/agent/tool_dispatch.ex` | Modify | `execute/2` → `execute/3` (config arg); fence check before `read_file`, `list_dir`, `shell` |
| `test/shem/agent/tool_dispatch_test.exs` | Modify | Add fence integration tests |
| `lib/shem/tui/command_dispatch.ex` | Modify | Add `/fence` parse clauses; add `/fence` to `commands/0` |
| `test/shem/tui/command_dispatch_test.exs` | Modify | Add `/fence` parse tests |
| `lib/shem/tui/app.ex` | Modify | Add `active_fence: nil` to model; wire `Ctrl+K`; handle `{:fence, ...}` dispatch; kill flash message |
| `lib/shem/tui/views/interactive.ex` | Modify | Show `[fence: path]` in `prompt_title/1` |

---

### Task 1: `Shem.Guardrails` module

**Files:**
- Create: `lib/shem/guardrails.ex`
- Create: `test/shem/guardrails_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/guardrails_test.exs
defmodule Shem.GuardrailsTest do
  use ExUnit.Case, async: true

  alias Shem.Guardrails

  describe "check_fence/4" do
    test "nil fence always returns :ok" do
      assert :ok = Guardrails.check_fence(nil, "read_file", %{"path" => "/etc/passwd"}, [])
    end

    test "path inside fence returns :ok" do
      fence = Path.expand("lib/shem")
      path  = Path.expand("lib/shem/agent.ex")
      assert :ok = Guardrails.check_fence(fence, "read_file", %{"path" => path}, [])
    end

    test "path outside fence returns {:blocked, reason}" do
      fence = Path.expand("lib/shem")
      path  = Path.expand("test/shem/guardrails_test.exs")
      assert {:blocked, reason} = Guardrails.check_fence(fence, "read_file", %{"path" => path}, [])
      assert reason =~ "blocked by scope fence"
    end

    test "relative path is expanded before check" do
      fence = Path.expand("lib/shem")
      # relative path that resolves inside the fence
      assert :ok = Guardrails.check_fence(fence, "list_dir", %{"path" => "lib/shem/agent"}, [])
    end

    test "relative path outside fence is blocked" do
      fence = Path.expand("lib/shem")
      assert {:blocked, _} = Guardrails.check_fence(fence, "list_dir", %{"path" => "test"}, [])
    end

    test "shell with container backend always returns :ok regardless of fence" do
      fence = Path.expand("lib/shem")
      assert :ok = Guardrails.check_fence(fence, "shell", %{"cmd" => "cat /etc/passwd"}, backend: :container)
    end

    test "shell with local backend and fence set is blocked" do
      fence = Path.expand("lib/shem")
      assert {:blocked, _} = Guardrails.check_fence(fence, "shell", %{"cmd" => "ls /"}, backend: :local)
    end

    test "shell with local backend and nil fence returns :ok" do
      assert :ok = Guardrails.check_fence(nil, "shell", %{"cmd" => "ls /"}, backend: :local)
    end

    test "read_file inside fence with container backend still checks fence" do
      fence = Path.expand("lib/shem")
      outside = Path.expand("test/shem/guardrails_test.exs")
      assert {:blocked, _} = Guardrails.check_fence(fence, "read_file", %{"path" => outside}, backend: :container)
    end
  end

  describe "kill_session/1" do
    test "returns :ok when session does not exist (no-op)" do
      assert :ok = Guardrails.kill_session("nonexistent_session_#{System.unique_integer()}")
    end
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/guardrails_test.exs
```

Expected: compile error (module not defined yet).

- [ ] **Step 3: Implement `Shem.Guardrails`**

```elixir
# lib/shem/guardrails.ex
defmodule Shem.Guardrails do
  alias Shem.Agent

  @spec check_fence(String.t() | nil, String.t(), map(), keyword()) ::
          :ok | {:blocked, String.t()}
  def check_fence(nil, _tool, _args, _opts), do: :ok

  def check_fence(_fence, "shell", _args, backend: :container), do: :ok

  def check_fence(fence, "shell", _args, _opts) do
    {:blocked, "blocked by scope fence: shell commands are restricted while fence is active (#{fence})"}
  end

  def check_fence(fence, _tool, args, _opts) do
    path = args["path"] || ""
    expanded_path  = Path.expand(path)
    expanded_fence = Path.expand(fence)

    if String.starts_with?(expanded_path, expanded_fence) do
      :ok
    else
      {:blocked, "blocked by scope fence: #{path} is outside #{fence}"}
    end
  end

  @spec kill_session(String.t()) :: :ok
  def kill_session(session_id) do
    Agent.stop(session_id)
    :ok
  end
end
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
mix test test/shem/guardrails_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Run the full suite to confirm no regressions**

```bash
mix test
```

Expected: all tests pass (783 + new).

- [ ] **Step 6: Commit**

```bash
git add lib/shem/guardrails.ex test/shem/guardrails_test.exs
git commit -m "feat: add Shem.Guardrails — check_fence/4 and kill_session/1"
```

---

### Task 2: `Agent.Config.fence` + `Agent.set_fence/2` + `Agent.Server` handle_call

**Files:**
- Modify: `lib/shem/agent.ex`
- Modify: `lib/shem/agent/server.ex`
- Modify: `test/shem/agent/server_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/shem/agent/server_test.exs` (in an appropriate describe block):

```elixir
describe "set_fence/2" do
  test "set_fence updates the fence on a running agent" do
    {:ok, name} = Agent.start(%Config{
      task: "t",
      system_prompt: "s",
      conversational: true
    })
    on_exit(fn -> Agent.stop(name) end)

    fence_path = Path.expand("lib/shem")
    assert :ok = Agent.set_fence(name, fence_path)
  end

  test "set_fence returns error for unknown agent" do
    assert {:error, :not_found} = Agent.set_fence("no_such_agent_#{System.unique_integer()}", "/tmp")
  end

  test "set_fence accepts nil to clear the fence" do
    {:ok, name} = Agent.start(%Config{
      task: "t",
      system_prompt: "s",
      conversational: true
    })
    on_exit(fn -> Agent.stop(name) end)

    assert :ok = Agent.set_fence(name, nil)
  end
end
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
mix test test/shem/agent/server_test.exs --only "set_fence"
```

Expected: `** (UndefinedFunctionError) function Shem.Agent.set_fence/2 is undefined`

- [ ] **Step 3: Add `fence: nil` to `Agent.Config` struct**

In `lib/shem/agent.ex`, the Config struct is defined at line 6. Change:

```elixir
defstruct [:task, :system_prompt, model: :default, tools: [], max_turns: 20,
           spawn_depth: 0, conversational: false, project_context: nil]
```

to:

```elixir
defstruct [:task, :system_prompt, model: :default, tools: [], max_turns: 20,
           spawn_depth: 0, conversational: false, project_context: nil, fence: nil]
```

Also add the typespec for `fence`. Find the `@type t :: %Config{` block and add:

```elixir
fence: String.t() | nil,
```

- [ ] **Step 4: Add `set_fence/2` to the `Agent` public API**

In `lib/shem/agent.ex`, after the `send_message/2` function, add:

```elixir
@spec set_fence(String.t(), String.t() | nil) :: :ok | {:error, :not_found}
def set_fence(name, path) do
  case Shem.Registry.whereis(name) do
    nil -> {:error, :not_found}
    pid -> GenServer.call(pid, {:set_fence, path})
  end
end
```

- [ ] **Step 5: Add `handle_call({:set_fence, path}, ...)` to `Agent.Server`**

In `lib/shem/agent/server.ex`, add after the last `handle_call` clause (before `handle_info`):

```elixir
def handle_call({:set_fence, path}, _from, state) do
  new_config = %{state.config | fence: path}
  {:reply, :ok, %{state | config: new_config}}
end
```

- [ ] **Step 6: Run the tests to confirm they pass**

```bash
mix test test/shem/agent/server_test.exs
```

Expected: all tests pass including the new set_fence tests.

- [ ] **Step 7: Run the full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add lib/shem/agent.ex lib/shem/agent/server.ex test/shem/agent/server_test.exs
git commit -m "feat: add Agent.Config.fence field and Agent.set_fence/2"
```

---

### Task 3: `ToolDispatch.execute/3` fence check

**Files:**
- Modify: `lib/shem/agent/tool_dispatch.ex`
- Modify: `lib/shem/agent/server.ex`
- Modify: `test/shem/agent/tool_dispatch_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/agent/tool_dispatch_test.exs`:

```elixir
describe "execute/3 — scope fence" do
  setup do
    # Create a temp file inside a temp dir to use as the fence root
    tmp = System.tmp_dir!()
    fence_dir = Path.join(tmp, "shem_fence_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(fence_dir)
    test_file = Path.join(fence_dir, "allowed.txt")
    File.write!(test_file, "hello")
    on_exit(fn -> File.rm_rf!(fence_dir) end)
    {:ok, fence_dir: fence_dir, test_file: test_file}
  end

  test "read_file inside fence succeeds", %{fence_dir: fence_dir, test_file: test_file} do
    config = %Config{task: "t", system_prompt: "s", fence: fence_dir}
    manifest = ToolDispatch.build_manifest(config)
    assert {:ok, "hello"} = ToolDispatch.execute(%{name: "read_file", args: %{"path" => test_file}}, manifest, config)
  end

  test "read_file outside fence returns error", %{fence_dir: fence_dir} do
    config = %Config{task: "t", system_prompt: "s", fence: fence_dir}
    manifest = ToolDispatch.build_manifest(config)
    result = ToolDispatch.execute(%{name: "read_file", args: %{"path" => "/etc/hosts"}}, manifest, config)
    assert {:error, reason} = result
    assert reason =~ "blocked by scope fence"
  end

  test "list_dir outside fence returns error", %{fence_dir: fence_dir} do
    config = %Config{task: "t", system_prompt: "s", fence: fence_dir}
    manifest = ToolDispatch.build_manifest(config)
    result = ToolDispatch.execute(%{name: "list_dir", args: %{"path" => "/tmp"}}, manifest, config)
    assert {:error, reason} = result
    assert reason =~ "blocked by scope fence"
  end

  test "nil fence does not block anything" do
    config = %Config{task: "t", system_prompt: "s", fence: nil}
    manifest = ToolDispatch.build_manifest(config)
    # /tmp is always readable and listable
    assert {:ok, _} = ToolDispatch.execute(%{name: "list_dir", args: %{"path" => System.tmp_dir!()}}, manifest, config)
  end

  test "shell with local backend is blocked when fence is set", %{fence_dir: fence_dir} do
    config = %Config{task: "t", system_prompt: "s", fence: fence_dir}
    manifest = ToolDispatch.build_manifest(config)
    result = ToolDispatch.execute(%{name: "shell", args: %{"cmd" => "echo hello"}}, manifest, config)
    assert {:error, reason} = result
    assert reason =~ "blocked by scope fence"
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/agent/tool_dispatch_test.exs --only "scope fence"
```

Expected: tests fail because `execute/2` is currently defined, not `execute/3`.

- [ ] **Step 3: Add `resolved_backend/0` helper and update `execute` to `execute/3`**

In `lib/shem/agent/tool_dispatch.ex`:

1. Add the alias at the top of the module:

```elixir
alias Shem.Agent.Config
alias Shem.Guardrails
alias Shem.Lab.Executor.Backend
```

2. Change both `execute/2` clauses to `execute/3` with a default config:

```elixir
@spec execute(%{name: String.t(), args: map()}, [map()], Config.t()) ::
        {:ok, String.t()} | {:error, String.t()}
def execute(%{name: "list_tools"}, manifest, _config) do
  lines = Enum.map(manifest, fn %{name: n, description: d} -> "- #{n}: #{d}" end)
  {:ok, "Available tools:\n" <> Enum.join(lines, "\n")}
end

def execute(%{name: name, args: args} = call, manifest, config) do
  case Enum.find(manifest, &(&1.name == name)) do
    nil ->
      {:error, "unknown tool: #{name}"}

    %{source: :builtin} ->
      case Guardrails.check_fence(config.fence, name, args, backend: resolved_backend()) do
        :ok -> dispatch_builtin(name, args)
        {:blocked, reason} -> {:error, reason}
      end

    %{source: {:mcp, server}} ->
      dispatch_mcp(server, name, args)

    %{source: {:lab, id}, trust: trust} ->
      if gate_blocks?(trust),
        do: {:error, "tool blocked (trust: #{trust})"},
        else: dispatch_lab(id, args)
  end
end
```

3. Add the `resolved_backend/0` private helper at the bottom of the module (before `score_to_band`):

```elixir
defp resolved_backend do
  case Application.get_env(:shem, :resolved_executor_backend, Backend.Local) do
    Backend.Container -> :container
    _ -> :local
  end
end
```

- [ ] **Step 4: Update `execute_tool_calls` in `Agent.Server` to pass config**

In `lib/shem/agent/server.ex`:

Change line 125:
```elixir
history = execute_tool_calls(calls, manifest, history, state.session_id)
```
to:
```elixir
history = execute_tool_calls(calls, manifest, history, state.session_id, state.config)
```

Change the `execute_tool_calls` function definition at line 145:
```elixir
defp execute_tool_calls(calls, manifest, history, session_id) do
```
to:
```elixir
defp execute_tool_calls(calls, manifest, history, session_id, config) do
```

Change the `ToolDispatch.execute` call at line 150:
```elixir
case ToolDispatch.execute(call, manifest) do
```
to:
```elixir
case ToolDispatch.execute(call, manifest, config) do
```

- [ ] **Step 5: Run the fence tests to confirm they pass**

```bash
mix test test/shem/agent/tool_dispatch_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Run the full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex lib/shem/agent/server.ex test/shem/agent/tool_dispatch_test.exs
git commit -m "feat: fence check in ToolDispatch.execute/3 for read_file, list_dir, shell"
```

---

### Task 4: `CommandDispatch` `/fence` parse

**Files:**
- Modify: `lib/shem/tui/command_dispatch.ex`
- Modify: `test/shem/tui/command_dispatch_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/tui/command_dispatch_test.exs`:

```elixir
describe "parse/1 — /fence command" do
  test "/fence <path> returns {:fence, path}" do
    assert {:fence, "src/auth"} = CommandDispatch.parse("/fence src/auth")
  end

  test "/fence with absolute path" do
    assert {:fence, "/home/user/proj/src"} = CommandDispatch.parse("/fence /home/user/proj/src")
  end

  test "/fence clear returns {:fence_clear}" do
    assert {:fence_clear} = CommandDispatch.parse("/fence clear")
  end

  test "/fence with no argument returns {:fence_show}" do
    assert {:fence_show} = CommandDispatch.parse("/fence")
  end

  test "/fence with multi-word path" do
    assert {:fence, "src/my module"} = CommandDispatch.parse("/fence src/my module")
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/tui/command_dispatch_test.exs
```

Expected: new tests fail with `{:error, "unknown command: /fence ..."}`.

- [ ] **Step 3: Add `/fence` clauses to `parse/1`**

In `lib/shem/tui/command_dispatch.ex`, in the `case parts do` block, add before the catch-all `_` clause:

```elixir
["fence"] ->
  {:fence_show}

["fence", "clear"] ->
  {:fence_clear}

["fence" | path_parts] when path_parts != [] ->
  {:fence, Enum.join(path_parts, " ")}
```

Also update the `@spec` for `parse/1` to include the new return types:

```elixir
| {:fence, String.t()}
| {:fence_clear}
| {:fence_show}
```

- [ ] **Step 4: Add `/fence` to `commands/0`**

In `lib/shem/tui/command_dispatch.ex`, add to the `commands/0` list:

```elixir
{"/fence <path>", "Restrict agent to a directory (e.g. /fence src/auth)"},
{"/fence clear", "Remove the active scope fence"},
```

- [ ] **Step 5: Run tests to confirm they pass**

```bash
mix test test/shem/tui/command_dispatch_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Run the full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/tui/command_dispatch.ex test/shem/tui/command_dispatch_test.exs
git commit -m "feat: add /fence command parsing to CommandDispatch"
```

---

### Task 5: TUI wiring — `Ctrl+K`, `/fence` handling, fence display

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Modify: `lib/shem/tui/views/interactive.ex`
- Modify: `test/shem/tui/app_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/tui/app_test.exs`:

```elixir
describe "Ctrl+K kill" do
  test "Ctrl+K with active conversational agent stops the agent and clears it" do
    # Start a real conversational agent
    {:ok, name} = Shem.Agent.start(%Shem.Agent.Config{
      task: "t",
      system_prompt: "s",
      conversational: true
    })

    model = App.init(%{})
    model = %{model | active_conversational_agent: name}

    updated = App.update(model, {:event, %{key: 11, ch: 0}})

    assert updated.active_conversational_agent == nil
    assert updated.command_output =~ "Agent stopped"
  end

  test "Ctrl+K with no active agent is a no-op" do
    model = App.init(%{})
    assert model.active_conversational_agent == nil

    updated = App.update(model, {:event, %{key: 11, ch: 0}})

    assert updated == model
  end
end

describe "/fence command handling" do
  test "/fence <path> sets active_fence on model" do
    model = App.init(%{})
    model_with_input = %{model | command_buffer: "/fence src/auth", mode: :interactive}
    updated = App.update(model_with_input, {:event, %{key: 13}})

    assert updated.active_fence == Path.expand("src/auth")
  end

  test "/fence clear sets active_fence to nil" do
    model = %{App.init(%{}) | active_fence: Path.expand("src/auth")}
    model_with_input = %{model | command_buffer: "/fence clear", mode: :interactive}

    updated = App.update(model_with_input, {:event, %{key: 13}})

    assert updated.active_fence == nil
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/tui/app_test.exs
```

Expected: new tests fail — `active_fence` field not in model, `key: 11` not handled.

- [ ] **Step 3: Add `active_fence: nil` to TUI model init**

In `lib/shem/tui/app.ex`, in the `init/1` function, add to the returned map (after `active_conversational_agent: nil`):

```elixir
active_fence: nil,
```

- [ ] **Step 4: Add `@ctrl_k` constant and `Ctrl+K` keybinding**

At the top of `lib/shem/tui/app.ex`, after the existing key constants:

```elixir
@ctrl_k 11
```

Then add the `Ctrl+K` clause in `update/2`, in the main event-handling section, before the `{:event, %{ch: ?d, key: 0}}` catch-all (line ~141). It should handle all modes except when a modal is showing:

```elixir
{:event, %{key: @ctrl_k}} when not model.show_welcome and not model.show_help ->
  case model.active_conversational_agent do
    nil ->
      model

    name ->
      if model.stream_sink, do: Shem.TUI.StreamSink.stop(model.stream_sink)
      Shem.Guardrails.kill_session(name)

      %{model |
        active_conversational_agent: nil,
        focused_agent: nil,
        agent_view: nil,
        stream_sink: nil,
        command_output: "Agent stopped — use /history to branch from a prior event.",
        command_error: nil
      }
  end
```

- [ ] **Step 5: Handle `{:fence, path}`, `{:fence_clear}`, `{:fence_show}` in command dispatch**

In `lib/shem/tui/app.ex`, in the `{:event, %{key: @enter}} when model.command_buffer != ""` block, inside the `case CommandDispatch.parse(model.command_buffer) do` expression, add the new cases (before the catch-all `_` clause):

```elixir
{:fence, path} ->
  expanded = Path.expand(path)
  if model.active_conversational_agent do
    Shem.Agent.set_fence(model.active_conversational_agent, expanded)
  end
  %{model | command_buffer: "", active_fence: expanded, command_error: nil, command_output: "Fence set: #{expanded}"}

{:fence_clear} ->
  if model.active_conversational_agent do
    Shem.Agent.set_fence(model.active_conversational_agent, nil)
  end
  %{model | command_buffer: "", active_fence: nil, command_error: nil, command_output: "Fence cleared."}

{:fence_show} ->
  output = case model.active_fence do
    nil -> "No fence active."
    path -> "Active fence: #{path}"
  end
  %{model | command_buffer: "", command_output: output, command_error: nil}
```

- [ ] **Step 6: Add fence display to `prompt_title/1` in Interactive view**

In `lib/shem/tui/views/interactive.ex`, change the `prompt_title` functions. Add a new clause before the catch-all:

```elixir
defp prompt_title(%{paused: true}), do: "[ PAUSED — press SPACE to resume ]"
defp prompt_title(%{command_buffer: "/" <> _ = buf}), do: "Command: #{buf}"
defp prompt_title(%{active_fence: fence}) when not is_nil(fence),
  do: "d=Dashboard  i=Interactive  Tab=cycle  /agent <preset> <task>  /stop  [fence: #{fence}]"
defp prompt_title(_), do: "d=Dashboard  i=Interactive  Tab=cycle  /agent <preset> <task>  /stop  /agents"
```

- [ ] **Step 7: Run the TUI tests**

```bash
mix test test/shem/tui/
```

Expected: all tests pass.

- [ ] **Step 8: Run the full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
git add lib/shem/tui/app.ex lib/shem/tui/views/interactive.ex test/shem/tui/app_test.exs
git commit -m "feat: wire Ctrl+K kill and /fence command in TUI (Phase 34)"
```
