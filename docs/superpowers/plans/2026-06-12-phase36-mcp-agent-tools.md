# Phase 36 — MCP Agent Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose `spawn_agent`, `agent_status`, `list_agents`, `stop_agent` over Shem's MCP server so any MCP client (Claude Code) can orchestrate Shem agents without writing Elixir.

**Architecture:** Four thin MCP handlers following the existing `Shem.MCP.Handlers.*` pattern (`call/1` returning `{:ok, map}` or `{:error, kind, detail}`), plus one shared helper module for the session-id↔agent-name mapping. The public `agent_id` is the **session_id** (`ses_...`), because it survives agent-process death — the EventLog acts as a tombstone for dead agents. Live agents are found by reverse lookup in `Shem.Registry` (Horde), whose values store session_ids (Phase 33 fix). Note: `Agent.Server` stays alive after finishing (`finish/3` only sets status), so live lookup covers done/waiting agents; the tombstone path covers killed agents.

**Tech Stack:** Elixir, Horde.Registry (`select/2`), existing `Shem.MCP.Schema` validation, `Shem.EventLog`, `Shem.LLM.StubTransport` in tests.

**Spec:** `docs/superpowers/specs/2026-06-11-phase36-mcp-agent-tools-design.md` + `docs/mcp-agent-tools.md`

**Deliberate deviations from spec (agreed in roadmap-v2 review):**
- `list_agents` returns **live agents only** (which includes finished-but-alive agents, since agent processes persist after `:done`). It does NOT join "recent EventLog sessions" — dead agents remain pollable by id via `agent_status`'s tombstone path. Joining all historical sessions would list every past session as an "agent", which is noise.
- `spawn_agent` takes `goal` + optional `preset` only — no `tools` array (the 06-11 spec explicitly puts arbitrary tool lists out of scope; `docs/mcp-agent-tools.md` predates that).

