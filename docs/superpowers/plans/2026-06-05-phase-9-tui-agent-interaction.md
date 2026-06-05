# Phase 9: TUI Agent Interaction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Shem usable as a daily driver — start agents from the TUI, watch turn-by-turn progress, and give agents real file system and shell tools to work with.

**Architecture:** Four independent modules (`Preset`, `CommandDispatch`, `AgentView`, file system tools) are built first as pure, well-tested units. Then `app.ex` is wired up to use them, and the interactive view is replaced with a live rendering. EventLog polling on 500ms ticks provides turn-by-turn display — no streaming infrastructure needed.

**Tech Stack:** Elixir/OTP 29, Ratatouille TUI, existing EventLog + AgentSupervisor + ProcessRegistry, `Horde.DynamicSupervisor.which_children/1`, `System.cmd/3` via `Task.Supervisor`.

---

## File Map

**New files:**
- `lib/shem/agent/preset.ex` — pure; loads/resolves named presets from config
- `lib/shem/tui/command_dispatch.ex` — pure; parses command buffer string → action tuple
- `lib/shem/tui/agent_view.ex` — pure; folds EventLog events → display struct
- `test/shem/agent/preset_test.exs`
- `test/shem/tui/command_dispatch_test.exs`
- `test/shem/tui/agent_view_test.exs`

**Modified files:**
- `lib/shem/agent.ex` — add `start_with_preset/2`
- `lib/shem/agent/tool_dispatch.ex` — add `read_file`, `write_file`, `list_dir`, `shell` builtins
- `lib/shem/tui/app.ex` — new model fields, Enter/Tab key handlers, tick additions
- `lib/shem/tui/views/interactive.ex` — full replacement, renders from model
- `test/shem/agent/tool_dispatch_test.exs` — new tests for file/shell tools
- `test/shem/tui/app_test.exs` — tests for new model fields and Tab handler

---

## Task 1: Shem.Agent.Preset

Pure module. Reads `Application.get_env(:shem, :agent_presets, @builtin_presets)` and exposes `resolve/1` and `all/0`. Three built-in presets ship out of the box.

**Files:**
- Create: `lib/shem/agent/preset.ex`
- Create: `test/shem/agent/preset_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/shem/agent/preset_test.exs`:

```elixir
defmodule Shem.Agent.PresetTest do
  use ExUnit.Case, async: true

  alias Shem.Agent.Preset

  describe "resolve/1 — built-ins" do
    test "general preset exists with :all tools" do
      assert {:ok, preset} = Preset.resolve("general")
      assert is_binary(preset.system_prompt)
      assert preset.tools == :all
    end

    test "coding preset exists with :all tools" do
      assert {:ok, preset} = Preset.resolve("coding")
      assert is_binary(preset.system_prompt)
      assert preset.tools == :all
    end

    test "explore preset exists with restricted tools list" do
      assert {:ok, preset} = Preset.resolve("explore")
      assert is_binary(preset.system_prompt)
      assert is_list(preset.tools)
      assert "read_file" in preset.tools
      assert "list_dir" in preset.tools
      assert "shell" in preset.tools
      refute "write_file" in preset.tools
    end

    test "returns :not_found for unknown preset" do
      assert {:error, :not_found} = Preset.resolve("nonexistent_xyz")
    end
  end

  describe "resolve/1 — user overrides" do
    test "user-defined presets override built-ins entirely" do
      custom = [%{name: "custom", system_prompt: "custom prompt", tools: :all}]
      Application.put_env(:shem, :agent_presets, custom)
      on_exit(fn -> Application.delete_env(:shem, :agent_presets) end)

      assert {:ok, preset} = Preset.resolve("custom")
      assert preset.system_prompt == "custom prompt"
      assert {:error, :not_found} = Preset.resolve("general")
    end
  end

  describe "all/0" do
    test "returns list of preset maps" do
      presets = Preset.all()
      assert is_list(presets)
      assert length(presets) >= 3
    end

    test "each preset has name, system_prompt, and tools keys" do
      Preset.all()
      |> Enum.each(fn p ->
        assert Map.has_key?(p, :name)
        assert Map.has_key?(p, :system_prompt)
        assert Map.has_key?(p, :tools)
      end)
    end

    test "built-in names are present by default" do
      names = Preset.all() |> Enum.map(& &1.name)
      assert "general" in names
      assert "coding" in names
      assert "explore" in names
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/agent/preset_test.exs --seed 0
```

Expected: compile error — module does not exist.

- [ ] **Step 3: Create lib/shem/agent/preset.ex**

