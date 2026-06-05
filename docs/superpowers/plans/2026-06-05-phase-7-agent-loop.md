# Phase 7: Agent Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Shem's existing primitives (LLM driver, EventLog, MCP client, Lab sandbox) into an autonomous ReAct agent loop that can reason, invoke tools, and write/graduate its own Elixir tools mid-run.

**Architecture:** `Shem.Agent.Server` is a `:temporary` GenServer owning conversation state; it drives the loop via `handle_info(:run_turn)`. Pure modules `Turn` and `ToolDispatch` handle the stateless logic — prompt building, response parsing, tool routing. `AgentSupervisor` is updated to start `Agent.Server` children.

**Tech Stack:** Elixir/OTP, Jason (already a dep), `Shem.LLM`, `Shem.EventLog`, `Shem.MCP.Client`, `Shem.Lab.{Executor, GraduationGate, Registry}`.

---

## File Map

**Create:**
- `lib/shem/agent.ex` — `%Agent.Config{}` struct + public API: `start/1`, `stop/1`, `status/1`, `await/2`
- `lib/shem/agent/server.ex` — GenServer: state machine, loop, EventLog events, circuit breakers
- `lib/shem/agent/turn.ex` — pure: `step/4`, `build_prompt/3`, `parse_response/1`
- `lib/shem/agent/tool_dispatch.ex` — built-in manifest, built-in handlers, Lab/MCP routing

**Modify:**
- `lib/shem/agent_supervisor.ex` — update `start_agent/2` to accept `%Agent.Config{}` instead of bare `init_fn`; change restart to `:temporary`
- `test/shem/agent_supervisor_test.exs` — update for new API and `:temporary` restart semantics

**Create (tests):**
- `test/shem/agent/turn_test.exs`
- `test/shem/agent/tool_dispatch_test.exs`
- `test/shem/agent/server_test.exs`

---

## Task 1: `%Shem.Agent.Config{}` struct and public API skeleton

**Files:**
- Create: `lib/shem/agent.ex`

- [ ] **Step 1: Write the failing test**