**Key domain facts for the implementer (verified against code):**
- `Shem.Agent.start_with_preset(preset, task)` → `{:ok, name, session_id}` | `{:error, :not_found}` (unknown preset). `name` is `"agent_XXXX"`, `session_id` is `"ses_XXXX"`.
- `Shem.Agent.status(name)` → `{:ok, :running | :done | :error | :waiting}` | `{:error, :not_found}`. Takes the **name**, not session_id.
- `Shem.Registry` (Horde) entries: agents registered as `{name, pid, session_id}` via `ProcessRegistry.via_tuple(name, session_id)`. Shadow agents register under `"shadow_..."` keys with `nil` values — always filter on the `"agent_"` name prefix.
- EventLog event types appended by `Agent.Server`: `:agent_started` (payload has `:task`), `:agent_turn_started`, `:agent_turn_completed` (payload: `turn`, `outcome` — **no content**), `:agent_tool_called`, `:agent_tool_result`, `:agent_error` (payload: `reason`), `:agent_done` (payload: `reason: :answer, content:` on success; `reason:` only otherwise), `:agent_waiting` (conversational; payload has `content`).
- An errored agent gets **both** `:agent_error` and `:agent_done` events.
- `EventLog.events(session_id)` → `{:ok, [Event.t]}` | `{:error, :session_not_found | :session_ended}`; `EventLog.read_session_events/1` reads from the store (works for ended sessions) → `{:ok, events}` | `{:error, :not_found}`.
- Test env uses `StubTransport`; push responses with `StubTransport.Server.push_response/1`, reset in setup. Copy the `stub/2` helper from `test/shem/agent/server_test.exs`.
- MCP handler tests live in `test/shem/mcp/handlers/`, `async: false`, call handlers directly. Router tests use `Plug.Test` (`test/shem/mcp/router_test.exs`).
- Agent processes from other tests may still be alive — `list_agents` tests must assert membership, never exact counts. Always stop spawned agents in the test or `on_exit`.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/shem/mcp/handlers/agent_common.ex` (create) | session↔name lookup, event extraction shared by 3 handlers |
| `lib/shem/mcp/handlers/spawn_agent.ex` (create) | `spawn_agent` tool |
| `lib/shem/mcp/handlers/agent_status.ex` (create) | `agent_status` tool (live + tombstone) |
| `lib/shem/mcp/handlers/list_agents.ex` (create) | `list_agents` tool |
| `lib/shem/mcp/handlers/stop_agent.ex` (create) | `stop_agent` tool |
| `lib/shem/mcp/router.ex` (modify: alias line 4, `call_tool` clauses ~line 98, `builtin_tool_descriptors/0` ~line 155) | dispatch + descriptors |
| `test/shem/mcp/handlers/agent_common_test.exs` etc. (create, one per handler) | handler tests |
| `test/shem/mcp/router_test.exs` (modify) | router round-trip + descriptor tests |

---

### Task 1: `Shem.MCP.Handlers.AgentCommon`

**Files:**
- Create: `lib/shem/mcp/handlers/agent_common.ex`
- Test: `test/shem/mcp/handlers/agent_common_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Shem.MCP.Handlers.AgentCommonTest do
  use ExUnit.Case, async: false

  alias Shem.Agent
  alias Shem.LLM.{Response, StubTransport}
  alias Shem.MCP.Handlers.AgentCommon

  setup do
    Shem.LLM.BudgetServer.reset()
    StubTransport.Server.reset()
    :ok
  end

  defp stub(content) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: 5, model: :default, latency_ms: 1}}
    )
  end

  defp start_done_agent(task) do
    stub("all done")
    config = %Agent.Config{task: task, system_prompt: "be helpful"}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :done} = Agent.await(name, 2_000)
    {name, session_id}
  end

  describe "find_by_session/1" do
    test "finds a live agent's name by its session_id" do
      {name, session_id} = start_done_agent("find me")
      on_exit(fn -> Agent.stop(name) end)
      assert {:ok, ^name} = AgentCommon.find_by_session(session_id)
    end

    test "returns :not_found for an unknown session_id" do
      assert :not_found = AgentCommon.find_by_session("ses_DOESNOTEXIST")
    end

    test "returns :not_found after the agent process is stopped" do
      {name, session_id} = start_done_agent("stop me")
      :ok = Agent.stop(name)
      eventually(fn -> AgentCommon.find_by_session(session_id) == :not_found end)
    end
  end

  # Horde.Registry deregisters asynchronously after process death — retry briefly
  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  describe "live_agents/0" do
    test "includes a started agent as {name, session_id}" do
      {name, session_id} = start_done_agent("list me")
      on_exit(fn -> Agent.stop(name) end)
      assert {name, session_id} in AgentCommon.live_agents()
    end
  end

  describe "event extraction" do
    test "goal/1 returns the task from :agent_started" do
      {name, session_id} = start_done_agent("the goal text")
      on_exit(fn -> Agent.stop(name) end)
      {:ok, events} = AgentCommon.session_events(session_id)
      assert AgentCommon.goal(events) == "the goal text"
    end

    test "final_output/1 returns the :agent_done answer content" do
      {name, session_id} = start_done_agent("answer me")
      on_exit(fn -> Agent.stop(name) end)
      {:ok, events} = AgentCommon.session_events(session_id)
      assert AgentCommon.final_output(events) == "all done"
    end

    test "tombstone_status/1 is done for a completed session" do
      {name, session_id} = start_done_agent("tombstone")
      :ok = Agent.stop(name)
      {:ok, events} = AgentCommon.session_events(session_id)
      assert AgentCommon.tombstone_status(events) == "done"
    end

    test "session_events/1 returns :not_found for unknown session" do
      assert {:error, :not_found} = AgentCommon.session_events("ses_NOPE")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/shem/mcp/handlers/agent_common_test.exs`
Expected: FAIL — `module Shem.MCP.Handlers.AgentCommon is not available`

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Shem.MCP.Handlers.AgentCommon do
  @moduledoc """
  Shared helpers for the MCP agent tools.

  The public `agent_id` over MCP is the EventLog session_id, because it
  outlives the agent process. `Shem.Registry` stores session_ids as values
  (entries are `{name, pid, session_id}`), so live agents are found by a
  reverse value lookup. Names are filtered to the `"agent_"` prefix to skip
  shadow agents and other registry tenants.
  """

  alias Shem.EventLog

  @spec find_by_session(String.t()) :: {:ok, String.t()} | :not_found
  def find_by_session(session_id) do
    match = [{{:"$1", :"$2", :"$3"}, [{:==, :"$3", session_id}], [:"$1"]}]

    Shem.Registry
    |> Horde.Registry.select(match)
    |> Enum.filter(&agent_name?/1)
    |> case do
      [name | _] -> {:ok, name}
      [] -> :not_found
    end
  end

  @spec live_agents() :: [{String.t(), String.t()}]
  def live_agents do
    match = [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}]

    Shem.Registry
    |> Horde.Registry.select(match)
    |> Enum.filter(fn {name, _session_id} -> agent_name?(name) end)
  end

  @spec session_events(String.t()) :: {:ok, [EventLog.Event.t()]} | {:error, :not_found}
  def session_events(session_id) do
    case EventLog.events(session_id) do
      {:ok, events} -> {:ok, events}
      {:error, _} -> EventLog.read_session_events(session_id)
    end
  end

  @spec goal([EventLog.Event.t()]) :: String.t()
  def goal(events) do
    case Enum.find(events, &(&1.type == :agent_started)) do
      %{payload: %{task: task}} when is_binary(task) -> task
      _ -> ""
    end
  end

  @spec final_output([EventLog.Event.t()]) :: String.t()
  def final_output(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{type: :agent_done, payload: %{content: content}} -> content
      %{type: :agent_done, payload: %{reason: reason}} -> "stopped: #{reason}"
      %{type: :agent_waiting, payload: %{content: content}} -> content
      _ -> nil
    end)
  end

  @spec tombstone_status([EventLog.Event.t()]) :: String.t()
  def tombstone_status(events) do
    done? = Enum.any?(events, &(&1.type == :agent_done))
    errored? = Enum.any?(events, &(&1.type == :agent_error))
    waited? = Enum.any?(events, &(&1.type == :agent_waiting))

    cond do
      done? and errored? -> "error"
      done? -> "done"
      waited? -> "done"
      true -> "error"
    end
  end

  defp agent_name?(name), do: is_binary(name) and String.starts_with?(name, "agent_")
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/shem/mcp/handlers/agent_common_test.exs`
Expected: 7 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/handlers/agent_common.ex test/shem/mcp/handlers/agent_common_test.exs
git commit -m "feat: AgentCommon — session_id reverse lookup and event extraction for MCP agent tools"
```

---

### Task 2: `spawn_agent` handler

**Files:**
- Create: `lib/shem/mcp/handlers/spawn_agent.ex`
- Test: `test/shem/mcp/handlers/spawn_agent_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Shem.MCP.Handlers.SpawnAgentTest do
  use ExUnit.Case, async: false

  alias Shem.LLM.{Response, StubTransport}
  alias Shem.MCP.Handlers.{AgentCommon, SpawnAgent}

  setup do
    Shem.LLM.BudgetServer.reset()
    StubTransport.Server.reset()
    :ok
  end

  defp stub(content) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: 5, model: :default, latency_ms: 1}}
    )
  end

  defp stop_by_session(session_id) do
    case AgentCommon.find_by_session(session_id) do
      {:ok, name} -> Shem.Agent.stop(name)
      :not_found -> :ok
    end
  end

  test "spawns an agent and returns its session_id as agent_id, status running" do
    stub("done")
    assert {:ok, %{"agent_id" => agent_id, "status" => "running"}} =
             SpawnAgent.call(%{"goal" => "say hello"})

    on_exit(fn -> stop_by_session(agent_id) end)
    assert String.starts_with?(agent_id, "ses_")
    assert {:ok, _name} = AgentCommon.find_by_session(agent_id)
  end

  test "accepts an optional preset" do
    stub("done")
    assert {:ok, %{"agent_id" => agent_id}} =
             SpawnAgent.call(%{"goal" => "say hello", "preset" => "coder"})

    on_exit(fn -> stop_by_session(agent_id) end)
  end

  test "rejects an unknown preset" do
    assert {:error, :invalid_args, msg} =
             SpawnAgent.call(%{"goal" => "x", "preset" => "no_such_preset"})

    assert msg =~ "no_such_preset"
  end

  test "rejects a missing goal" do
    assert {:error, :invalid_args, _} = SpawnAgent.call(%{})
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/shem/mcp/handlers/spawn_agent_test.exs`
Expected: FAIL — `module Shem.MCP.Handlers.SpawnAgent is not available`

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Shem.MCP.Handlers.SpawnAgent do
  alias Shem.MCP.Schema

  @schema %{
    "goal" => %{"type" => "string"},
    "preset" => %{"type" => "string", "required" => false}
  }

  @spec call(map()) :: {:ok, map()} | {:error, atom(), any()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema) do
      preset = Map.get(valid, "preset", "general")

      case Shem.Agent.start_with_preset(preset, valid["goal"]) do
        {:ok, _name, session_id} ->
          {:ok, %{"agent_id" => session_id, "status" => "running"}}

        {:error, :not_found} ->
          {:error, :invalid_args, "unknown preset: #{preset}"}

        {:error, reason} ->
          {:error, :spawn_failed, inspect(reason)}
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/shem/mcp/handlers/spawn_agent_test.exs`
Expected: 4 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/handlers/spawn_agent.ex test/shem/mcp/handlers/spawn_agent_test.exs
git commit -m "feat: spawn_agent MCP handler — start a Shem agent from any MCP client"
```

---

### Task 3: `agent_status` handler

**Files:**
- Create: `lib/shem/mcp/handlers/agent_status.ex`
- Test: `test/shem/mcp/handlers/agent_status_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Shem.MCP.Handlers.AgentStatusTest do
  use ExUnit.Case, async: false

  alias Shem.Agent
  alias Shem.LLM.{Response, StubTransport}
  alias Shem.MCP.Handlers.AgentStatus

  setup do
    Shem.LLM.BudgetServer.reset()
    StubTransport.Server.reset()
    :ok
  end

  defp stub(content) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: 5, model: :default, latency_ms: 1}}
    )
  end

  test "live done agent: status done with final output and event count" do
    stub("the final answer")
    config = %Agent.Config{task: "compute", system_prompt: "be helpful"}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :done} = Agent.await(name, 2_000)
    on_exit(fn -> Agent.stop(name) end)

    assert {:ok, result} = AgentStatus.call(%{"agent_id" => session_id})
    assert result["agent_id"] == session_id
    assert result["status"] == "done"
    assert result["output"] == "the final answer"
    assert result["events"] > 0
  end

  test "live conversational agent: status waiting with last content" do
    stub("how can I help?")
    config = %Agent.Config{task: "chat", system_prompt: "be helpful", conversational: true}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :waiting} = Agent.await(name, 2_000)
    on_exit(fn -> Agent.stop(name) end)

    assert {:ok, result} = AgentStatus.call(%{"agent_id" => session_id})
    assert result["status"] == "waiting"
    assert result["output"] == "how can I help?"
  end

  test "dead agent: tombstone status from EventLog" do
    stub("posthumous answer")
    config = %Agent.Config{task: "die", system_prompt: "be helpful"}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :done} = Agent.await(name, 2_000)
    :ok = Agent.stop(name)

    assert {:ok, result} = AgentStatus.call(%{"agent_id" => session_id})
    assert result["status"] == "done"
    assert result["output"] == "posthumous answer"
  end

  test "unknown agent_id returns not_found error" do
    assert {:error, :not_found, _} = AgentStatus.call(%{"agent_id" => "ses_NOPE"})
  end

  test "missing agent_id is invalid_args" do
    assert {:error, :invalid_args, _} = AgentStatus.call(%{})
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/shem/mcp/handlers/agent_status_test.exs`
Expected: FAIL — `module Shem.MCP.Handlers.AgentStatus is not available`

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Shem.MCP.Handlers.AgentStatus do
  alias Shem.MCP.Handlers.AgentCommon
  alias Shem.MCP.Schema

  @schema %{"agent_id" => %{"type" => "string"}}

  @spec call(map()) :: {:ok, map()} | {:error, atom(), any()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema) do
      session_id = valid["agent_id"]

      case AgentCommon.find_by_session(session_id) do
        {:ok, name} -> live_status(name, session_id)
        :not_found -> tombstone(session_id)
      end
    end
  end

  defp live_status(name, session_id) do
    case Shem.Agent.status(name) do
      {:ok, status} ->
        {events, count} =
          case AgentCommon.session_events(session_id) do
            {:ok, events} -> {events, length(events)}
            {:error, _} -> {[], 0}
          end

        output = if status == :running, do: "", else: AgentCommon.final_output(events)

        {:ok,
         %{
           "agent_id" => session_id,
           "status" => Atom.to_string(status),
           "output" => output,
           "events" => count
         }}

      # agent died between registry lookup and the status call
      {:error, :not_found} ->
        tombstone(session_id)
    end
  end

  defp tombstone(session_id) do
    case AgentCommon.session_events(session_id) do
      {:ok, events} ->
        {:ok,
         %{
           "agent_id" => session_id,
           "status" => AgentCommon.tombstone_status(events),
           "output" => AgentCommon.final_output(events),
           "events" => length(events)
         }}

      {:error, _} ->
        {:error, :not_found, "no agent with id #{session_id}"}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/shem/mcp/handlers/agent_status_test.exs`