```elixir
defmodule Shem.Agent.Preset do
  @builtin_presets [
    %{
      name: "general",
      system_prompt: "You are a helpful assistant. Think step by step and use available tools to complete the task. When finished, respond with plain text only.",
      tools: :all
    },
    %{
      name: "coding",
      system_prompt: "You are an expert Elixir and OTP engineer. Read the relevant code and understand the context before making changes. Use write_file to edit files, shell to run tests (e.g. mix test), and read_file/list_dir to explore. Prefer small, verified changes over large rewrites. When finished, confirm what was done.",
      tools: :all
    },
    %{
      name: "explore",
      system_prompt: "You are a read-only code explorer. Your job is to understand and explain code, not to modify it. Use read_file, list_dir, and shell (for grep/find) to explore the codebase. Do not use write_file or write_tool.",
      tools: ["read_file", "list_dir", "shell"]
    }
  ]

  @spec resolve(String.t()) ::
          {:ok, %{system_prompt: String.t(), tools: :all | [String.t()]}}
          | {:error, :not_found}
  def resolve(name) do
    presets = Application.get_env(:shem, :agent_presets, @builtin_presets)

    case Enum.find(presets, &(&1.name == name)) do
      nil -> {:error, :not_found}
      preset -> {:ok, Map.take(preset, [:system_prompt, :tools])}
    end
  end

  @spec all() :: [map()]
  def all do
    Application.get_env(:shem, :agent_presets, @builtin_presets)
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/agent/preset_test.exs --seed 0
```

Expected: all 9 tests pass.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: 327 + 9 = 336 tests passing.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/agent/preset.ex test/shem/agent/preset_test.exs
git commit -m "feat: Shem.Agent.Preset — named preset loading and resolution"
```

---

## Task 2: Shem.Agent.start_with_preset/2

Adds a convenience function to the `Shem.Agent` public API that resolves a preset by name and starts an agent with it.

**Files:**
- Modify: `lib/shem/agent.ex`

- [ ] **Step 1: Read the current file**

```bash
cat lib/shem/agent.ex
```

Note the existing `start/1`, `stop/1`, `status/1`, `await/2` functions and the `Config` struct.

- [ ] **Step 2: Write the failing test**

Add to `test/shem/agent/server_test.exs` (find the file first to understand its setup pattern, then add a new describe block):

```elixir
describe "start_with_preset/2" do
  test "starts an agent using a named preset" do
    stub("done")
    assert {:ok, name} = Shem.Agent.start_with_preset("general", "say hello")
    assert is_binary(name)
    assert {:ok, _status} = Shem.Agent.await(name, 2_000)
  end

  test "returns error for unknown preset" do
    assert {:error, :not_found} = Shem.Agent.start_with_preset("no_such_preset", "task")
  end
