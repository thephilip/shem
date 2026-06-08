# Multi-Agent Coordination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `spawn_agent` built-in tool that lets an agent delegate a sub-task to a new agent and receive its final answer as a tool result.

**Architecture:** One new public function `Agent.await_result/2` encapsulates EventLog access for result extraction. One new `@builtins` entry and `dispatch_builtin` clause in `ToolDispatch` with a process-dictionary depth guard. Parent blocks until sub-agent completes; no changes to `Agent.Server`, `Turn`, or `AgentSupervisor`.

**Tech Stack:** Elixir/OTP, Horde, DETS EventLog, ExUnit, StubTransport

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Modify | `config/config.exs` | Add `spawn_agent_timeout_ms` and `spawn_agent_max_depth` defaults |
| Modify | `config/test.exs` | Override both config keys for fast/safe tests |
| Modify | `lib/shem/agent.ex` | Add `await_result/2` public function |
| Modify | `lib/shem/agent/tool_dispatch.ex` | Add `spawn_agent` builtin + `dispatch_builtin` clause + `alias Shem.Agent` |
| Modify | `test/shem/agent/server_test.exs` | Add `await_result/2` tests |
| Modify | `test/shem/agent/tool_dispatch_test.exs` | Add `spawn_agent` builtin tests |

---

## Task 1: Config and `Agent.await_result/2`

**Files:**
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `lib/shem/agent.ex`
- Modify: `test/shem/agent/server_test.exs`

- [ ] **Step 1: Add config keys**

In `config/config.exs`, add after the `trust_gate_enabled` line:

```elixir
config :shem, spawn_agent_timeout_ms: 300_000
config :shem, spawn_agent_max_depth: 3
```

In `config/test.exs`, add after the `trust_gate_enabled` line:

```elixir
config :shem, spawn_agent_timeout_ms: 5_000
config :shem, spawn_agent_max_depth: 2
```

- [ ] **Step 2: Write failing tests for `await_result/2`**

In `test/shem/agent/server_test.exs`, add the following describe block after the existing describe blocks (before the final `end`):

```elixir
  describe "await_result/2" do
    test "returns {:ok, answer} when agent completes with a final answer" do
      stub("The computed answer.")
      name = start_agent("compute something")
      assert {:ok, "The computed answer."} = Agent.await_result(name, 2_000)
    end

    test "returns {:error, :sub_agent_failed} when agent finishes with error status" do
      StubTransport.Server.push_response({:error, :transport_failure})
      name = start_agent("anything")
      assert {:error, :sub_agent_failed} = Agent.await_result(name, 2_000)
    end
  end
```

- [ ] **Step 3: Run to confirm tests fail**

```bash
mix test test/shem/agent/server_test.exs 2>&1 | tail -10
```

Expected: `** (UndefinedFunctionError) function Shem.Agent.await_result/2 is undefined`

- [ ] **Step 4: Implement `Agent.await_result/2`**

In `lib/shem/agent.ex`, add after `session_id/1` (before the closing `end`):

```elixir
  @spec await_result(String.t(), timeout()) :: {:ok, String.t()} | {:error, term()}
  def await_result(name, timeout \\ 300_000) do
    with {:ok, sid} <- session_id(name),
         {:ok, :done} <- await(name, timeout),
         {:ok, events} <- Shem.EventLog.events(sid),
         %{payload: %{content: content}} <-
           Enum.find(Enum.reverse(events), &(&1.type == :agent_done)) do
      {:ok, content}
    else
      {:ok, :error} -> {:error, :sub_agent_failed}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :no_result}
    end
  end
```

- [ ] **Step 5: Run tests to confirm they pass**

```bash
mix test test/shem/agent/server_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add config/config.exs config/test.exs lib/shem/agent.ex test/shem/agent/server_test.exs
git commit -m "feat: Agent.await_result/2 — await + extract sub-agent final answer"
```

---

## Task 2: `spawn_agent` builtin in `ToolDispatch`

**Files:**
- Modify: `lib/shem/agent/tool_dispatch.ex`
- Modify: `test/shem/agent/tool_dispatch_test.exs`

- [ ] **Step 1: Write failing tests**

In `test/shem/agent/tool_dispatch_test.exs`, add the following alias at the top of the module (after the existing aliases):

```elixir
  alias Shem.LLM.{Response, StubTransport}
```

Then add this describe block before the final `end` of the module:

