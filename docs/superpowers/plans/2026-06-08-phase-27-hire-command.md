# /hire Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `/hire <name> <role>` to the TUI — one LLM call generates a system prompt, the result is saved to `PresetStore` and immediately available to `/agent` and `spawn_agent`.

**Architecture:** Two source files change. `CommandDispatch` gains a `/hire` parse clause. `App` fires a `Task.start` on `{:hire, name, role}` (capturing `self()` as `tui_pid`), then handles the async `{:hire_complete, name, result}` message that the task sends back. The existing `command_output` field surfaces hire status to the user — no view changes needed.

**Tech Stack:** Elixir/OTP, Ratatouille TUI, `Shem.LLM` (pipeline-based, `StubTransport` in tests), `Shem.Agent.PresetStore` (DETS-backed GenServer)

> **Spec deviation note:** The spec described a separate `hire_status` field and listed `interactive.ex` as implicitly needing no change. In implementation, we reuse the existing `command_output` field (already rendered by `Interactive.render_turn_card/1` when no agent is active) to surface hire feedback. This stays within the "two source files only" constraint while producing identical visible behaviour.

---

## File Map

| File | Change |
|------|--------|
| `lib/shem/tui/command_dispatch.ex` | Add `["hire", name \| role_parts]` + `["hire" \| _]` clauses; extend `@spec` return type |
| `lib/shem/tui/app.ex` | Handle `{:hire, name, role}` in Enter path (fire Task, set `command_output`); handle `{:hire_complete, name, result}` message |
| `test/shem/tui/command_dispatch_test.exs` | Add `/hire` parse test cases |
| `test/shem/tui/app_hire_test.exs` | New — unit tests for `{:hire_complete}` handler + integration test for full async flow |

---

### Task 1: CommandDispatch — parse `/hire`

**Files:**
- Modify: `lib/shem/tui/command_dispatch.ex`
- Test: `test/shem/tui/command_dispatch_test.exs`

- [ ] **Step 1: Write failing tests**

Add a new `describe` block at the end of `test/shem/tui/command_dispatch_test.exs` (before the final `end`):

```elixir
  describe "parse/1 — /hire command" do
    test "/hire <name> <role> returns {:hire, name, role}" do
      assert {:hire, "researcher", "summarises academic papers"} =
               CommandDispatch.parse("/hire researcher summarises academic papers")
    end

    test "/hire with single-word role works" do
      assert {:hire, "coder", "codes"} = CommandDispatch.parse("/hire coder codes")
    end

    test "/hire with no name returns error" do
      assert {:error, msg} = CommandDispatch.parse("/hire")
      assert msg =~ "usage: /hire"
    end

    test "/hire with name but no role returns error" do
      assert {:error, msg} = CommandDispatch.parse("/hire researcher")
      assert msg =~ "usage: /hire"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/tui/command_dispatch_test.exs 2>&1 | tail -20
```

Expected: 3 failures — first two return `{:error, "unknown command: /hire ..."}`, last two already return an error but with the wrong message, or pass for the wrong reason. At least the first two should fail.

- [ ] **Step 3: Add `{:hire, String.t(), String.t()}` to `@spec`**

In `lib/shem/tui/command_dispatch.ex`, replace the `@spec parse` block (lines 4–16) with:

```elixir
  @spec parse(String.t()) ::
          {:start_agent, String.t(), String.t()}
          | {:stop_agent}
          | {:list_agents}
          | {:redteam, String.t()}
          | {:tools}
          | {:trust, String.t()}
          | {:preset_list}
          | {:preset_add, String.t()}
          | {:preset_delete, String.t()}
          | {:hire, String.t(), String.t()}
          | {:llm_routes}
          | {:llm_route, [{atom(), :llama_cpp | :ollama | :openai | :anthropic, String.t()}]}
          | {:error, String.t()}
```

- [ ] **Step 4: Add `/hire` parse clauses**

In `lib/shem/tui/command_dispatch.ex`, inside the `case parts do` block, add two clauses just before the final `_ ->` catch-all (which currently reads `{:error, "unknown command: /#{rest}"}`):

```elixir
      ["hire", name | role_parts] when role_parts != [] ->
        {:hire, name, Enum.join(role_parts, " ")}

      ["hire" | _] ->
        {:error, "usage: /hire <name> <role description>"}
```

The surrounding context should look like:

