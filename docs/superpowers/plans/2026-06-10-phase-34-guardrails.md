# Phase 34: Guardrails Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Ctrl+K` instant kill and `/fence <path>` scope fence to make Shem safe for unsupervised use on real work.

**Architecture:** A pure `Shem.Guardrails` module holds all guardrail logic. `Agent.Config` gains a `fence` field. `ToolDispatch.execute/3` receives fence+backend via opts and calls `check_fence/4` before dispatching `read_file`, `list_dir`, and `shell`. The TUI adds a `Ctrl+K` kill binding, `/fence` command, and a status line fence display.

**Tech Stack:** Elixir/OTP — pure module, GenServer handle_call extension, Ratatouille TUI event pattern-matching.

---

## File Map

| Action | Path |
|--------|------|
| Create | `lib/shem/guardrails.ex` |
| Create | `test/shem/guardrails_test.exs` |
| Modify | `lib/shem/agent.ex` — `Config` struct + `set_fence/2` |
| Modify | `lib/shem/agent/server.ex` — `set_fence` handle_call, `execute_tool_calls/5` |
| Modify | `lib/shem/agent/tool_dispatch.ex` — `execute/3` with fence opts |
| Modify | `lib/shem/tui/command_dispatch.ex` — `/fence` parse + `commands/0` |
| Modify | `lib/shem/tui/app.ex` — `Ctrl+K`, `/fence` dispatch, `active_fence` model field |
| Modify | `lib/shem/tui/views/interactive.ex` — fence in `prompt_title` |
| Modify | `test/shem/agent/tool_dispatch_test.exs` — fence integration tests |
| Modify | `test/shem/agent/server_test.exs` — `set_fence` tests |
| Modify | `test/shem/tui/command_dispatch_test.exs` — `/fence` parse tests |
| Modify | `test/shem/tui/app_test.exs` — `Ctrl+K` and `/fence` TUI tests |

---

## Task 1: `Shem.Guardrails` — pure module (TDD)

**Files:**
- Create: `lib/shem/guardrails.ex`
- Create: `test/shem/guardrails_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/guardrails_test.exs
defmodule Shem.GuardrailsTest do
  use ExUnit.Case, async: true

  alias Shem.Guardrails
  alias Shem.Lab.Executor.Backend

  describe "check_fence/4" do
    test "fence nil always returns :ok" do
      assert :ok = Guardrails.check_fence(nil, "read_file", %{"path" => "/anywhere"}, [])
    end

    test "path inside fence returns :ok" do
      fence = System.tmp_dir!()
      path = Path.join(fence, "subdir/file.txt")
      assert :ok = Guardrails.check_fence(fence, "read_file", %{"path" => path}, [])
    end

    test "path outside fence returns {:blocked, _}" do
      fence = Path.join(System.tmp_dir!(), "project")
      path = "/etc/passwd"
      assert {:blocked, reason} = Guardrails.check_fence(fence, "read_file", %{"path" => path}, [])
      assert reason =~ "scope fence"
    end

    test "list_dir path inside fence returns :ok" do
      fence = System.tmp_dir!()
      path = Path.join(fence, "subdir")
      assert :ok = Guardrails.check_fence(fence, "list_dir", %{"path" => path}, [])
    end

    test "list_dir path outside fence returns {:blocked, _}" do
      fence = Path.join(System.tmp_dir!(), "project")
      assert {:blocked, _} = Guardrails.check_fence(fence, "list_dir", %{"path" => "/etc"}, [])
    end

    test "relative path is expanded before check" do
      fence = File.cwd!()
      # relative path that resolves inside cwd
      assert :ok = Guardrails.check_fence(fence, "read_file", %{"path" => "lib/shem.ex"}, [])
    end

    test "relative path outside fence is blocked" do
      fence = Path.join(File.cwd!(), "lib")
      assert {:blocked, _} = Guardrails.check_fence(fence, "read_file", %{"path" => "test/test_helper.exs"}, [])
    end

    test "shell with container backend returns :ok regardless of fence" do
      fence = Path.join(System.tmp_dir!(), "project")
      assert :ok = Guardrails.check_fence(fence, "shell", %{"cmd" => "rm -rf /"}, [backend: Backend.Container])
    end

    test "shell with local backend returns {:blocked, _} when fence is active" do
      fence = System.tmp_dir!()
      assert {:blocked, _} = Guardrails.check_fence(fence, "shell", %{"cmd" => "ls"}, [backend: Backend.Local])
    end

    test "other tools (write_file, run_code) are not fenced" do
      fence = Path.join(System.tmp_dir!(), "project")
      assert :ok = Guardrails.check_fence(fence, "write_file", %{"path" => "/etc/passwd"}, [])
      assert :ok = Guardrails.check_fence(fence, "run_code", %{"source" => "IO.puts(:hi)"}, [])
    end

    test "symlink path is checked literally, not resolved" do
      fence = Path.join(System.tmp_dir!(), "project")
      # path looks like it's inside the fence but could be a symlink pointing outside — checked as-is
      inside_path = Path.join(fence, "link_to_etc")
      assert :ok = Guardrails.check_fence(fence, "read_file", %{"path" => inside_path}, [])
    end
  end

  describe "kill_session/1" do
    test "returns {:error, :not_found} for unknown agent" do
      assert {:error, :not_found} = Guardrails.kill_session("nonexistent_agent_xyz")
    end
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/guardrails_test.exs
```