```elixir
  describe "spawn_agent built-in" do
    setup do
      Shem.LLM.BudgetServer.reset()
      StubTransport.Server.reset()
      :ok
    end

    test "returns sub-agent final answer on success" do
      StubTransport.Server.push_response(
        {:ok, %Response{content: "Sub-task complete.", tokens_used: 5, model: :default, latency_ms: 1}}
      )
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, "Sub-task complete."} =
        ToolDispatch.execute(
          %{name: "spawn_agent", args: %{"task" => "do the sub-task", "preset" => "general"}},
          manifest
        )
    end

    test "returns error result when preset does not exist" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:error, reason} =
        ToolDispatch.execute(
          %{name: "spawn_agent", args: %{"task" => "do something", "preset" => "no_such_preset"}},
          manifest
        )
      assert String.contains?(reason, "sub-agent failed")
    end

    test "returns depth limit error without starting an agent" do
      Process.put(:spawn_agent_depth, 2)
      on_exit(fn -> Process.delete(:spawn_agent_depth) end)
      manifest = ToolDispatch.build_manifest(@config)
      assert {:error, "spawn_agent depth limit reached (2)"} =
        ToolDispatch.execute(
          %{name: "spawn_agent", args: %{"task" => "do something"}},
          manifest
        )
    end

    test "defaults preset to general when omitted" do
      StubTransport.Server.push_response(
        {:ok, %Response{content: "Done with default preset.", tokens_used: 5, model: :default, latency_ms: 1}}
      )
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, "Done with default preset."} =
        ToolDispatch.execute(
          %{name: "spawn_agent", args: %{"task" => "do the sub-task"}},
          manifest
        )
    end
  end
```

- [ ] **Step 2: Run to confirm tests fail**

```bash
mix test test/shem/agent/tool_dispatch_test.exs 2>&1 | tail -10
```

Expected: failures — `spawn_agent` is an unknown built-in.

- [ ] **Step 3: Add `alias Shem.Agent` to `ToolDispatch`**

In `lib/shem/agent/tool_dispatch.ex`, update the alias block at the top to add `alias Shem.Agent`:

```elixir
  alias Shem.Agent.Config
  alias Shem.Agent
  alias Shem.Lab
  alias Shem.MCP
  alias Shem.Trust
```

- [ ] **Step 4: Add `spawn_agent` to `@builtins`**

In `lib/shem/agent/tool_dispatch.ex`, append the following map to the `@builtins` list after the existing `shell` entry (before the closing `]`):

```elixir
    %{
      name: "spawn_agent",
      description: "Delegate a task to a sub-agent. Specify the task and optionally a preset name (default: general). Returns the sub-agent's final answer.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{
          "task"   => %{"type" => "string"},
          "preset" => %{"type" => "string"}
        },
        required: ["task"]
      }
    }
```

- [ ] **Step 5: Add `dispatch_builtin("spawn_agent", ...)` clause**

In `lib/shem/agent/tool_dispatch.ex`, add the following clause after `dispatch_builtin("shell", ...)` and before the fallthrough `defp dispatch_builtin(name, _args)`:

```elixir
  defp dispatch_builtin("spawn_agent", args) do
    task = args["task"]
    preset = args["preset"] || "general"
    depth = Process.get(:spawn_agent_depth, 0)
    max_depth = Application.get_env(:shem, :spawn_agent_max_depth, 3)
    timeout = Application.get_env(:shem, :spawn_agent_timeout_ms, 300_000)

    if depth >= max_depth do
      {:error, "spawn_agent depth limit reached (#{max_depth})"}
    else
      Process.put(:spawn_agent_depth, depth + 1)

      result =
        case Agent.start_with_preset(preset, task) do
          {:ok, name} ->
            case Agent.await_result(name, timeout) do
              {:ok, answer} -> {:ok, answer}
              {:error, reason} -> {:error, "sub-agent failed: #{inspect(reason)}"}
            end

          {:error, reason} ->
            {:error, "sub-agent failed: #{inspect(reason)}"}
        end

      Process.put(:spawn_agent_depth, depth)
      result
    end
  end
```

- [ ] **Step 6: Run new tests to confirm they pass**

```bash
mix test test/shem/agent/tool_dispatch_test.exs
```

Expected: all tests pass.

- [ ] **Step 7: Run the full test suite**

```bash
mix test
```

Expected: all tests pass. Count should be approximately 686+ (671 + new tests from Tasks 1 and 2).

- [ ] **Step 8: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex test/shem/agent/tool_dispatch_test.exs
git commit -m "feat: spawn_agent builtin — blocking sub-agent delegation with depth guard"
```