Create `test/shem/agent/turn_test.exs` with just the module stub (we'll add to it in Task 2), then write a config test at the top of `test/shem/agent/server_test.exs`:

```elixir
# test/shem/agent/server_test.exs
defmodule Shem.Agent.ServerTest do
  use ExUnit.Case, async: false

  alias Shem.Agent

  setup do
    Shem.LLM.BudgetServer.reset()
    Shem.LLM.StubTransport.Server.reset()
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  describe "Agent.Config" do
    test "struct has required fields with defaults" do
      config = %Agent.Config{task: "do something", system_prompt: "you are helpful"}
      assert config.task == "do something"
      assert config.system_prompt == "you are helpful"
      assert config.model == :default
      assert config.tools == []
      assert config.max_turns == 20
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/shem/agent/server_test.exs --no-start 2>&1 | head -20
```
Expected: compilation error — `Shem.Agent` does not exist.

- [ ] **Step 3: Create `lib/shem/agent.ex`**

```elixir
defmodule Shem.Agent do
  alias Shem.{AgentSupervisor, ProcessRegistry}

  defmodule Config do
    @enforce_keys [:task, :system_prompt]
    defstruct [:task, :system_prompt, model: :default, tools: [], max_turns: 20]

    @type t :: %__MODULE__{
            task: String.t(),
            system_prompt: String.t(),
            model: atom(),
            tools: [String.t()],
            max_turns: pos_integer()
          }
  end

  @spec start(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def start(%Config{} = config) do
    name = "agent_" <> Base.encode16(:crypto.strong_rand_bytes(4))

    case AgentSupervisor.start_agent(name, config) do
      {:ok, _pid} -> {:ok, name}
      error -> error
    end
  end

  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(name) do
    case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
      nil -> {:error, :not_found}
      pid -> GenServer.stop(pid)
    end
  end

  @spec status(String.t()) :: {:ok, :running | :done | :error} | {:error, :not_found}
  def status(name) do
    case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :status)
    end
  end

  @spec await(String.t(), timeout()) :: {:ok, :done | :error} | {:error, :not_found | :timeout}
  def await(name, timeout \\ 5_000) do
    case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :await, timeout)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mix test test/shem/agent/server_test.exs --no-start 2>&1 | head -20
```
Expected: `1 test, 0 failures` (will fail to compile until `AgentSupervisor` is updated — see step below)

Note: if compilation fails because `AgentSupervisor.start_agent/2` doesn't accept a `Config.t()` yet, that's fine — stub the call or continue to Task 6 first, then return. Alternatively add a temporary typespec override for now. The test for Config struct itself doesn't call `start/1` so it should compile.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/agent.ex test/shem/agent/server_test.exs
git commit -m "feat: Shem.Agent.Config struct and public API skeleton"
```

---

## Task 2: `Shem.Agent.Turn` — `parse_response/1`

**Files:**
- Create: `lib/shem/agent/turn.ex`
- Create: `test/shem/agent/turn_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/shem/agent/turn_test.exs
defmodule Shem.Agent.TurnTest do
  use ExUnit.Case, async: true

  alias Shem.Agent.Turn

  describe "parse_response/1" do
    test "returns {:done, content} when no JSON tool call present" do
      assert {:done, "The answer is 42."} = Turn.parse_response("The answer is 42.")
    end

    test "extracts a single tool call embedded in prose" do
      content = ~s(I'll write a tool.\n{"tool": "write_tool", "args": {"name": "Foo"}}\nDone.)
      assert {:tool_calls, [call], ^content} = Turn.parse_response(content)
      assert call == %{tool: "write_tool", args: %{"name" => "Foo"}}
    end

    test "extracts multiple tool calls" do
      content = ~s({"tool": "run_code", "args": {"source": "x"}}\n{"tool": "list_tools", "args": {}})
      assert {:tool_calls, [c1, c2], ^content} = Turn.parse_response(content)
      assert c1.tool == "run_code"
      assert c2.tool == "list_tools"
    end

    test "ignores non-tool JSON objects" do
      content = ~s(Here is some JSON: {"key": "value"}. No tool call.)
      assert {:done, ^content} = Turn.parse_response(content)
    end

    test "handles tool call with no args key — defaults to empty map" do
      content = ~s({"tool": "list_tools"})
      assert {:tool_calls, [%{tool: "list_tools", args: %{}}], ^content} = Turn.parse_response(content)
    end

    test "returns {:done, content} on empty string" do
      assert {:done, ""} = Turn.parse_response("")
    end

    test "handles nested args object" do
      content = ~s({"tool": "write_tool", "args": {"name": "T", "source": "defmodule T do\\nend"}})
      assert {:tool_calls, [call], _} = Turn.parse_response(content)
      assert call.args["source"] =~ "defmodule"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/agent/turn_test.exs 2>&1 | head -10
```
Expected: compilation error — `Shem.Agent.Turn` does not exist.

- [ ] **Step 3: Create `lib/shem/agent/turn.ex` with `parse_response/1`**

```elixir
defmodule Shem.Agent.Turn do
  alias Shem.LLM
  alias Shem.LLM.{Request, Response}
  alias Shem.Agent.Config

  @spec parse_response(String.t()) ::
          {:tool_calls, [%{tool: String.t(), args: map()}], String.t()}
          | {:done, String.t()}
  def parse_response(content) do
    pattern = ~r/\{(?:[^{}]|\{[^{}]*\})*\}/

    tool_calls =
      Regex.scan(pattern, content)
      |> List.flatten()
      |> Enum.flat_map(fn json_str ->
        case Jason.decode(json_str) do
          {:ok, %{"tool" => tool, "args" => args}} when is_binary(tool) and is_map(args) ->
            [%{tool: tool, args: args}]

          {:ok, %{"tool" => tool}} when is_binary(tool) ->
            [%{tool: tool, args: %{}}]

          _ ->
            []
        end
      end)

    case tool_calls do
      [] -> {:done, content}
      calls -> {:tool_calls, calls, content}
    end
  end

  # build_prompt/3 and step/4 added in Tasks 3 and 4
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/agent/turn_test.exs 2>&1 | tail -5
```
Expected: `7 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add lib/shem/agent/turn.ex test/shem/agent/turn_test.exs
git commit -m "feat: Shem.Agent.Turn.parse_response/1 — extract JSON tool calls from prose"
```

---

## Task 3: `Turn.build_prompt/3`

**Files:**
- Modify: `lib/shem/agent/turn.ex`
- Modify: `test/shem/agent/turn_test.exs`

The manifest is a list of `%{name: String.t(), description: String.t(), source: term()}` entries. `build_prompt/3` takes `(system_prompt, tools_manifest, history)` and returns a single string the LLM completes from.

History entries: `%{role: :user | :assistant | :tool, content: String.t()}`. Tool entries have their content pre-formatted as `"Tool result (name): result"` — rendered verbatim. The prompt ends with `"\nAssistant:"` to cue completion.

- [ ] **Step 1: Add tests for `build_prompt/3`**

Append to the `describe` blocks in `test/shem/agent/turn_test.exs`:

```elixir
  describe "build_prompt/3" do
    @manifest [
      %{name: "list_tools", description: "List tools.", source: :builtin},
      %{name: "run_code", description: "Run code.", source: :builtin}
    ]

    test "includes system prompt" do
      prompt = Turn.build_prompt("Be helpful.", @manifest, [%{role: :user, content: "task"}])
      assert prompt =~ "Be helpful."
    end

    test "includes tool names and descriptions in manifest section" do
      prompt = Turn.build_prompt("sys", @manifest, [%{role: :user, content: "task"}])
      assert prompt =~ "list_tools"
      assert prompt =~ "List tools."
      assert prompt =~ "run_code"
    end

    test "renders user history entry" do
      prompt = Turn.build_prompt("sys", @manifest, [%{role: :user, content: "my task"}])
      assert prompt =~ "User: my task"
    end

    test "renders assistant history entry" do
      history = [
        %{role: :user, content: "task"},
        %{role: :assistant, content: "thinking..."}
      ]
      prompt = Turn.build_prompt("sys", @manifest, history)
      assert prompt =~ "Assistant: thinking..."
    end

    test "renders tool result verbatim" do
      history = [
        %{role: :user, content: "task"},
        %{role: :assistant, content: "calling"},
        %{role: :tool, content: "Tool result (run_code): 42"}
      ]
      prompt = Turn.build_prompt("sys", @manifest, history)
      assert prompt =~ "Tool result (run_code): 42"
    end

    test "ends with 'Assistant:' to cue next completion" do
      prompt = Turn.build_prompt("sys", @manifest, [%{role: :user, content: "task"}])
      assert String.ends_with?(String.trim_trailing(prompt), "Assistant:")
    end

    test "includes tool call JSON format instructions" do
      prompt = Turn.build_prompt("sys", @manifest, [%{role: :user, content: "t"}])
      assert prompt =~ ~s({"tool":)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/agent/turn_test.exs 2>&1 | grep "build_prompt"
```
Expected: test failures with `UndefinedFunctionError` for `build_prompt/3`.

- [ ] **Step 3: Add `build_prompt/3` to `lib/shem/agent/turn.ex`**

```elixir
  @spec build_prompt(String.t(), [map()], [map()]) :: String.t()
  def build_prompt(system_prompt, tools_manifest, history) do
    tool_lines =
      tools_manifest
      |> Enum.map(fn %{name: name, description: desc} -> "- #{name}: #{desc}" end)
      |> Enum.join("\n")

    history_lines =
      history
      |> Enum.map(fn
        %{role: :user, content: c} -> "User: #{c}"
        %{role: :assistant, content: c} -> "Assistant: #{c}"
        %{role: :tool, content: c} -> c
      end)
      |> Enum.join("\n\n")

    """
    #{system_prompt}

    You have access to tools. To call a tool, output JSON anywhere in your response:
    {"tool": "<name>", "args": {"key": "value"}}

    If a tool takes no args use: {"tool": "<name>", "args": {}}

    When your task is complete, respond with plain text only — no JSON tool call.

    Available tools:
    #{tool_lines}

    ---

    #{history_lines}

    Assistant:\
    """
  end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/agent/turn_test.exs 2>&1 | tail -5
```
Expected: `14 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add lib/shem/agent/turn.ex test/shem/agent/turn_test.exs
git commit -m "feat: Shem.Agent.Turn.build_prompt/3 — prompt builder for ReAct loop"
```

---

## Task 4: `Turn.step/4`

**Files:**
- Modify: `lib/shem/agent/turn.ex`
- Modify: `test/shem/agent/turn_test.exs`

`step/4` takes `(config, session_id, history, tools_manifest)`, calls `LLM.complete/1`, then delegates to `parse_response/1`. Tests use `StubTransport.Server` to control LLM output (already configured in test env).

- [ ] **Step 1: Add tests for `step/4`**

Append to `test/shem/agent/turn_test.exs`:

```elixir
  describe "step/4" do
    alias Shem.Agent.Config
    alias Shem.LLM.{Response, StubTransport}

    @config %Config{task: "do X", system_prompt: "be helpful"}
    @manifest [%{name: "list_tools", description: "list", source: :builtin}]

    setup do
      Shem.LLM.BudgetServer.reset()
      StubTransport.Server.reset()
      :ok
    end

    test "returns {:done, content} when LLM response has no tool call" do
      StubTransport.Server.push_response(
        {:ok, %Response{content: "The answer is 42.", tokens_used: 5, model: :default, latency_ms: 1}}
      )
      {:ok, sid} = Shem.EventLog.start_session()
      assert {:done, "The answer is 42."} =
               Turn.step(@config, sid, [%{role: :user, content: "do X"}], @manifest)
    end

    test "returns {:tool_calls, calls, raw} when LLM response contains tool call" do
      raw = ~s(I'll call a tool.\n{"tool": "list_tools", "args": {}})
      StubTransport.Server.push_response(
        {:ok, %Response{content: raw, tokens_used: 10, model: :default, latency_ms: 1}}
      )
      {:ok, sid} = Shem.EventLog.start_session()
      assert {:tool_calls, [%{tool: "list_tools", args: %{}}], ^raw} =
               Turn.step(@config, sid, [%{role: :user, content: "do X"}], @manifest)
    end

    test "returns {:error, reason} when LLM transport fails" do
      StubTransport.Server.push_response({:error, :no_stub_response})
      {:ok, sid} = Shem.EventLog.start_session()
      assert {:error, _} =
               Turn.step(@config, sid, [%{role: :user, content: "do X"}], @manifest)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/agent/turn_test.exs 2>&1 | grep "step"
```
Expected: `UndefinedFunctionError` for `step/4`.

- [ ] **Step 3: Add `step/4` to `lib/shem/agent/turn.ex`**

Add the following to the Turn module (after the existing functions):

```elixir
  @spec step(Config.t(), String.t(), [map()], [map()]) ::
          {:tool_calls, [%{tool: String.t(), args: map()}], String.t()}
          | {:done, String.t()}
          | {:error, term()}
  def step(%Config{} = config, session_id, history, tools_manifest) do
    prompt = build_prompt(config.system_prompt, tools_manifest, history)
    request = %Request{prompt: prompt, model: config.model, session_id: session_id}

    case LLM.complete(request) do
      {:ok, %Response{content: content}} -> parse_response(content)
      {:error, reason} -> {:error, reason}
    end
  end
```

Also add the missing alias at the top of the module if not already present:

```elixir
alias Shem.Agent.Config
```

- [ ] **Step 4: Run the full Turn test suite**

```bash
mix test test/shem/agent/turn_test.exs 2>&1 | tail -5
```
Expected: `17 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add lib/shem/agent/turn.ex test/shem/agent/turn_test.exs
git commit -m "feat: Shem.Agent.Turn.step/4 — one ReAct turn using LLM pipeline"
```

---

## Task 5: `Shem.Agent.ToolDispatch`

**Files:**
- Create: `lib/shem/agent/tool_dispatch.ex`
- Create: `test/shem/agent/tool_dispatch_test.exs`

Handles `build_manifest/1` and `execute/2`. `execute/2` dispatches to built-ins, graduated Lab tools, or MCP. Manifest entries: `%{name: String.t(), description: String.t(), source: :builtin | {:lab, id} | {:mcp, server}}`.

- [ ] **Step 1: Write failing tests**

```elixir
# test/shem/agent/tool_dispatch_test.exs
defmodule Shem.Agent.ToolDispatchTest do
  use ExUnit.Case, async: false

  alias Shem.Agent.{Config, ToolDispatch}

  @config %Config{task: "t", system_prompt: "s"}

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  describe "build_manifest/1" do
    test "includes all three built-ins" do
      manifest = ToolDispatch.build_manifest(@config)
      names = Enum.map(manifest, & &1.name)
      assert "write_tool" in names
      assert "run_code" in names
      assert "list_tools" in names
    end

    test "built-in entries have :builtin source" do
      manifest = ToolDispatch.build_manifest(@config)
      builtins = Enum.filter(manifest, &(&1.source == :builtin))
      assert length(builtins) == 3
    end

    test "includes graduated Lab tools with {:lab, id} source" do
      source = """
      defmodule DispatchTool1 do
        def run(_args), do: :ok
      end
      """
      test_src = """
      defmodule DispatchTool1Test do
        def run, do: :ok
      end
      """
      {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
      manifest = ToolDispatch.build_manifest(@config)
      assert Enum.any?(manifest, &(&1.source == {:lab, tool.id}))
    end
  end

  describe "execute/2 — list_tools built-in" do
    test "returns {:ok, formatted string} listing manifest tools" do
      manifest = [%{name: "foo", description: "does foo", source: :builtin}]
      assert {:ok, result} = ToolDispatch.execute(%{tool: "list_tools", args: %{}}, manifest)
      assert result =~ "foo"
      assert result =~ "does foo"
    end
  end

  describe "execute/2 — run_code built-in" do
    test "returns {:ok, result} for valid source with run/0" do
      source = """
      defmodule RunCodeTest1 do
        def run, do: 1 + 1
      end
      """
      manifest = [%{name: "run_code", description: "run", source: :builtin}]
      assert {:ok, "2"} = ToolDispatch.execute(%{tool: "run_code", args: %{"source" => source}}, manifest)
    end

    test "returns {:error, msg} for source with compile error" do
      manifest = [%{name: "run_code", description: "run", source: :builtin}]
      assert {:error, msg} =
               ToolDispatch.execute(
                 %{tool: "run_code", args: %{"source" => "this is not valid elixir !!!"}},
                 manifest
               )
      assert msg =~ "compile error"
    end
  end

  describe "execute/2 — write_tool built-in" do
    test "returns {:ok, 'graduated: name'} on valid source and tests" do
      source = """
      defmodule WriteToolTarget1 do
        def run(_args), do: :written
      end
      """
      test_src = """
      defmodule WriteToolTarget1Test do
        def run, do: :ok
      end
      """
      manifest = [%{name: "write_tool", description: "write", source: :builtin}]
      assert {:ok, "graduated: WriteToolTarget1"} =
               ToolDispatch.execute(
                 %{tool: "write_tool", args: %{"source" => source, "test_source" => test_src}},
                 manifest
               )
    end

    test "returns {:error, msg} when test fails" do
      source = """
      defmodule WriteToolTarget2 do
        def run(_args), do: :ok
      end
      """
      test_src = """
      defmodule WriteToolTarget2Test do
        def run, do: raise "intentional failure"
      end
      """
      manifest = [%{name: "write_tool", description: "write", source: :builtin}]
      assert {:error, msg} =
               ToolDispatch.execute(
                 %{tool: "write_tool", args: %{"source" => source, "test_source" => test_src}},
                 manifest
               )
      assert msg =~ "test failed"
    end
  end

  describe "execute/2 — Lab tool dispatch" do
    test "routes to a graduated tool and returns its result" do
      source = """
      defmodule LabDispatchTool1 do
        def run(args), do: Map.get(args, "x", 0) * 2
      end
      """
      test_src = """
      defmodule LabDispatchTool1Test do
        def run, do: :ok
      end
      """
      {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
      manifest = [%{name: tool.name, description: "", source: {:lab, tool.id}}]
      assert {:ok, "2"} =
               ToolDispatch.execute(%{tool: tool.name, args: %{"x" => 1}}, manifest)
    end
  end

  describe "execute/2 — unknown tool" do
    test "returns {:error, 'unknown tool: name'} when not in manifest" do
      assert {:error, "unknown tool: ghost"} =
               ToolDispatch.execute(%{tool: "ghost", args: %{}}, [])
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/agent/tool_dispatch_test.exs 2>&1 | head -10
```
Expected: compilation error — `Shem.Agent.ToolDispatch` does not exist.

- [ ] **Step 3: Create `lib/shem/agent/tool_dispatch.ex`**

```elixir
defmodule Shem.Agent.ToolDispatch do
  alias Shem.Agent.Config
  alias Shem.Lab
  alias Shem.MCP

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
    }
  ]

  @spec build_manifest(Config.t()) :: [map()]
  def build_manifest(%Config{tools: allowed_tools}) do
    lab_tools =
      Lab.Registry.all()
      |> Enum.map(fn tool ->
        %{
          name: tool.name,
          description: Map.get(tool.metadata, "description", "graduated tool: #{tool.name}"),
          source: {:lab, tool.id}
        }
      end)

    mcp_tools =
      MCP.Client.connected_servers()
      |> Enum.filter(&(&1.status == :ready))
      |> Enum.flat_map(fn %{name: server} ->
        case MCP.Client.list_tools(server) do
          {:ok, tools} ->
            tools
            |> then(fn ts ->
              if allowed_tools == [],
                do: ts,
                else: Enum.filter(ts, &(&1["name"] in allowed_tools))
            end)
            |> Enum.map(fn t ->
              %{name: t["name"], description: t["description"] || "", source: {:mcp, server}}
            end)

          _ ->
            []
        end
      end)

    @builtins ++ lab_tools ++ mcp_tools
  end

  @spec execute(%{tool: String.t(), args: map()}, [map()]) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(%{tool: "list_tools"}, manifest) do
    lines = Enum.map(manifest, fn %{name: n, description: d} -> "- #{n}: #{d}" end)
    {:ok, "Available tools:\n" <> Enum.join(lines, "\n")}
  end

  def execute(%{tool: name, args: args}, manifest) do
    case find_source(name, manifest) do
      :builtin -> dispatch_builtin(name, args)
      {:lab, id} -> dispatch_lab(id, args)
      {:mcp, server} -> dispatch_mcp(server, name, args)
      nil -> {:error, "unknown tool: #{name}"}
    end
  end

  defp find_source(name, manifest) do
    case Enum.find(manifest, &(&1.name == name)) do
      %{source: source} -> source
      nil -> nil
    end
  end

  defp dispatch_builtin("run_code", args) do
    source = args["source"] || ""
    timeout = args["timeout_ms"] || 5_000

    case Lab.Executor.run(source, fn mod -> mod.run() end, timeout: timeout) do
      {:ok, result} -> {:ok, inspect(result)}
      {:error, :compile, msg} -> {:error, "compile error: #{msg}"}
      {:error, :timeout} -> {:error, "timeout after #{timeout}ms"}
      {:error, :runtime, reason} -> {:error, "runtime error: #{inspect(reason)}"}
    end
  end

  defp dispatch_builtin("write_tool", args) do
    source = args["source"] || ""
    test_source = args["test_source"] || ""

    case Lab.GraduationGate.run(source, test_source) do
      {:ok, tool} -> {:ok, "graduated: #{tool.name}"}
      {:error, :compile, msg} -> {:error, "compile error: #{msg}"}
      {:error, :gate, reason} -> {:error, "test failed: #{inspect(reason)}"}
      {:error, :timeout} -> {:error, "graduation timed out"}
    end
  end

  defp dispatch_builtin(name, _args), do: {:error, "unknown built-in: #{name}"}

  defp dispatch_lab(id, args) do
    case Lab.Registry.lookup(id) do
      {:ok, tool} ->
        with :ok <- ensure_loaded(tool) do
          try do
            {:ok, inspect(tool.module.run(args))}
          rescue
            e -> {:error, "runtime error: #{Exception.message(e)}"}
          end
        end

      {:error, :not_found} ->
        {:error, "tool not found in registry: #{id}"}
    end
  end

  defp ensure_loaded(%{module: module, source: source}) do
    case :code.is_loaded(module) do
      false ->
        case Code.compile_string(source) do
          [{^module, bc} | _] ->
            case :code.load_binary(module, ~c"nofile", bc) do
              {:module, _} -> :ok
              {:error, _} -> {:error, "failed to load #{module}"}
            end

          _ ->
            {:error, "failed to compile #{module}"}
        end

      _ ->
        :ok
    end
  end

  defp dispatch_mcp(server, name, args) do
    case MCP.Client.call(server, name, args) do
      {:ok, result} -> {:ok, inspect(result)}
      {:error, reason} -> {:error, "mcp error: #{inspect(reason)}"}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/agent/tool_dispatch_test.exs 2>&1 | tail -5
```
Expected: `9 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex test/shem/agent/tool_dispatch_test.exs
git commit -m "feat: Shem.Agent.ToolDispatch — built-in tools and Lab/MCP routing"
```

---

## Task 6: `Shem.Agent.Server`

**Files:**
- Create: `lib/shem/agent/server.ex`

The Server is a GenServer owning: `config`, `history`, `session_id`, `turn_count`, `status`, `done_reason`, `awaiting`. Loop driven by `handle_info(:run_turn)`. Tests are in Task 7 (integration).

- [ ] **Step 1: Create `lib/shem/agent/server.ex`**

```elixir
defmodule Shem.Agent.Server do
  use GenServer

  alias Shem.Agent.{Config, Turn, ToolDispatch}
  alias Shem.{EventLog, LLM}

  def start_link({name, %Config{} = config, opts}) do
    GenServer.start_link(__MODULE__, {name, config}, opts)
  end

  # ── Client API ──────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  def handle_call(:await, _from, %{status: s} = state) when s in [:done, :error] do
    {:reply, {:ok, s}, state}
  end

  def handle_call(:await, from, state) do
    {:noreply, %{state | awaiting: [from | state.awaiting]}}
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  # ── Init ────────────────────────────────────────────────────────────────────

  @impl true
  def init({name, config}) do
    {:ok, session_id} = EventLog.start_session()

    EventLog.append(session_id, :agent_started, %{
      task: config.task,
      model: config.model,
      max_turns: config.max_turns
    })

    state = %{
      name: name,
      config: config,
      history: [%{role: :user, content: config.task}],
      session_id: session_id,
      turn_count: 0,
      status: :running,
      done_reason: nil,
      awaiting: []
    }

    send(self(), :run_turn)
    {:ok, state}
  end

  # ── Loop ────────────────────────────────────────────────────────────────────

  @impl true
  def handle_info(:run_turn, %{status: s} = state) when s != :running do
    {:noreply, state}
  end

  def handle_info(:run_turn, state) do
    cond do
      state.turn_count >= state.config.max_turns ->
        {:noreply, finish(state, :done, :max_turns_reached)}

      LLM.BudgetServer.check() == {:error, :budget_exhausted} ->
        {:noreply, finish(state, :done, :budget_exhausted)}

      true ->
        EventLog.append(state.session_id, :agent_turn_started, %{turn: state.turn_count + 1})
        manifest = ToolDispatch.build_manifest(state.config)

        case Turn.step(state.config, state.session_id, state.history, manifest) do
          {:done, answer} ->
            history = state.history ++ [%{role: :assistant, content: answer}]
            EventLog.append(state.session_id, :agent_turn_completed, %{
              turn: state.turn_count + 1,
              outcome: :done
            })
            {:noreply, finish(%{state | history: history, turn_count: state.turn_count + 1}, :done, :answer)}

          {:tool_calls, calls, raw} ->
            history = state.history ++ [%{role: :assistant, content: raw}]
            history = execute_tool_calls(calls, manifest, history, state.session_id)
            EventLog.append(state.session_id, :agent_turn_completed, %{
              turn: state.turn_count + 1,
              outcome: :tool_calls
            })
            new_state = %{state | history: history, turn_count: state.turn_count + 1}
            send(self(), :run_turn)
            {:noreply, new_state}

          {:error, reason} ->
            EventLog.append(state.session_id, :agent_error, %{reason: inspect(reason)})
            {:noreply, finish(state, :error, reason)}
        end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp execute_tool_calls(calls, manifest, history, session_id) do
    Enum.reduce(calls, history, fn call, acc ->
      EventLog.append(session_id, :agent_tool_called, %{tool: call.tool, args: call.args})

      result_str =
        case ToolDispatch.execute(call, manifest) do
          {:ok, result} -> result
          {:error, reason} -> "Error: #{reason}"
        end

      EventLog.append(session_id, :agent_tool_result, %{tool: call.tool, result: result_str})
      acc ++ [%{role: :tool, content: "Tool result (#{call.tool}): #{result_str}"}]
    end)
  end

  defp finish(state, status, reason) do
    EventLog.append(state.session_id, :agent_done, %{reason: reason})
    Enum.each(state.awaiting, fn from -> GenServer.reply(from, {:ok, status}) end)
    %{state | status: status, done_reason: reason, awaiting: []}
  end
end
```

- [ ] **Step 2: Verify the module compiles**

```bash
mix compile 2>&1 | grep -E "error|warning" | head -20
```
Expected: no errors. Warnings about unused variables are acceptable.

- [ ] **Step 3: Commit**

```bash
git add lib/shem/agent/server.ex
git commit -m "feat: Shem.Agent.Server — GenServer loop with circuit breakers and EventLog"
```

---

## Task 7: Update `AgentSupervisor` and run integration tests

**Files:**
- Modify: `lib/shem/agent_supervisor.ex`
- Modify: `test/shem/agent_supervisor_test.exs`
- Modify: `test/shem/agent/server_test.exs`

- [ ] **Step 1: Write new `AgentSupervisor` tests**

Replace `test/shem/agent_supervisor_test.exs` with:

```elixir
defmodule Shem.AgentSupervisorTest do
  use ExUnit.Case, async: false

  alias Shem.{Agent, AgentSupervisor}

  setup do
    Shem.LLM.BudgetServer.reset()
    Shem.LLM.StubTransport.Server.reset()
    :ok
  end

  test "start_agent/2 starts a live Agent.Server process" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Agent.Config{task: "t", system_prompt: "s"}
    name = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = AgentSupervisor.start_agent(name, config)
    assert Process.alive?(pid)
  end

  test "started agent registers in Shem.Registry under its name" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Agent.Config{task: "t", system_prompt: "s"}
    name = "test_agent_#{System.unique_integer([:positive])}"
    AgentSupervisor.start_agent(name, config)
    via = Shem.ProcessRegistry.via_tuple(name)
    assert is_pid(GenServer.whereis(via))
  end

  test "a crashed agent is NOT restarted (temporary restart)" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Agent.Config{task: "t", system_prompt: "s"}
    name = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = AgentSupervisor.start_agent(name, config)
    Process.exit(pid, :kill)
    Process.sleep(100)
    via = Shem.ProcessRegistry.via_tuple(name)
    assert GenServer.whereis(via) == nil
  end
end
```

- [ ] **Step 2: Update `lib/shem/agent_supervisor.ex`**

```elixir
defmodule Shem.AgentSupervisor do
  use DynamicSupervisor

  alias Shem.Agent.Config

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_agent(String.t(), Config.t()) :: DynamicSupervisor.on_start_child()
  def start_agent(name, %Config{} = config) do
    via = Shem.ProcessRegistry.via_tuple(name)

    child_spec = %{
      id: name,
      start: {Shem.Agent.Server, :start_link, [{name, config, [name: via]}]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end
```

- [ ] **Step 3: Run updated supervisor tests**

```bash
mix test test/shem/agent_supervisor_test.exs 2>&1 | tail -5
```
Expected: `3 tests, 0 failures`

- [ ] **Step 4: Write integration tests in `test/shem/agent/server_test.exs`**

Replace the file with the full integration test suite:

```elixir
defmodule Shem.Agent.ServerTest do
  use ExUnit.Case, async: false

  alias Shem.Agent
  alias Shem.LLM.{Response, StubTransport}

  setup do
    Shem.LLM.BudgetServer.reset()
    StubTransport.Server.reset()
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  defp stub(content, tokens \\ 5) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: tokens, model: :default, latency_ms: 1}}
    )
  end

  defp start_agent(task, opts \\ []) do
    system_prompt = Keyword.get(opts, :system_prompt, "be helpful")
    max_turns = Keyword.get(opts, :max_turns, 10)
    config = %Agent.Config{task: task, system_prompt: system_prompt, max_turns: max_turns}
    {:ok, name} = Agent.start(config)
    name
  end

  describe "Config" do
    test "struct has required fields with defaults" do
      config = %Agent.Config{task: "do something", system_prompt: "you are helpful"}
      assert config.task == "do something"
      assert config.model == :default
      assert config.tools == []
      assert config.max_turns == 20
    end
  end

  describe "single-turn run (no tool calls)" do
    test "agent reaches :done status after plain-text response" do
      stub("The answer is 42.")
      name = start_agent("what is 6 * 7?")
      assert {:ok, :done} = Agent.await(name, 2_000)
      assert {:ok, :done} = Agent.status(name)
    end

    test "EventLog session contains :agent_started, :agent_turn_started, :agent_turn_completed, :agent_done" do
      {:ok, sessions_before} = Shem.EventLog.list_sessions()
      before_ids = MapSet.new(Enum.map(sessions_before, & &1.id))

      stub("done")
      name = start_agent("task")
      Agent.await(name, 2_000)

      {:ok, sessions_after} = Shem.EventLog.list_sessions()
      session = Enum.find(sessions_after, fn s -> s.id not in before_ids end)
      assert session != nil

      {:ok, events} = Shem.EventLog.events(session.id)
      types = Enum.map(events, & &1.type)
      assert :agent_started in types
      assert :agent_turn_started in types
      assert :agent_turn_completed in types
      assert :agent_done in types
    end
  end

  describe "two-turn run: tool call then done" do
    test "agent calls write_tool, then completes" do
      source = """
      defmodule AgentWritten1 do
        def run(_args), do: :written
      end
      """
      test_src = """
      defmodule AgentWritten1Test do
        def run, do: :ok
      end
      """
      tool_call_response =
        ~s(I'll write a tool.\n{"tool": "write_tool", "args": {"source": #{Jason.encode!(source)}, "test_source": #{Jason.encode!(test_src)}}})

      stub(tool_call_response)
      stub("Task complete.")

      name = start_agent("write and graduate a tool")
      assert {:ok, :done} = Agent.await(name, 3_000)
      assert {:ok, _} = Shem.Lab.Registry.lookup("agent_written1")
    end
  end

  describe "self-correction loop" do
    test "agent retries write_tool after compile error, eventually graduates" do
      bad_source = "this is not valid elixir !!!"
      good_source = """
      defmodule AgentSelfCorrect1 do
        def run(_args), do: :corrected
      end
      """
      test_src = """
      defmodule AgentSelfCorrect1Test do
        def run, do: :ok
      end
      """

      stub(~s({"tool": "write_tool", "args": {"source": #{Jason.encode!(bad_source)}, "test_source": ""}}))
      stub(~s({"tool": "write_tool", "args": {"source": #{Jason.encode!(good_source)}, "test_source": #{Jason.encode!(test_src)}}}))
      stub("Done, tool graduated.")

      name = start_agent("write a tool, handle errors")
      assert {:ok, :done} = Agent.await(name, 3_000)
      assert {:ok, _} = Shem.Lab.Registry.lookup("agent_self_correct1")
    end
  end

  describe "circuit breakers" do
    test "agent stops with :done after max_turns" do
      # Push more responses than max_turns allows — agent will loop on tool calls
      for _ <- 1..5, do: stub(~s({"tool": "list_tools", "args": {}}))

      name = start_agent("loop forever", max_turns: 2)
      assert {:ok, :done} = Agent.await(name, 2_000)
      # Only 2 turns should have fired
      assert {:ok, :done} = Agent.status(name)
    end

    test "agent stops with :done when budget is exhausted" do
      # Exhaust budget (test config sets llm_budget_limit: 100_000)
      Shem.LLM.BudgetServer.deduct(100_001)
      name = start_agent("some task")
      assert {:ok, :done} = Agent.await(name, 2_000)
    end

    test "agent reaches :error status when LLM transport returns error" do
      StubTransport.Server.push_response({:error, :transport_down})
      name = start_agent("failing task")
      assert {:ok, :error} = Agent.await(name, 2_000)
    end
  end

  describe "Shem.Agent public API" do
    test "stop/1 terminates the agent process" do
      stub("done")
      name = start_agent("task")
      Agent.await(name, 2_000)
      assert :ok = Agent.stop(name)
      assert {:error, :not_found} = Agent.status(name)
    end

    test "status/1 returns {:error, :not_found} for unknown name" do
      assert {:error, :not_found} = Agent.status("nonexistent_agent")
    end

    test "await/2 returns immediately if agent is already done" do
      stub("done")
      name = start_agent("task")
      Agent.await(name, 2_000)
      assert {:ok, :done} = Agent.await(name, 100)
    end
  end
end
```

- [ ] **Step 5: Run integration tests**

```bash
mix test test/shem/agent/server_test.exs 2>&1 | tail -10
```
Expected: `10 tests, 0 failures`

Fix any failures. Common issues:
- `BudgetServer.deduct/1` doesn't accept a single arg — check signature. If it requires a server as first arg: `Shem.LLM.BudgetServer.deduct(Shem.LLM.BudgetServer, 100_001)`.
- EventLog session lookup in tests — if multiple sessions exist from other tests, the `Enum.find` may need tightening.

- [ ] **Step 6: Run the full test suite to check for regressions**

```bash
mix test 2>&1 | tail -10
```
Expected: all tests passing.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent_supervisor.ex test/shem/agent_supervisor_test.exs test/shem/agent/server_test.exs
git commit -m "feat: Shem.Agent.Server integration — ReAct loop, self-evolution, circuit breakers"
```

---

## Task 8: Final wiring check and smoke test

- [ ] **Step 1: Run the complete test suite**

```bash
mix test 2>&1 | tail -5
```
Expected: all tests passing, no compilation warnings about undefined functions.

- [ ] **Step 2: Verify `Shem.Agent` public API compiles and is accessible**

```bash
mix run --no-halt -e '
config = %Shem.Agent.Config{task: "list your tools", system_prompt: "be helpful"}
IO.inspect(config)
IO.puts("Agent.Config OK")
' 2>&1 | grep -E "Config|error"
```
Expected: prints the struct and "Agent.Config OK".

- [ ] **Step 3: Update `project_shem.md` memory**

Update the memory file at `/home/philip/.claude/projects/-home-philip-Downloads--project-shem/memory/project_shem.md` to add Phase 7 to the completed phases list.

- [ ] **Step 4: Final commit**

```bash
git add -p  # stage any remaining changes
git commit -m "feat: Phase 7 complete — Shem.Agent autonomous ReAct loop"
```