Expected: compilation error — `Shem.Guardrails` does not exist.

- [ ] **Step 3: Implement `Shem.Guardrails`**

```elixir
# lib/shem/guardrails.ex
defmodule Shem.Guardrails do
  alias Shem.Lab.Executor.Backend

  @fenced_tools ~w[read_file list_dir]

  @spec check_fence(nil | String.t(), String.t(), map(), keyword()) :: :ok | {:blocked, String.t()}
  def check_fence(nil, _tool, _args, _opts), do: :ok

  def check_fence(_fence, "shell", _args, opts) do
    if Keyword.get(opts, :backend) == Backend.Container,
      do: :ok,
      else: {:blocked, "shell is restricted inside a scope fence on a local executor"}
  end

  def check_fence(fence, tool, args, _opts) when tool in @fenced_tools do
    path = args["path"] || ""
    expanded = Path.expand(path)
    fence_abs = Path.expand(fence)

    if String.starts_with?(expanded, fence_abs) do
      :ok
    else
      {:blocked, "blocked by scope fence: #{path} is outside #{fence}"}
    end
  end

  def check_fence(_fence, _tool, _args, _opts), do: :ok

  @spec kill_session(String.t()) :: :ok | {:error, :not_found}
  def kill_session(name), do: Shem.Agent.stop(name)
end
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
mix test test/shem/guardrails_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/guardrails.ex test/shem/guardrails_test.exs
git commit -m "feat: add Shem.Guardrails pure module — check_fence/4 and kill_session/1"
```

---

## Task 2: `Agent.Config.fence` field

**Files:**
- Modify: `lib/shem/agent.ex` (lines 4–18)

- [ ] **Step 1: Write the failing test**

Add to `test/shem/agent_test.exs` inside the `describe "Config"` block (or create one):

```elixir
describe "Config" do
  test "fence defaults to nil" do
    config = %Shem.Agent.Config{task: "t", system_prompt: "s"}
    assert config.fence == nil
  end

  test "fence can be set to an absolute path" do
    config = %Shem.Agent.Config{task: "t", system_prompt: "s", fence: "/home/user/proj"}
    assert config.fence == "/home/user/proj"
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/agent_test.exs --only describe:"Config"
```

Expected: `** (KeyError) key :fence not found`.

- [ ] **Step 3: Add `fence` to `Agent.Config`**

In `lib/shem/agent.ex`, change the `Config` defstruct and `@type`:

```elixir
defmodule Config do
  @enforce_keys [:task, :system_prompt]
  defstruct [:task, :system_prompt, model: :default, tools: [], max_turns: 20,
             spawn_depth: 0, conversational: false, project_context: nil, fence: nil]

  @type t :: %__MODULE__{
          task: String.t(),
          system_prompt: String.t(),
          model: atom(),
          tools: [String.t()],
          max_turns: pos_integer(),
          spawn_depth: non_neg_integer(),
          project_context: Shem.Context.Project.t() | nil,
          conversational: boolean(),
          fence: String.t() | nil
        }
end
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
mix test test/shem/agent_test.exs
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/agent.ex test/shem/agent_test.exs
git commit -m "feat: add fence field to Agent.Config"
```