Expected: 5 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/handlers/agent_status.ex test/shem/mcp/handlers/agent_status_test.exs
git commit -m "feat: agent_status MCP handler — live status + EventLog tombstone for dead agents"
```

---

### Task 4: `list_agents` handler

**Files:**
- Create: `lib/shem/mcp/handlers/list_agents.ex`
- Test: `test/shem/mcp/handlers/list_agents_test.exs`

- [ ] **Step 1: Write the failing tests**

Note: other test files leave finished agents alive — assert membership, never exact list length.

```elixir
defmodule Shem.MCP.Handlers.ListAgentsTest do
  use ExUnit.Case, async: false

  alias Shem.Agent
  alias Shem.LLM.{Response, StubTransport}
  alias Shem.MCP.Handlers.ListAgents

  setup do
    Shem.LLM.BudgetServer.reset()
    StubTransport.Server.reset()
    :ok
  end

  defp stub(content) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: 5, model: :default, latency_ms: 1}}
    )
  end

  test "lists a live agent with its goal, status, and event count" do
    stub("done")
    config = %Agent.Config{task: "a distinctive goal", system_prompt: "be helpful"}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :done} = Agent.await(name, 2_000)
    on_exit(fn -> Agent.stop(name) end)

    assert {:ok, %{"agents" => agents}} = ListAgents.call(%{})
    entry = Enum.find(agents, &(&1["agent_id"] == session_id))
    assert entry
    assert entry["status"] == "done"
    assert entry["goal"] == "a distinctive goal"
    assert entry["events"] > 0
  end

  test "a stopped agent disappears from the list" do
    stub("done")
    config = %Agent.Config{task: "ephemeral", system_prompt: "be helpful"}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :done} = Agent.await(name, 2_000)
    :ok = Agent.stop(name)

    # Horde.Registry deregisters asynchronously after process death — retry briefly
    eventually(fn ->
      {:ok, %{"agents" => agents}} = ListAgents.call(%{})
      not Enum.any?(agents, &(&1["agent_id"] == session_id))
    end)
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/shem/mcp/handlers/list_agents_test.exs`
Expected: FAIL — `module Shem.MCP.Handlers.ListAgents is not available`

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Shem.MCP.Handlers.ListAgents do
  alias Shem.MCP.Handlers.AgentCommon

  @spec call(map()) :: {:ok, map()}
  def call(_args) do
    agents =
      AgentCommon.live_agents()
      |> Enum.map(fn {name, session_id} ->
        status =
          case Shem.Agent.status(name) do
            {:ok, s} -> Atom.to_string(s)
            {:error, :not_found} -> "error"
          end

        {goal, count} =
          case AgentCommon.session_events(session_id) do
            {:ok, events} -> {AgentCommon.goal(events), length(events)}
            {:error, _} -> {"", 0}
          end

        %{"agent_id" => session_id, "status" => status, "goal" => goal, "events" => count}
      end)

    {:ok, %{"agents" => agents}}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/shem/mcp/handlers/list_agents_test.exs`