```elixir
      ["llm" | _] ->
        {:error, "unknown /llm subcommand — try: /llm routes, /llm route <role>=<model>"}

      ["hire", name | role_parts] when role_parts != [] ->
        {:hire, name, Enum.join(role_parts, " ")}

      ["hire" | _] ->
        {:error, "usage: /hire <name> <role description>"}

      _ ->
        {:error, "unknown command: /#{rest}"}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/shem/tui/command_dispatch_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/command_dispatch.ex test/shem/tui/command_dispatch_test.exs
git commit -m "feat: CommandDispatch — parse /hire <name> <role>"
```

---

### Task 2: App — handle `{:hire_complete, name, result}`

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Create: `test/shem/tui/app_hire_test.exs`

Start with the `{:hire_complete}` handler first — it is synchronous and testable in isolation before adding the async Task fire.

- [ ] **Step 1: Create test file with failing tests**

Create `test/shem/tui/app_hire_test.exs`:

```elixir
defmodule Shem.TUI.AppHireTest do
  use ExUnit.Case, async: false

  alias Shem.TUI.App
  alias Shem.Agent.PresetStore

  setup do
    PresetStore.flush()
    :ok
  end

  defp base_model, do: App.init(%{})

  describe "update/2 — {:hire_complete, name, result}" do
    test "on success: stores preset and sets command_output to 'hired: <name>'" do
      model = base_model()
      new_model = App.update(model, {:hire_complete, "researcher", {:ok, "You summarise papers."}})

      assert new_model.command_output == "hired: researcher"
      assert {:ok, %{system_prompt: "You summarise papers.", tools: :all}} =
               PresetStore.get("researcher")
    end

    test "on error: sets command_output to failure message, no preset stored" do
      model = base_model()
      new_model = App.update(model, {:hire_complete, "researcher", {:error, :timeout}})

      assert new_model.command_output =~ "hire failed"
      assert new_model.command_output =~ "timeout"
      assert {:error, :not_found} = PresetStore.get("researcher")
    end

    test "on success: silently overwrites existing preset" do
      PresetStore.put("researcher", %{system_prompt: "old", tools: :all})
      model = base_model()
      App.update(model, {:hire_complete, "researcher", {:ok, "new prompt"}})

      assert {:ok, %{system_prompt: "new prompt"}} = PresetStore.get("researcher")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/tui/app_hire_test.exs 2>&1 | tail -20
```

Expected: 3 failures — `{:hire_complete, ...}` falls through `_ -> model`, leaving `command_output: nil` and preset not stored.

- [ ] **Step 3: Add `{:hire_complete}` clauses to `update/2`**

In `lib/shem/tui/app.ex`, add two clauses before the final `_ -> model` catch-all (currently at line 302):

```elixir
      {:hire_complete, name, {:ok, system_prompt}} ->
        Shem.Agent.PresetStore.put(name, %{system_prompt: system_prompt, tools: :all})
        %{model | command_output: "hired: #{name}"}

      {:hire_complete, name, {:error, reason}} ->
        %{model | command_output: "hire failed: #{inspect(reason)}"}

      _ ->
        model
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/tui/app_hire_test.exs
```

Expected: all 3 tests pass.