---

## Task 3: `Agent.set_fence/2` and `Agent.Server` handle_call

**Files:**
- Modify: `lib/shem/agent.ex` — add `set_fence/2`
- Modify: `lib/shem/agent/server.ex` — add `handle_call({:set_fence, ...})`
- Modify: `test/shem/agent/server_test.exs` — add tests

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/agent/server_test.exs`:

```elixir
describe "set_fence/2" do
  test "sets fence on running agent config" do
    {:ok, name} = Agent.start(%Config{task: "t", system_prompt: "s"})
    on_exit(fn -> Agent.stop(name) end)

    assert :ok = Agent.set_fence(name, "/home/user/proj")
    # fence is internal to config — verify via a round-trip: set then clear
    assert :ok = Agent.set_fence(name, nil)
  end

  test "returns {:error, :not_found} for unknown agent" do
    assert {:error, :not_found} = Agent.set_fence("no_such_agent_xyz", "/tmp")
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/agent/server_test.exs --only describe:"set_fence/2"
```

Expected: `** (UndefinedFunctionError) function Shem.Agent.set_fence/2`.

- [ ] **Step 3: Add `set_fence/2` to `Agent` public API**

In `lib/shem/agent.ex`, add after `session_id/1`:

```elixir
@spec set_fence(String.t(), String.t() | nil) :: :ok | {:error, :not_found}
def set_fence(name, path) do
  case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
    nil -> {:error, :not_found}
    pid -> GenServer.call(pid, {:set_fence, path})
  end
end
```

- [ ] **Step 4: Add `handle_call` to `Agent.Server`**

In `lib/shem/agent/server.ex`, add a new `handle_call` clause. Find the other `handle_call` clauses and add alongside them:

```elixir
def handle_call({:set_fence, path}, _from, state) do
  {:reply, :ok, %{state | config: %{state.config | fence: path}}}
end
```

- [ ] **Step 5: Run tests**

```bash
mix test test/shem/agent/server_test.exs
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/agent.ex lib/shem/agent/server.ex test/shem/agent/server_test.exs
git commit -m "feat: Agent.set_fence/2 — update Config.fence on running agent"
```

---

## Task 4: `ToolDispatch.execute/3` with fence check

**Files:**
- Modify: `lib/shem/agent/tool_dispatch.ex` — `execute/2` → `execute/3`
- Modify: `lib/shem/agent/server.ex` — `execute_tool_calls/4` → `/5`
- Modify: `test/shem/agent/tool_dispatch_test.exs` — fence integration tests

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/agent/tool_dispatch_test.exs`:

```elixir
describe "execute/3 — fence" do
  setup do
    {:ok, tmp} = Briefly.create(type: :directory)
    fence = tmp
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, fence: fence}
  end

  test "read_file inside fence succeeds", %{fence: fence} do
    path = Path.join(fence, "test.txt")
    File.write!(path, "hello")
    call = %{name: "read_file", args: %{"path" => path}, id: "1"}
    manifest = ToolDispatch.build_manifest(%Config{task: "t", system_prompt: "s"})
    assert {:ok, "hello"} = ToolDispatch.execute(call, manifest, fence: fence, backend: Shem.Lab.Executor.Backend.Local)
  end

  test "read_file outside fence returns error tuple", %{fence: fence} do
    call = %{name: "read_file", args: %{"path" => "/etc/hostname"}, id: "1"}
    manifest = ToolDispatch.build_manifest(%Config{task: "t", system_prompt: "s"})
    assert {:error, reason} = ToolDispatch.execute(call, manifest, fence: fence, backend: Shem.Lab.Executor.Backend.Local)
    assert reason =~ "scope fence"
  end

  test "list_dir outside fence returns error tuple", %{fence: fence} do
    call = %{name: "list_dir", args: %{"path" => "/etc"}, id: "1"}
    manifest = ToolDispatch.build_manifest(%Config{task: "t", system_prompt: "s"})
    assert {:error, reason} = ToolDispatch.execute(call, manifest, fence: fence, backend: Shem.Lab.Executor.Backend.Local)
    assert reason =~ "scope fence"
  end

  test "shell with container backend is not fenced", %{fence: fence} do
    call = %{name: "shell", args: %{"cmd" => "echo hi"}, id: "1"}
    manifest = ToolDispatch.build_manifest(%Config{task: "t", system_prompt: "s"})
    # container backend — fence does not block
    assert {:ok, _} = ToolDispatch.execute(call, manifest, fence: fence, backend: Shem.Lab.Executor.Backend.Container)
  end

  test "execute/2 (no opts) still works — fence defaults to nil" do
    call = %{name: "list_tools", args: %{}, id: "1"}
    manifest = ToolDispatch.build_manifest(%Config{task: "t", system_prompt: "s"})
    assert {:ok, _} = ToolDispatch.execute(call, manifest)
  end
end
```