Expected: 2 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/handlers/list_agents.ex test/shem/mcp/handlers/list_agents_test.exs
git commit -m "feat: list_agents MCP handler — live agents with goal and status"
```

---

### Task 5: `stop_agent` handler

**Files:**
- Create: `lib/shem/mcp/handlers/stop_agent.ex`
- Test: `test/shem/mcp/handlers/stop_agent_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Shem.MCP.Handlers.StopAgentTest do
  use ExUnit.Case, async: false

  alias Shem.Agent
  alias Shem.LLM.{Response, StubTransport}
  alias Shem.MCP.Handlers.{AgentCommon, StopAgent}

  setup do
    Shem.LLM.BudgetServer.reset()
    StubTransport.Server.reset()
    :ok
  end

  defp stub(content) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: 5, model: :default, latency_ms: 1}}
    )
  end

  test "stops a live agent by session_id" do
    stub("done")
    config = %Agent.Config{task: "stoppable", system_prompt: "be helpful"}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :done} = Agent.await(name, 2_000)

    assert {:ok, %{"ok" => true}} = StopAgent.call(%{"agent_id" => session_id})
    # Horde.Registry deregisters asynchronously after process death — retry briefly
    eventually(fn -> AgentCommon.find_by_session(session_id) == :not_found end)
  end

  test "unknown agent_id returns not_found error" do
    assert {:error, :not_found, _} = StopAgent.call(%{"agent_id" => "ses_NOPE"})
  end

  test "missing agent_id is invalid_args" do
    assert {:error, :invalid_args, _} = StopAgent.call(%{})
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/shem/mcp/handlers/stop_agent_test.exs`
Expected: FAIL — `module Shem.MCP.Handlers.StopAgent is not available`

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Shem.MCP.Handlers.StopAgent do
  alias Shem.MCP.Handlers.AgentCommon
  alias Shem.MCP.Schema

  @schema %{"agent_id" => %{"type" => "string"}}

  @spec call(map()) :: {:ok, map()} | {:error, atom(), any()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema) do
      session_id = valid["agent_id"]

      with {:ok, name} <- AgentCommon.find_by_session(session_id),
           :ok <- Shem.Agent.stop(name) do
        {:ok, %{"ok" => true}}
      else
        _ -> {:error, :not_found, "no running agent with id #{session_id}"}
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/shem/mcp/handlers/stop_agent_test.exs`
Expected: 3 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/handlers/stop_agent.ex test/shem/mcp/handlers/stop_agent_test.exs
git commit -m "feat: stop_agent MCP handler"
```

---

### Task 6: Router wiring — dispatch + tool descriptors

**Files:**
- Modify: `lib/shem/mcp/router.ex` (alias at line 4, `call_tool` clauses after line 101, descriptors in `builtin_tool_descriptors/0`)
- Test: `test/shem/mcp/router_test.exs` (append tests)

- [ ] **Step 1: Write the failing tests** (append inside `Shem.MCP.RouterTest`; it already has `post_rpc/3` and `decode_response/1` helpers)

First add this private helper at **module level** next to `decode_response/1` — ExUnit does not allow `defp` inside `describe` blocks:

```elixir
  defp call_tool_rpc(name, arguments) do
    conn = post_rpc("tools/call", %{"name" => name, "arguments" => arguments})
    assert conn.status == 200
    resp = decode_response(conn)
    [%{"type" => "text", "text" => text}] = resp["result"]["content"]
    Jason.decode!(text)
  end