end
```

- [ ] **Step 3: Run to confirm failure**

```bash
mix test test/shem/agent/server_test.exs --seed 0 -k "start_with_preset"
```

Expected: fails — `start_with_preset/2` is undefined.

- [ ] **Step 4: Add start_with_preset/2 to lib/shem/agent.ex**

Add after the existing `await/2` function (keeping the `Config` defmodule and all existing functions intact):

```elixir
@spec start_with_preset(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
def start_with_preset(preset_name, task) do
  with {:ok, preset} <- Shem.Agent.Preset.resolve(preset_name) do
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

- [ ] **Step 5: Run tests**

```bash
mix test test/shem/agent/server_test.exs --seed 0
```

Expected: all server tests pass including the two new ones.

- [ ] **Step 6: Run full suite**

```bash
mix test
```

Expected: all tests passing.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent.ex test/shem/agent/server_test.exs
git commit -m "feat: Agent.start_with_preset/2 — start agent from named preset"
```

---

## Task 3: File System + Shell Built-in Tools

Adds `read_file`, `write_file`, `list_dir`, and `shell` to `ToolDispatch`. The `shell` tool uses `sh -c` to handle complex commands with pipes and arguments. **Note:** `shell` runs locally until the K8s executor lands in Phase 9b.

**Files:**
- Modify: `lib/shem/agent/tool_dispatch.ex`
- Modify: `test/shem/agent/tool_dispatch_test.exs`

- [ ] **Step 1: Write the failing tests**

Open `test/shem/agent/tool_dispatch_test.exs` and add after the existing describe blocks:

```elixir
describe "read_file built-in" do
  test "returns file contents on success" do
    path = Path.join(System.tmp_dir!(), "shem_test_read_#{System.unique_integer([:positive])}.txt")
    File.write!(path, "hello world")
    on_exit(fn -> File.rm(path) end)

    manifest = ToolDispatch.build_manifest(@config)
    assert {:ok, "hello world"} = ToolDispatch.execute(%{tool: "read_file", args: %{"path" => path}}, manifest)
  end

  test "returns error for missing file" do
    manifest = ToolDispatch.build_manifest(@config)
    result = ToolDispatch.execute(%{tool: "read_file", args: %{"path" => "/nonexistent/path/xyz"}}, manifest)
    assert match?({:error, _}, result)
  end
end

describe "write_file built-in" do
  test "writes file and returns byte count message" do
    path = Path.join(System.tmp_dir!(), "shem_test_write_#{System.unique_integer([:positive])}.txt")
    on_exit(fn -> File.rm(path) end)

    manifest = ToolDispatch.build_manifest(@config)
    assert {:ok, msg} = ToolDispatch.execute(%{tool: "write_file", args: %{"path" => path, "content" => "test content"}}, manifest)
    assert String.contains?(msg, "bytes")
    assert File.read!(path) == "test content"
  end

  test "returns error for unwritable path" do
    manifest = ToolDispatch.build_manifest(@config)
    result = ToolDispatch.execute(%{tool: "write_file", args: %{"path" => "/nonexistent_dir/file.txt", "content" => "x"}}, manifest)
    assert match?({:error, _}, result)
  end
end

describe "list_dir built-in" do
  test "returns newline-joined directory entries" do
    manifest = ToolDispatch.build_manifest(@config)
    assert {:ok, entries} = ToolDispatch.execute(%{tool: "list_dir", args: %{"path" => "lib/shem"}}, manifest)
    assert String.contains?(entries, "agent")
    assert String.contains?(entries, "event_log.ex")
  end

  test "returns error for missing directory" do
    manifest = ToolDispatch.build_manifest(@config)
    result = ToolDispatch.execute(%{tool: "list_dir", args: %{"path" => "/nonexistent_xyz"}}, manifest)
    assert match?({:error, _}, result)
  end
end

describe "shell built-in" do
  test "returns stdout for successful command" do
    manifest = ToolDispatch.build_manifest(@config)
    assert {:ok, output} = ToolDispatch.execute(%{tool: "shell", args: %{"cmd" => "echo hello"}}, manifest)
    assert String.trim(output) == "hello"
  end

  test "returns exit code error for failing command" do
    manifest = ToolDispatch.build_manifest(@config)
    result = ToolDispatch.execute(%{tool: "shell", args: %{"cmd" => "exit 1"}}, manifest)
    assert match?({:error, "exit 1:" <> _}, result)
  end

  test "returns timeout error when exceeded" do
    manifest = ToolDispatch.build_manifest(@config)
    result = ToolDispatch.execute(%{tool: "shell", args: %{"cmd" => "sleep 10", "timeout_ms" => 100}}, manifest)
    assert match?({:error, "timeout after 100ms"}, result)
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/shem/agent/tool_dispatch_test.exs --seed 0
```

Expected: new tests fail — built-ins don't exist yet.

- [ ] **Step 3: Add builtins to @builtins list**

In `lib/shem/agent/tool_dispatch.ex`, extend the `@builtins` list:

```elixir
@builtins [
  %{
    name: "write_tool",
    description:
      "Graduate a new Elixir tool into the Lab. Args: source (string), test_source (string).",
    source: :builtin
  },
  %{
    name: "run_code",
    description:
      "Run Elixir source defining a module with run/0. Returns the result. Args: source (string), timeout_ms (integer, optional).",
    source: :builtin
  },
  %{
    name: "list_tools",
    description: "List all tools currently available.",
    source: :builtin
  },
  %{
    name: "read_file",
    description: "Read a file and return its contents. Args: path (string).",
    source: :builtin
  },
  %{
    name: "write_file",
    description: "Write content to a file. Args: path (string), content (string).",
    source: :builtin
  },
  %{
    name: "list_dir",
    description: "List entries in a directory. Args: path (string).",
    source: :builtin
  },
  %{
    name: "shell",
    description:
      "Run a shell command and return stdout. Args: cmd (string), timeout_ms (integer, optional, default 10000). NOTE: runs locally until Phase 9b K8s executor.",
    source: :builtin
  }
]
```

- [ ] **Step 4: Add dispatch_builtin clauses**

In `lib/shem/agent/tool_dispatch.ex`, add after the existing `dispatch_builtin("write_tool", ...)` clause (before the catch-all `dispatch_builtin(name, _args)`):

```elixir
defp dispatch_builtin("read_file", args) do
  path = args["path"] || ""

  case File.read(path) do
    {:ok, contents} -> {:ok, contents}
    {:error, reason} -> {:error, "read_file failed: #{:file.format_error(reason)}"}
  end
end

defp dispatch_builtin("write_file", args) do
  path = args["path"] || ""
  content = args["content"] || ""

  case File.write(path, content) do
    :ok -> {:ok, "written #{byte_size(content)} bytes to #{path}"}
    {:error, reason} -> {:error, "write_file failed: #{:file.format_error(reason)}"}
  end
end

defp dispatch_builtin("list_dir", args) do
  path = args["path"] || ""

  case File.ls(path) do
    {:ok, entries} -> {:ok, Enum.join(entries, "\n")}
    {:error, reason} -> {:error, "list_dir failed: #{:file.format_error(reason)}"}
  end
end

# TODO(phase-9b): route through K8s executor once available — currently runs locally
defp dispatch_builtin("shell", args) do
  cmd = args["cmd"] || ""
  timeout = args["timeout_ms"] || 10_000

  task =
    Task.Supervisor.async_nolink(Shem.Lab.TaskSupervisor, fn ->
      System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
    end)

  case Task.yield(task, timeout) do
    {:ok, {output, 0}} ->
      {:ok, output}

    {:ok, {output, code}} ->
      {:error, "exit #{code}: #{output}"}

    nil ->
      Task.shutdown(task, :brutal_kill)
      {:error, "timeout after #{timeout}ms"}
  end
end
```

- [ ] **Step 5: Update build_manifest test expectation**

In `test/shem/agent/tool_dispatch_test.exs`, find the test:

```elixir
test "built-in entries have :builtin source" do
  manifest = ToolDispatch.build_manifest(@config)
  builtins = Enum.filter(manifest, &(&1.source == :builtin))
  assert length(builtins) == 3
end
```

Change `== 3` to `== 7`:

```elixir
test "built-in entries have :builtin source" do
  manifest = ToolDispatch.build_manifest(@config)
  builtins = Enum.filter(manifest, &(&1.source == :builtin))
  assert length(builtins) == 7
end
```

- [ ] **Step 6: Run tool dispatch tests**

```bash
mix test test/shem/agent/tool_dispatch_test.exs --seed 0
```

Expected: all pass.

- [ ] **Step 7: Run full suite**

```bash
mix test
```

Expected: all tests passing.

- [ ] **Step 8: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex test/shem/agent/tool_dispatch_test.exs
git commit -m "feat: add read_file, write_file, list_dir, shell built-in tools"
```

---

## Task 4: Shem.TUI.CommandDispatch

Pure parser module. Takes a command buffer string, returns a tagged action tuple. No side effects.

**Files:**
- Create: `lib/shem/tui/command_dispatch.ex`
- Create: `test/shem/tui/command_dispatch_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/shem/tui/command_dispatch_test.exs`:

```elixir
defmodule Shem.TUI.CommandDispatchTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.CommandDispatch

  describe "parse/1 — free text" do
    test "plain text starts agent with general preset" do
      assert {:start_agent, "general", "fix the bug in foo.ex"} =
               CommandDispatch.parse("fix the bug in foo.ex")
    end

    test "empty string returns error" do
      assert {:error, _} = CommandDispatch.parse("")
    end
  end

  describe "parse/1 — /agent command" do
    test "/agent <preset> <task> starts agent with named preset" do
      assert {:start_agent, "coding", "fix the memory leak"} =
               CommandDispatch.parse("/agent coding fix the memory leak")
    end

    test "/agent with multi-word task" do
      assert {:start_agent, "explore", "find all GenServer modules in lib"} =
               CommandDispatch.parse("/agent explore find all GenServer modules in lib")
    end

    test "/agent with no task returns error" do
      assert {:error, _} = CommandDispatch.parse("/agent coding")
    end

    test "/agent with no preset and no task returns error" do
      assert {:error, _} = CommandDispatch.parse("/agent")
    end
  end

  describe "parse/1 — /stop command" do
    test "/stop returns stop_agent" do
      assert {:stop_agent} = CommandDispatch.parse("/stop")
    end
  end

  describe "parse/1 — /agents command" do
    test "/agents returns list_agents" do
      assert {:list_agents} = CommandDispatch.parse("/agents")
    end
  end

  describe "parse/1 — unknown slash commands" do
    test "unknown slash command returns error" do
      assert {:error, msg} = CommandDispatch.parse("/unknown")
      assert String.contains?(msg, "unknown command")
    end

    test "/run returns error (not supported — use /agent)" do
      assert {:error, _} = CommandDispatch.parse("/run do something")
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/shem/tui/command_dispatch_test.exs --seed 0
```

Expected: compile error — module does not exist.

- [ ] **Step 3: Create lib/shem/tui/command_dispatch.ex**

```elixir
defmodule Shem.TUI.CommandDispatch do
  @spec parse(String.t()) ::
          {:start_agent, String.t(), String.t()}
          | {:stop_agent}
          | {:list_agents}
          | {:error, String.t()}
  def parse(""), do: {:error, "empty input"}

  def parse("/" <> rest) do
    parts = String.split(rest, " ", trim: true)

    case parts do
      ["agent", preset | task_parts] when task_parts != [] ->
        {:start_agent, preset, Enum.join(task_parts, " ")}

      ["agent" | _] ->
        {:error, "usage: /agent <preset> <task>"}

      ["stop"] ->
        {:stop_agent}

      ["agents"] ->
        {:list_agents}

      _ ->
        {:error, "unknown command: /#{rest}"}
    end
  end

  def parse(text), do: {:start_agent, "general", text}
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/tui/command_dispatch_test.exs --seed 0
```

Expected: all 10 tests pass.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: all tests passing.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/command_dispatch.ex test/shem/tui/command_dispatch_test.exs
git commit -m "feat: Shem.TUI.CommandDispatch — command buffer parser"
```

---

## Task 5: Shem.TUI.AgentView

Pure module. Calls `EventLog.events/1` and folds the result into a display-ready struct. No side effects beyond reading EventLog.

**Files:**
- Create: `lib/shem/tui/agent_view.ex`
- Create: `test/shem/tui/agent_view_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/shem/tui/agent_view_test.exs`:

```elixir
defmodule Shem.TUI.AgentViewTest do
  use ExUnit.Case, async: false

  alias Shem.TUI.AgentView
  alias Shem.EventLog

  defp open(id) do
    {:ok, ^id} = EventLog.start_session(id)
    id
  end

  defp session_id, do: "ses_AGVIEW_#{System.unique_integer([:positive])}"

  describe "build/1" do
    test "returns :not_found for empty session" do
      id = open(session_id())
      assert :not_found = AgentView.build(id)
    end

    test "returns :not_found for non-existent session" do
      assert :not_found = AgentView.build("ses_DOES_NOT_EXIST_XYZ")
    end

    test "returns {:ok, view} after agent_started event" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "do something", model: :default, max_turns: 15})
      assert {:ok, view} = AgentView.build(id)
      assert view.max_turns == 15
      assert view.status == :running
      assert view.turn_count == 0
    end

    test "turn_count increments on agent_turn_started" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(id, :agent_turn_started, %{turn: 1})
      EventLog.append(id, :agent_turn_started, %{turn: 2})
      assert {:ok, view} = AgentView.build(id)
      assert view.turn_count == 2
    end

    test "current_reasoning is set from llm_call_completed" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(id, :agent_turn_started, %{turn: 1})
      EventLog.append(id, :llm_call_completed, %{content: "I will read the file first.", tokens_used: 5, model: :default, latency_ms: 100})
      assert {:ok, view} = AgentView.build(id)
      assert view.current_reasoning == "I will read the file first."
    end

    test "last_tool_call is populated from tool_called and tool_result events" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(id, :agent_turn_started, %{turn: 1})
      EventLog.append(id, :agent_tool_called, %{tool: "read_file", args: %{"path" => "lib/foo.ex"}})
      EventLog.append(id, :agent_tool_result, %{tool: "read_file", result: "defmodule Foo do"})
      assert {:ok, view} = AgentView.build(id)
      assert view.last_tool_call.name == "read_file"
      assert view.last_tool_call.result == "defmodule Foo do"
    end

    test "history accumulates completed turns" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(id, :agent_turn_started, %{turn: 1})
      EventLog.append(id, :agent_tool_called, %{tool: "read_file", args: %{}})
      EventLog.append(id, :agent_turn_completed, %{turn: 1, outcome: :tool_calls})
      EventLog.append(id, :agent_turn_started, %{turn: 2})
      EventLog.append(id, :agent_turn_completed, %{turn: 2, outcome: :done})
      assert {:ok, view} = AgentView.build(id)
      assert length(view.history) == 2
      assert hd(view.history).tool == "read_file"
    end

    test "status becomes :done on agent_done event" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(id, :agent_done, %{reason: :answer})
      assert {:ok, view} = AgentView.build(id)
      assert view.status == :done
    end

    test "status becomes :error on agent_error event" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(id, :agent_error, %{reason: "llm failed"})
      assert {:ok, view} = AgentView.build(id)
      assert view.status == :error
    end

    test "recent_events contains last event types (capped at 10)" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      for i <- 1..12 do
        EventLog.append(id, :agent_turn_started, %{turn: i})
      end
      assert {:ok, view} = AgentView.build(id)
      assert length(view.recent_events) == 10
      assert List.last(view.recent_events) == :agent_turn_started
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/shem/tui/agent_view_test.exs --seed 0
```

Expected: compile error — module does not exist.

- [ ] **Step 3: Create lib/shem/tui/agent_view.ex**

```elixir
defmodule Shem.TUI.AgentView do
  defstruct [
    :agent_name,
    status: :running,
    turn_count: 0,
    max_turns: 20,
    current_reasoning: nil,
    last_tool_call: nil,
    history: [],
    recent_events: []
  ]

  @type t :: %__MODULE__{
          agent_name: String.t() | nil,
          status: :running | :done | :error,
          turn_count: non_neg_integer(),
          max_turns: pos_integer(),
          current_reasoning: String.t() | nil,
          last_tool_call: %{name: String.t(), args: map(), result: String.t() | nil} | nil,
          history: [%{turn: non_neg_integer(), tool: String.t() | nil}],
          recent_events: [atom()]
        }

  @spec build(String.t()) :: {:ok, t()} | :not_found
  def build(session_id) do
    case Shem.EventLog.events(session_id) do
      {:ok, []} ->
        :not_found

      {:ok, events} ->
        view = Enum.reduce(events, %__MODULE__{}, &fold_event/2)
        recent = events |> Enum.map(& &1.type) |> Enum.take(-10)
        {:ok, %{view | recent_events: recent}}

      _ ->
        :not_found
    end
  end

  defp fold_event(event, acc) do
    case event.type do
      :agent_started ->
        %{acc | max_turns: event.payload[:max_turns] || 20}

      :agent_turn_started ->
        %{acc | turn_count: event.payload[:turn] || acc.turn_count + 1, last_tool_call: nil}

      :llm_call_completed ->
        content = event.payload[:content] || ""
        %{acc | current_reasoning: content}

      :agent_tool_called ->
        %{
          acc
          | last_tool_call: %{
              name: event.payload[:tool],
              args: event.payload[:args] || %{},
              result: nil
            }
        }

      :agent_tool_result ->
        case acc.last_tool_call do
          nil -> acc
          tc -> %{acc | last_tool_call: %{tc | result: event.payload[:result]}}
        end

      :agent_turn_completed ->
        tool_name = if acc.last_tool_call, do: acc.last_tool_call.name, else: nil
        entry = %{turn: acc.turn_count, tool: tool_name}
        %{acc | history: acc.history ++ [entry], last_tool_call: nil}

      :agent_done ->
        %{acc | status: :done}

      :agent_error ->
        %{acc | status: :error}

      _ ->
        acc
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/tui/agent_view_test.exs --seed 0
```

Expected: all 9 tests pass.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: all tests passing.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/agent_view.ex test/shem/tui/agent_view_test.exs
git commit -m "feat: Shem.TUI.AgentView — EventLog events to display struct"
```