Note: the shell+container test assumes a container runtime is available; skip with `@tag :skip` if not available in CI. The container test calls actual podman/docker — if you want a pure unit test, add `run_fn:` opt injection (already supported in `Backend.Container`). For the plan, keep it simple — the pure blocking logic is tested in `GuardrailsTest`.

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/agent/tool_dispatch_test.exs --only describe:"execute/3 — fence"
```

Expected: compilation error or function_clause — `execute/3` with opts doesn't exist yet.

- [ ] **Step 3: Update `ToolDispatch.execute` to `execute/3`**

In `lib/shem/agent/tool_dispatch.ex`, change the two `execute` function heads:

```elixir
@spec execute(%{name: String.t(), args: map()}, [map()], keyword()) ::
        {:ok, String.t()} | {:error, String.t()}
def execute(call, manifest, opts \\ [])

def execute(%{name: "list_tools"}, manifest, _opts) do
  lines = Enum.map(manifest, fn %{name: n, description: d} -> "- #{n}: #{d}" end)
  {:ok, "Available tools:\n" <> Enum.join(lines, "\n")}
end

def execute(%{name: name, args: args}, manifest, opts) do
  case Enum.find(manifest, &(&1.name == name)) do
    nil ->
      {:error, "unknown tool: #{name}"}

    %{source: :builtin} ->
      with :ok <- Shem.Guardrails.check_fence(opts[:fence], name, args, backend: opts[:backend]) do
        dispatch_builtin(name, args)
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

- [ ] **Step 4: Update `execute_tool_calls` in `Agent.Server` to pass fence and backend**

In `lib/shem/agent/server.ex`, change the function signature and call site:

Change the call at line ~125:
```elixir
history = execute_tool_calls(calls, manifest, history, state.session_id, state.config)
```

Change the function definition:
```elixir
defp execute_tool_calls(calls, manifest, history, session_id, config) do
  backend = Application.get_env(:shem, :resolved_executor_backend, Shem.Lab.Executor.Backend.Local)
  opts = [fence: config.fence, backend: backend]

  Enum.reduce(calls, history, fn call, acc ->
    EventLog.append(session_id, :agent_tool_called, %{tool: call.name, args: call.args})

    result_str =
      case ToolDispatch.execute(call, manifest, opts) do
        {:ok, result} -> result
        {:error, reason} -> "Error: #{reason}"
      end

    EventLog.append(session_id, :agent_tool_result, %{tool: call.name, result: result_str})
    acc ++ [%{role: :tool, tool_call_id: call.id, content: "Tool result (#{call.name}): #{result_str}"}]
  end)
end
```

- [ ] **Step 5: Run the full test suite to confirm nothing regressed**

```bash
mix test
```