```

Then append the describe block:

```elixir
  describe "agent tools over MCP" do
    setup do
      Shem.LLM.BudgetServer.reset()
      Shem.LLM.StubTransport.Server.reset()
      :ok
    end

    test "tools/list includes the four agent tools" do
      conn = post_rpc("tools/list", %{})
      names = Enum.map(decode_response(conn)["result"]["tools"], & &1["name"])

      for tool <- ["spawn_agent", "agent_status", "list_agents", "stop_agent"] do
        assert tool in names
      end
    end

    test "spawn → poll → stop round-trip over JSON-RPC" do
      Shem.LLM.StubTransport.Server.push_response(
        {:ok,
         %Shem.LLM.Response{content: "rpc answer", tokens_used: 5, model: :default, latency_ms: 1}}
      )

      %{"agent_id" => agent_id, "status" => "running"} =
        call_tool_rpc("spawn_agent", %{"goal" => "round trip"})

      # poll until done (StubTransport answers immediately; allow a few ticks)
      status =
        Enum.reduce_while(1..50, nil, fn _, _ ->
          case call_tool_rpc("agent_status", %{"agent_id" => agent_id}) do
            %{"status" => "done"} = result -> {:halt, result}
            _ -> Process.sleep(50); {:cont, nil}
          end
        end)

      assert %{"output" => "rpc answer"} = status

      listed = call_tool_rpc("list_agents", %{})
      assert Enum.any?(listed["agents"], &(&1["agent_id"] == agent_id))

      assert %{"ok" => true} = call_tool_rpc("stop_agent", %{"agent_id" => agent_id})
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/shem/mcp/router_test.exs`
Expected: new tests FAIL (`spawn_agent` missing from tools/list; tools/call returns `-32602 :not_found`)

- [ ] **Step 3: Wire the router**

In `lib/shem/mcp/router.ex`, change the alias line:

```elixir
  alias Shem.MCP.Handlers.{
    AgentStatus,
    ExecuteCode,
    GraduateTool,
    InvokeTool,
    ListAgents,
    ListTools,
    SpawnAgent,
    StopAgent
  }