---

## Task 6: TUI App wiring

Adds new model fields and handlers to `app.ex`. Wires CommandDispatch, AgentView, and agent list polling into the existing tick/event loop.

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Modify: `test/shem/tui/app_test.exs`

- [ ] **Step 1: Write the failing tests**

Open `test/shem/tui/app_test.exs` and add a new describe block at the end (before the final `end`):

```elixir
describe "init/1 — new Phase 9 fields" do
  test "model has agents list defaulting to empty" do
    model = App.init(%{})
    assert model.agents == []
  end

  test "model has focused_agent defaulting to nil" do
    model = App.init(%{})
    assert model.focused_agent == nil
  end

  test "model has agent_view defaulting to nil" do
    model = App.init(%{})
    assert model.agent_view == nil
  end

  test "model has command_error defaulting to nil" do
    model = App.init(%{})
    assert model.command_error == nil
  end
end

describe "update/2 — Tab key cycles focused_agent" do
  test "Tab with no agents is a no-op" do
    model = App.init(%{})
    result = App.update(model, {:event, %{ch: 0, key: 9}})
    assert result.focused_agent == nil
  end

  test "Tab with agents and no focused agent focuses first" do
    model = %{App.init(%{}) | agents: [%{name: "a1", status: :running, session_id: "s1", turn_count: 0}]}
    result = App.update(model, {:event, %{ch: 0, key: 9}})
    assert result.focused_agent == "a1"
  end

  test "Tab cycles to next agent" do
    agents = [
      %{name: "a1", status: :running, session_id: "s1", turn_count: 0},
      %{name: "a2", status: :done, session_id: "s2", turn_count: 3}
    ]
    model = %{App.init(%{}) | agents: agents, focused_agent: "a1"}
    result = App.update(model, {:event, %{ch: 0, key: 9}})
    assert result.focused_agent == "a2"
  end

  test "Tab wraps around from last agent to first" do
    agents = [
      %{name: "a1", status: :running, session_id: "s1", turn_count: 0},
      %{name: "a2", status: :done, session_id: "s2", turn_count: 3}
    ]
    model = %{App.init(%{}) | agents: agents, focused_agent: "a2"}
    result = App.update(model, {:event, %{ch: 0, key: 9}})
    assert result.focused_agent == "a1"
  end

  test "Tab is ignored when command buffer is active" do
    agents = [%{name: "a1", status: :running, session_id: "s1", turn_count: 0}]
    model = %{App.init(%{}) | agents: agents, command_buffer: "/some"}
    result = App.update(model, {:event, %{ch: 0, key: 9}})
    assert result.focused_agent == nil
  end
end
```