Expected: all existing tests pass, new fence tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex lib/shem/agent/server.ex test/shem/agent/tool_dispatch_test.exs
git commit -m "feat: ToolDispatch.execute/3 — fence check via Guardrails before builtin dispatch"
```

---

## Task 5: `CommandDispatch` — `/fence` command parsing

**Files:**
- Modify: `lib/shem/tui/command_dispatch.ex`
- Modify: `test/shem/tui/command_dispatch_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/tui/command_dispatch_test.exs`:

```elixir
describe "parse/1 — /fence command" do
  test "/fence <relative path> returns {:fence_set, absolute_path}" do
    {:fence_set, path} = CommandDispatch.parse("/fence src/auth")
    assert Path.type(path) == :absolute
    assert String.ends_with?(path, "src/auth")
  end

  test "/fence /absolute/path returns {:fence_set, path}" do
    assert {:fence_set, "/home/user/proj"} = CommandDispatch.parse("/fence /home/user/proj")
  end

  test "/fence clear returns {:fence_clear}" do
    assert {:fence_clear} = CommandDispatch.parse("/fence clear")
  end

  test "/fence with no args returns {:fence_show}" do
    assert {:fence_show} = CommandDispatch.parse("/fence")
  end

  test "/fence multi-word path is joined" do
    {:fence_set, path} = CommandDispatch.parse("/fence /home/user/my project")
    assert String.ends_with?(path, "my project")
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/tui/command_dispatch_test.exs --only describe:"/fence command"
```

Expected: all 5 tests fail — `{:error, "unknown command: /fence"}`.

- [ ] **Step 3: Add `/fence` to `CommandDispatch.parse/1`**

Update the `@spec` return type to add:

```elixir
| {:fence_set, String.t()}
| {:fence_clear}
| {:fence_show}
```

Add these clauses to the `case parts do` block in `parse("/" <> rest)`, before the `_` catchall:

```elixir
["fence"] ->
  {:fence_show}

["fence", "clear"] ->
  {:fence_clear}

["fence" | path_parts] ->
  {:fence_set, Path.expand(Enum.join(path_parts, " "))}
```

- [ ] **Step 4: Add `/fence` to `commands/0`**

In `commands/0`, add (before the closing `]`):

```elixir
{"/fence <path>", "Restrict agent file access to a directory"},
{"/fence clear", "Remove the active scope fence"},
{"/fence", "Show the current scope fence"},
```

- [ ] **Step 5: Run tests**

```bash
mix test test/shem/tui/command_dispatch_test.exs
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/command_dispatch.ex test/shem/tui/command_dispatch_test.exs
git commit -m "feat: CommandDispatch /fence command — set, clear, show"
```

---

## Task 6: TUI — `Ctrl+K` kill, `/fence` dispatch, `active_fence` model field

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Modify: `test/shem/tui/app_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/tui/app_test.exs` (requires the `setup_all` `Welcome.mark_welcomed()` already present in that file):

```elixir
describe "update/2 — Ctrl+K kill" do
  @ctrl_k 11

  test "with active agent: stops agent and sets command_output" do
    model = %{App.init(%{}) | focused_agent: "fake_agent_xyz"}
    result = App.update(model, {:event, %{key: @ctrl_k}})
    assert result.focused_agent == nil
    assert result.command_output =~ "Agent stopped"
    assert result.active_fence == nil
  end

  test "with no active agent: no-op" do
    model = App.init(%{})
    result = App.update(model, {:event, %{key: @ctrl_k}})
    assert result == model
  end
end

describe "update/2 — /fence dispatch" do
  @enter 13

  test "/fence <path> sets active_fence and clears command_buffer" do
    model = %{App.init(%{}) | command_buffer: "/fence /tmp/proj"}
    result = App.update(model, {:event, %{key: @enter}})
    assert result.active_fence == "/tmp/proj"
    assert result.command_buffer == ""
    assert result.command_output =~ "fence"
  end

  test "/fence clear clears active_fence" do
    model = %{App.init(%{}) | command_buffer: "/fence clear", active_fence: "/tmp/proj"}
    result = App.update(model, {:event, %{key: @enter}})
    assert result.active_fence == nil
    assert result.command_output =~ "cleared"
  end

  test "/fence show with active fence displays path" do
    model = %{App.init(%{}) | command_buffer: "/fence", active_fence: "/tmp/proj"}
    result = App.update(model, {:event, %{key: @enter}})
    assert result.command_output =~ "/tmp/proj"
    assert result.command_buffer == ""
  end

  test "/fence show with no fence displays 'no fence active'" do
    model = %{App.init(%{}) | command_buffer: "/fence"}
    result = App.update(model, {:event, %{key: @enter}})
    assert result.command_output =~ "no fence active"
  end
end