```

Add four `call_tool` clauses after the existing ones (before the catch-all):

```elixir
  defp call_tool("spawn_agent", args), do: SpawnAgent.call(args)
  defp call_tool("agent_status", args), do: AgentStatus.call(args)
  defp call_tool("list_agents", args), do: ListAgents.call(args)
  defp call_tool("stop_agent", args), do: StopAgent.call(args)
```

Append four descriptors to the list in `builtin_tool_descriptors/0`:

```elixir
      %{
        "name" => "spawn_agent",
        "description" =>
          "Start a Shem agent with a goal. Returns an agent_id immediately (non-blocking). Poll with agent_status.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "goal" => %{"type" => "string", "description" => "The task for the agent"},
            "preset" => %{
              "type" => "string",
              "description" =>
                "Agent preset (general, coder, researcher, writer, security, explorer). Default: general"
            }
          },
          "required" => ["goal"]
        }
      },
      %{
        "name" => "agent_status",
        "description" =>
          "Poll a Shem agent by id. Returns status (running|waiting|done|error), accumulated output, and event count. When status is done or error, output holds the final result.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "agent_id" => %{"type" => "string", "description" => "Agent id from spawn_agent"}
          },
          "required" => ["agent_id"]
        }
      },
      %{
        "name" => "list_agents",
        "description" => "List all live Shem agents with their status, goal, and event count.",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "stop_agent",
        "description" => "Stop a running Shem agent by id.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "agent_id" => %{"type" => "string", "description" => "Agent id from spawn_agent"}
          },
          "required" => ["agent_id"]
        }
      }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/shem/mcp/router_test.exs`
Expected: all pass, including the existing "four Shem tools" test (it asserts membership, not count)

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/router.ex test/shem/mcp/router_test.exs
git commit -m "feat: wire spawn_agent/agent_status/list_agents/stop_agent into MCP router"
```