- [ ] **Step 2: Run to confirm new test failures**

```bash
mix test test/shem/tui/app_test.exs --seed 0
```

Expected: the new `init/1` tests fail (fields don't exist yet), Tab tests fail.

- [ ] **Step 3: Update lib/shem/tui/app.ex — add aliases and constants**

Replace the top of `lib/shem/tui/app.ex` through the `@space` constant line:

```elixir
defmodule Shem.TUI.App do
  @behaviour Ratatouille.App

  alias Shem.TUI.Views.{Dashboard, Interactive}
  alias Shem.TUI.{CommandDispatch, AgentView}
  alias Ratatouille.Runtime.Subscription

  @esc 27
  @backspace 127
  @space ?\s
  @enter 13
  @tab 9
```

- [ ] **Step 4: Update init/1 to add new fields**

Replace the `init/1` function:

```elixir
@impl true
def init(_context) do
  %{
    mode: :dashboard,
    command_buffer: "",
    paused: false,
    event_log_stats: %{sessions: 0, total_events: 0},
    tool_count: 0,
    mcp_client_count: 0,
    mcp_outbound_count: 0,
    cluster_node_count: 1,
    agents: [],
    focused_agent: nil,
    agent_view: nil,
    command_error: nil
  }
end
```

- [ ] **Step 5: Add Enter and Tab handlers to update/2**

In `lib/shem/tui/app.ex`, inside the `update/2` function's `case msg do` block, add new clauses before the `:tick` clause:

```elixir
{:event, %{key: @tab}} when model.command_buffer == "" ->
  case model.agents do
    [] ->
      model

    agents ->
      names = Enum.map(agents, & &1.name)

      next =
        case model.focused_agent do
          nil ->
            List.first(names)

          current ->
            idx = Enum.find_index(names, &(&1 == current)) || 0
            Enum.at(names, rem(idx + 1, length(names)))
        end

      %{model | focused_agent: next}
  end

{:event, %{key: @enter}} when model.command_buffer != "" ->
  case CommandDispatch.parse(model.command_buffer) do
    {:start_agent, preset_name, task} ->
      case Shem.Agent.start_with_preset(preset_name, task) do
        {:ok, name} ->
          %{model | command_buffer: "", focused_agent: name, command_error: nil}

        {:error, reason} ->
          %{model | command_error: "failed to start agent: #{inspect(reason)}"}
      end

    {:stop_agent} ->
      if model.focused_agent, do: Shem.Agent.stop(model.focused_agent)
      %{model | command_buffer: "", command_error: nil}

    {:list_agents} ->
      %{model | command_buffer: "", command_error: nil}

    {:error, reason} ->
      %{model | command_error: reason}
  end
```

- [ ] **Step 6: Update the :tick clause to refresh agents and agent_view**

Replace the existing `:tick ->` clause with:

```elixir
:tick ->
  %{
    model
    | event_log_stats: safe_stats(),
      tool_count: safe_tool_count(),
      mcp_client_count: safe_mcp_count(),
      mcp_outbound_count: safe_mcp_outbound_count(),
      cluster_node_count: safe_cluster_count(),
      agents: safe_agent_list(),
      agent_view: safe_agent_view(model.focused_agent)
  }
```

- [ ] **Step 7: Add the new private helpers**

At the bottom of `lib/shem/tui/app.ex`, before the final `end`, add:

```elixir
defp safe_agent_list do
  try do
    Horde.DynamicSupervisor.which_children(Shem.AgentSupervisor)
    |> Enum.filter(fn {_id, pid, _, _} -> is_pid(pid) end)
    |> Enum.map(fn {id, pid, _, _} ->
      status =
        case GenServer.call(pid, :status, 100) do
          {:ok, s} -> s
          _ -> :unknown
        end

      session_id =
        case GenServer.call(pid, :session_id, 100) do
          s when is_binary(s) -> s
          _ -> nil
        end

      %{name: id, pid: pid, status: status, session_id: session_id, turn_count: 0}
    end)
  catch
    :exit, _ -> []
  end
end

defp safe_agent_view(nil), do: nil

defp safe_agent_view(name) do
  try do
    via = Shem.ProcessRegistry.via_tuple(name)

    case GenServer.whereis(via) do
      nil ->
        nil

      pid ->
        session_id = GenServer.call(pid, :session_id, 200)

        case AgentView.build(session_id) do
          {:ok, view} -> %{view | agent_name: name}
          :not_found -> nil
        end
    end
  catch
    :exit, _ -> nil
  end
end
```

- [ ] **Step 8: Run app tests**

```bash
mix test test/shem/tui/app_test.exs --seed 0
```

Expected: all tests pass, including the new init and Tab handler tests.

- [ ] **Step 9: Run full suite**

```bash
mix test
```

Expected: all tests passing.

- [ ] **Step 10: Commit**

```bash
git add lib/shem/tui/app.ex test/shem/tui/app_test.exs
git commit -m "feat: TUI App — agent list, Enter/Tab handlers, agent_view polling"
```

---

## Task 7: Interactive View — full replacement

Replaces the placeholder `Interactive` view with a live rendering from `model.agent_view`, `model.agents`, and `model.focused_agent`. Uses column(size: 8) + column(size: 4) split for turn card and event log.

**Files:**
- Modify: `lib/shem/tui/views/interactive.ex`
- Modify: `test/shem/tui/views/dashboard_test.exs` (check base_model helper)

- [ ] **Step 1: Check the dashboard test base_model helper**

```bash
cat test/shem/tui/views/dashboard_test.exs | head -30
```

Note the `base_model()` helper — it needs the new fields added in Task 6.

- [ ] **Step 2: Update base_model in dashboard_test.exs**

Find the `base_model()` function in `test/shem/tui/views/dashboard_test.exs` and add the new fields:

```elixir
defp base_model do
  %{
    mode: :dashboard,
    command_buffer: "",
    paused: false,
    event_log_stats: %{sessions: 0, total_events: 0},
    tool_count: 0,
    mcp_client_count: 0,
    mcp_outbound_count: 0,
    cluster_node_count: 1,
    agents: [],
    focused_agent: nil,
    agent_view: nil,
    command_error: nil
  }
end
```

- [ ] **Step 3: Replace lib/shem/tui/views/interactive.ex**

```elixir
defmodule Shem.TUI.Views.Interactive do
  import Ratatouille.View
  import Ratatouille.Constants, only: [color: 1, attribute: 1]

  def render(model) do
    view do
      row do
        column(size: 8) do
          render_turn_card(model)
        end

        column(size: 4) do
          render_event_log(model)
        end
      end

      row do
        column(size: 12) do
          render_agent_switcher(model)
        end
      end

      row do
        column(size: 12) do
          panel(title: prompt_title(model), color: prompt_color(model)) do
            label(
              content: prompt_content(model),
              color: color(:white)
            )

            label(
              content: if(model.command_error, do: "Error: #{model.command_error}", else: ""),
              color: color(:red)
            )
          end
        end
      end
    end
  end

  defp render_turn_card(%{agent_view: nil}) do
    panel(title: "Shem // Interactive · Agent Output", color: color(:cyan)) do
      label(content: "")
      label(
        content: "No active session.",
        attributes: [attribute(:bold)],
        color: color(:white)
      )
      label(content: "")
      label(
        content: "Type a task and press Enter to start an agent.",
        color: color(:cyan)
      )
      label(
        content: "Or use: /agent <preset> <task>",
        color: color(:cyan)
      )
      label(content: "")
      label(
        content: "Presets: general  coding  explore",
        color: color(:white)
      )
    end
  end

  defp render_turn_card(%{agent_view: view, focused_agent: name}) do
    status_str = status_label(view.status)
    title = "#{name} · turn #{view.turn_count}/#{view.max_turns} · #{status_str}"

    panel(title: title, color: status_color(view.status)) do
      label(
        content: "REASONING",
        attributes: [attribute(:bold)],
        color: color(:white)
      )

      label(
        content: truncate(view.current_reasoning || "waiting...", 200),
        color: color(:cyan)
      )

      label(content: "")

      label(
        content: "LAST TOOL CALL",
        attributes: [attribute(:bold)],
        color: color(:white)
      )

      case view.last_tool_call do
        nil ->
          label(content: "none", color: color(:white))

        tc ->
          label(content: "→ #{tc.name}", color: color(:green))
          label(content: truncate(inspect(tc.args), 120), color: color(:white))

          if tc.result do
            label(content: "← #{truncate(tc.result, 120)}", color: color(:white))
          end
      end

      label(content: "")

      label(
        content: "HISTORY",
        attributes: [attribute(:bold)],
        color: color(:white)
      )

      history_line =
        view.history
        |> Enum.map(fn %{turn: t, tool: tool} ->
          if tool, do: "t#{t}:#{tool}", else: "t#{t}:done"
        end)
        |> Enum.join("  ·  ")

      label(content: if(history_line == "", do: "no completed turns", else: history_line), color: color(:white))
    end
  end

  defp render_event_log(%{agent_view: nil}) do
    panel(title: "Event Log", color: color(:yellow)) do
      label(
        content: "No events yet.",
        attributes: [attribute(:bold)],
        color: color(:yellow)
      )
    end
  end

  defp render_event_log(%{agent_view: view}) do
    panel(title: "Event Log", color: color(:yellow)) do
      for event_type <- view.recent_events do
        label(content: to_string(event_type), color: color(:yellow))
      end
    end
  end

  defp render_agent_switcher(%{agents: []}) do
    panel(title: "Agents", color: color(:white)) do
      label(content: "No agents running.  Tab=cycle  /agent <preset> <task>=start", color: color(:white))
    end
  end

  defp render_agent_switcher(%{agents: agents, focused_agent: focused}) do
    panel(title: "Agents · Tab=cycle", color: color(:white)) do
      agent_line =
        agents
        |> Enum.map(fn a ->
          marker = if a.name == focused, do: "●", else: "○"
          "#{marker} #{a.name} [#{a.status}]"
        end)
        |> Enum.join("   ")

      label(content: agent_line, color: color(:cyan))
    end
  end

  defp prompt_title(%{paused: true}), do: "[ PAUSED — press SPACE to resume ]"
  defp prompt_title(%{command_buffer: "/" <> _ = buf}), do: "Command: #{buf}"
  defp prompt_title(_), do: "d=Dashboard  i=Interactive  Tab=cycle  /agent <preset> <task>  /stop  /agents"

  defp prompt_color(%{paused: true}), do: color(:red)
  defp prompt_color(_), do: color(:cyan)

  defp prompt_content(%{paused: true}), do: "PAUSED — press SPACE to resume."
  defp prompt_content(%{command_buffer: ""}), do: "> _"
  defp prompt_content(%{command_buffer: buf}), do: buf

  defp status_label(:running), do: "running"
  defp status_label(:done), do: "done"
  defp status_label(:error), do: "error"
  defp status_label(_), do: "unknown"

  defp status_color(:running), do: color(:cyan)
  defp status_color(:done), do: color(:green)
  defp status_color(:error), do: color(:red)
  defp status_color(_), do: color(:white)

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "…"
end
```

- [ ] **Step 4: Run the full test suite**

```bash
mix test
```

Expected: all tests pass. The Interactive view has no dedicated unit tests (it's a pure render function with no logic) — the existing TUI tests cover the model shape it receives.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/tui/views/interactive.ex test/shem/tui/views/dashboard_test.exs
git commit -m "feat: Interactive view — live turn card, event log, agent switcher"
```

---

## Done

All 7 tasks complete. Run the final suite:

```bash
mix test
```

Expected: all tests pass (327 + ~30 new ≈ 357+).

### Quick smoke test (optional, requires llama.cpp running)

```bash
SHEM_NO_TUI=1 mix run --no-halt -e '
config = %Shem.Agent.Config{
  task: "list the files in lib/shem/agent/",
  system_prompt: "You are a helpful assistant.",
  max_turns: 3
}
{:ok, name} = Shem.Agent.start(config)
IO.inspect(Shem.Agent.await(name, 30_000))
'
```

To test from the TUI:
```bash
mix run --no-halt
```
Press `i` to enter interactive mode, type a task, press Enter.