- [ ] **Step 5: Run full test suite to check for regressions**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/app.ex test/shem/tui/app_hire_test.exs
git commit -m "feat: App — handle {:hire_complete}, store preset via PresetStore"
```

---

### Task 3: App — fire async LLM call on `/hire`

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Modify: `test/shem/tui/app_hire_test.exs`

The key insight for testing: `App.update/2` runs in the test process when called directly, so `self()` inside `update/2` is the test process. The `Task.start` sends `{:hire_complete, ...}` to that same process, making it catchable with `assert_receive`.

- [ ] **Step 1: Add integration tests to `test/shem/tui/app_hire_test.exs`**

Add a new `describe` block at the bottom of the file (before the final `end`):

```elixir
  describe "update/2 — {:event, @enter} with /hire buffer (integration)" do
    alias Shem.LLM.{Response, StubTransport}

    @enter 13

    setup do
      StubTransport.Server.reset()
      :ok
    end

    test "fires LLM call and sends {:hire_complete, name, {:ok, content}} to caller" do
      StubTransport.Server.push_response(
        {:ok, %Response{content: "You are a researcher.", tokens_used: 10, model: :default, latency_ms: 1}}
      )

      model = %{base_model() | command_buffer: "/hire analyst examines data"}
      new_model = App.update(model, {:event, %{key: @enter}})

      assert new_model.command_buffer == ""
      assert new_model.command_output == "hiring analyst..."
      assert new_model.command_error == nil

      assert_receive {:hire_complete, "analyst", {:ok, "You are a researcher."}}, 2000
    end

    test "on LLM failure: sends {:hire_complete, name, {:error, reason}}" do
      StubTransport.Server.push_response({:error, :transport_down})

      model = %{base_model() | command_buffer: "/hire analyst examines data"}
      App.update(model, {:event, %{key: @enter}})

      assert_receive {:hire_complete, "analyst", {:error, _reason}}, 2000
    end

    test "full round-trip: hire fires, completes, stores preset" do
      StubTransport.Server.push_response(
        {:ok, %Response{content: "Generated prompt.", tokens_used: 5, model: :default, latency_ms: 1}}
      )

      model = %{base_model() | command_buffer: "/hire devops reads logs"}
      after_hire = App.update(model, {:event, %{key: @enter}})

      assert_receive {:hire_complete, "devops", {:ok, "Generated prompt."}}, 2000

      final = App.update(after_hire, {:hire_complete, "devops", {:ok, "Generated prompt."}})
      assert final.command_output == "hired: devops"
      assert {:ok, %{system_prompt: "Generated prompt.", tools: :all}} = PresetStore.get("devops")
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/tui/app_hire_test.exs 2>&1 | tail -30
```

Expected: integration tests fail — `{:hire, name, role}` is not yet handled in the Enter path, so the command falls to `{:error, "unknown command: /hire ..."}`.

- [ ] **Step 3: Add `{:hire, name, role}` clause to Enter handler**

In `lib/shem/tui/app.ex`, inside the `case CommandDispatch.parse(model.command_buffer) do` block (within the `{:event, %{key: @enter}}` handler, around line 159), add the `:hire` clause just before the `{:error, reason}` clause:

```elixir
          {:hire, name, role} ->
            tui_pid = self()

            Task.start(fn ->
              prompt =
                "You are writing a system prompt for an AI agent.\n" <>
                "Role description: \"#{role}\"\n" <>
                "Write a concise system prompt (2-4 sentences) that describes the agent's purpose, approach, and any constraints.\n" <>
                "Return ONLY the system prompt text. No explanation, no preamble, no quotes."

              result = Shem.LLM.complete(%Shem.LLM.Request{prompt: prompt, model: :default})

              case result do
                {:ok, response} ->
                  send(tui_pid, {:hire_complete, name, {:ok, response.content}})

                {:error, reason} ->
                  send(tui_pid, {:hire_complete, name, {:error, reason}})
              end
            end)

            %{model | command_buffer: "", command_output: "hiring #{name}...", command_error: nil}
```

The surrounding context (within the Enter handler's `case CommandDispatch.parse/1` block) should read:

```elixir
          {:llm_routes} ->
            output = format_routes()
            %{model | command_buffer: "", command_output: output, command_error: nil}

          {:hire, name, role} ->
            tui_pid = self()

            Task.start(fn ->
              prompt =
                "You are writing a system prompt for an AI agent.\n" <>
                "Role description: \"#{role}\"\n" <>
                "Write a concise system prompt (2-4 sentences) that describes the agent's purpose, approach, and any constraints.\n" <>
                "Return ONLY the system prompt text. No explanation, no preamble, no quotes."

              result = Shem.LLM.complete(%Shem.LLM.Request{prompt: prompt, model: :default})

              case result do
                {:ok, response} ->
                  send(tui_pid, {:hire_complete, name, {:ok, response.content}})

                {:error, reason} ->
                  send(tui_pid, {:hire_complete, name, {:error, reason}})
              end
            end)

            %{model | command_buffer: "", command_output: "hiring #{name}...", command_error: nil}

          {:error, reason} ->
            %{model | command_error: reason, command_output: nil}
```

- [ ] **Step 4: Run all hire tests**

```bash
mix test test/shem/tui/app_hire_test.exs
```

Expected: all 6 tests pass.

- [ ] **Step 5: Run full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Final commit**

```bash
git add lib/shem/tui/app.ex test/shem/tui/app_hire_test.exs
git commit -m "feat: /hire command — async LLM preset generation via Task"
```