---

### Task 7: Parallel-dispatch integration test + full suite

The spec's success criterion: two agents spawned simultaneously both complete and return results.

**Files:**
- Create: `test/shem/mcp/agent_tools_integration_test.exs`

- [ ] **Step 1: Write the integration test**

```elixir
defmodule Shem.MCP.AgentToolsIntegrationTest do
  use ExUnit.Case, async: false

  alias Shem.LLM.{Response, StubTransport}
  alias Shem.MCP.Handlers.{AgentStatus, SpawnAgent, StopAgent}

  setup do
    Shem.LLM.BudgetServer.reset()
    StubTransport.Server.reset()
    :ok
  end

  defp stub(content) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: 5, model: :default, latency_ms: 1}}
    )
  end

  defp poll_until_done(agent_id, attempts \\ 50) do
    Enum.reduce_while(1..attempts, :timeout, fn _, _ ->
      case AgentStatus.call(%{"agent_id" => agent_id}) do
        {:ok, %{"status" => s} = result} when s in ["done", "error"] -> {:halt, result}
        _ -> Process.sleep(50); {:cont, :timeout}
      end
    end)
  end

  test "two agents spawned in parallel both complete with their own results" do
    # StubTransport is a FIFO queue shared by all agents; push one answer per agent
    stub("answer alpha")
    stub("answer beta")

    {:ok, %{"agent_id" => id_a}} = SpawnAgent.call(%{"goal" => "task alpha"})
    {:ok, %{"agent_id" => id_b}} = SpawnAgent.call(%{"goal" => "task beta"})
    on_exit(fn ->
      StopAgent.call(%{"agent_id" => id_a})
      StopAgent.call(%{"agent_id" => id_b})
    end)

    result_a = poll_until_done(id_a)
    result_b = poll_until_done(id_b)

    assert %{"status" => "done"} = result_a
    assert %{"status" => "done"} = result_b
    assert Enum.sort([result_a["output"], result_b["output"]]) ==
             ["answer alpha", "answer beta"]
  end
end
```

- [ ] **Step 2: Run the integration test**

Run: `mix test test/shem/mcp/agent_tools_integration_test.exs`
Expected: 1 test, 0 failures. (If the output assertion is flaky because the FIFO queue assigns answers to whichever agent calls first, relax it to asserting both outputs are in `["answer alpha", "answer beta"]` — the sort-comparison already handles either assignment order.)

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: 876 existing + ~22 new tests, 0 failures

- [ ] **Step 4: Commit**

```bash
git add test/shem/mcp/agent_tools_integration_test.exs
git commit -m "test: parallel agent dispatch over MCP integration test"
```

---

## Post-implementation checklist (not separate tasks)

- Update memory `project_shem.md`: add Phase 36 ✅ section with final test count; move it out of On-deck.
- Manual smoke test (optional, needs running server): `shem start --headless`, then from Claude Code call `spawn_agent` — requires a configured LLM backend for the agent itself (StubTransport is test-only; real agents need llama.cpp/LM-Studio running).