describe "init/1" do
  test "model has active_fence field defaulting to nil" do
    model = App.init(%{})
    assert Map.has_key?(model, :active_fence)
    assert model.active_fence == nil
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/tui/app_test.exs --only describe:"Ctrl+K kill"
mix test test/shem/tui/app_test.exs --only describe:"/fence dispatch"
```

Expected: `KeyError: key :active_fence not found`.

- [ ] **Step 3: Add `active_fence` to model and `@ctrl_k` constant**

In `lib/shem/tui/app.ex`:

After `@arrow_down 65516`, add:

```elixir
@ctrl_k 11
```

In `init/1`, add `active_fence: nil` to the returned map (alongside other fields like `shadow_band`):

```elixir
active_fence: nil,
```

- [ ] **Step 4: Add `Ctrl+K` handler**

In `App.update/2`, add after the history mode block (before `# --- Normal mode ---`):

```elixir
# --- Kill (Ctrl+K) ---
{:event, %{key: @ctrl_k}} ->
  case model.focused_agent do
    nil -> model
    name ->
      Shem.Guardrails.kill_session(name)
      %{model |
        focused_agent: nil,
        active_fence: nil,
        command_output: "Agent stopped — use /history to branch from a prior event.",
        command_error: nil
      }
  end
```

- [ ] **Step 5: Add `/fence` dispatch clauses to the Enter handler**

In `App.update/2`, inside the `case CommandDispatch.parse(model.command_buffer) do` block, add before `{:error, reason}`:

```elixir
{:fence_set, path} ->
  if model.focused_agent, do: Shem.Agent.set_fence(model.focused_agent, path)
  %{model | command_buffer: "", active_fence: path,
    command_output: "fence: #{path}", command_error: nil}

{:fence_clear} ->
  if model.focused_agent, do: Shem.Agent.set_fence(model.focused_agent, nil)
  %{model | command_buffer: "", active_fence: nil,
    command_output: "fence cleared", command_error: nil}

{:fence_show} ->
  output = if model.active_fence, do: "fence: #{model.active_fence}", else: "no fence active"
  %{model | command_buffer: "", command_output: output, command_error: nil}
```

- [ ] **Step 6: Run tests**

```bash
mix test test/shem/tui/app_test.exs
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/tui/app.ex test/shem/tui/app_test.exs
git commit -m "feat: TUI Ctrl+K kill and /fence dispatch — active_fence model field"
```

---

## Task 7: Interactive view — fence in status line

**Files:**
- Modify: `lib/shem/tui/views/interactive.ex`

No new tests needed — `prompt_title` is a private render helper; the TUI render path is covered by visual inspection. The existing app_test already verifies the model state; render helpers are not unit-tested in this codebase.

- [ ] **Step 1: Add fence clause to `prompt_title`**

In `lib/shem/tui/views/interactive.ex`, update `prompt_title` — add a new clause between the command buffer clause and the default:

```elixir
defp prompt_title(%{paused: true}), do: "[ PAUSED — press SPACE to resume ]"
defp prompt_title(%{command_buffer: "/" <> _ = buf}), do: "Command: #{buf}"
defp prompt_title(%{active_fence: fence}) when not is_nil(fence),
  do: "[fence: #{fence}]  d=Dashboard  Tab=cycle  /fence clear=remove fence"
defp prompt_title(_), do: "d=Dashboard  i=Interactive  Tab=cycle  /agent <preset> <task>  /stop  /agents"
```

- [ ] **Step 2: Run full test suite**

```bash
mix test
```

Expected: all tests pass, count increases from 813.

- [ ] **Step 3: Commit**

```bash
git add lib/shem/tui/views/interactive.ex
git commit -m "feat: show active fence in TUI interactive status line"
```

---

## Task 8: Final verification

- [ ] **Step 1: Run full test suite one more time**

```bash
mix test
```

Expected: all tests pass, no regressions.

- [ ] **Step 2: Verify compile in prod mode**

```bash
MIX_ENV=prod mix compile
```

Expected: no errors or warnings.

- [ ] **Step 3: Confirm test count increased**

Test count should be at least 830+ (adding ~17+ new tests across all tasks).

- [ ] **Step 4: Final commit if anything outstanding**

```bash
git status
```

If clean, done. If any untracked files remain, stage and commit them.
