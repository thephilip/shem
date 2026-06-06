# Phase 11: TUI Trust Surfacing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface trust data in the TUI via `/tools`, `/trust <name>`, and a live dashboard trust summary.

**Architecture:** `Trust.Store` gains `entry/1` for full metadata access. `CommandDispatch` gains two new parse results. `App` gains `command_output` and `trust_counts` model fields, handles the new commands, and populates counts on each tick. The dashboard replaces its static "Lab: idle" label with live band counts. The interactive view's turn card renders `command_output` when no agent is active.

**Tech Stack:** Elixir/OTP, Ratatouille, DETS, ExUnit

---

## File Map

| Action | File |
|---|---|
| Modify | `lib/shem/trust/store.ex` |
| Modify | `test/shem/trust/store_test.exs` |
| Modify | `lib/shem/tui/command_dispatch.ex` |
| Modify | `test/shem/tui/command_dispatch_test.exs` |
| Modify | `lib/shem/tui/app.ex` |
| Modify | `test/shem/tui/app_test.exs` |
| Modify | `lib/shem/tui/views/dashboard.ex` |
| Modify | `test/shem/tui/views/dashboard_test.exs` |
| Modify | `lib/shem/tui/views/interactive.ex` |
| Create | `test/shem/tui/views/interactive_test.exs` |

---

### Task 1: `Trust.Store.entry/1`

**Files:**
- Modify: `lib/shem/trust/store.ex`
- Modify: `test/shem/trust/store_test.exs`

- [ ] **Step 1: Write failing tests**

Add a new `describe` block at the end of `test/shem/trust/store_test.exs`, before the final `end`:

```elixir
  describe "entry/1" do
    test "returns {:error, :unrated} for unknown tool_id" do
      assert {:error, :unrated} = Store.entry("no_such_tool")
    end

    test "returns {:ok, entry} with score, hardening_count, last_updated after record" do
      Store.record("entry_tool_1", %{outcome: :clean, rounds: 1})
      assert {:ok, entry} = Store.entry("entry_tool_1")
      assert_in_delta entry.score, 1.0, 0.001
      assert entry.hardening_count == 1
      assert %DateTime{} = entry.last_updated
    end

    test "hardening_count increments on subsequent records" do
      Store.record("entry_tool_2", %{outcome: :clean, rounds: 1})
      Store.record("entry_tool_2", %{outcome: :clean, rounds: 1})
      assert {:ok, entry} = Store.entry("entry_tool_2")
      assert entry.hardening_count == 2
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/trust/store_test.exs --seed 0 2>&1 | tail -10
```

Expected: 3 failures — `Store.entry/1` undefined.

- [ ] **Step 3: Add `entry/1` public function to `lib/shem/trust/store.ex`**

Add after the `all/0` function (around line 22):

```elixir
  @spec entry(String.t()) :: {:ok, map()} | {:error, :unrated}
  def entry(tool_id) do
    GenServer.call(__MODULE__, {:entry, tool_id})
  end
```

- [ ] **Step 4: Add `handle_call({:entry, ...})` to `lib/shem/trust/store.ex`**

Add after the `handle_call(:all, ...)` clause (around line 81):

```elixir
  def handle_call({:entry, tool_id}, _from, state) do
    result =
      case :dets.lookup(state.table, tool_id) do
        [{^tool_id, entry}] -> {:ok, entry}
        [] -> {:error, :unrated}
      end

    {:reply, result, state}
  end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/shem/trust/store_test.exs --seed 0 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/trust/store.ex test/shem/trust/store_test.exs
git commit -m "feat: Trust.Store.entry/1 — expose full entry for TUI display"
```

---

### Task 2: `CommandDispatch` — `/tools` and `/trust`

**Files:**
- Modify: `lib/shem/tui/command_dispatch.ex`
- Modify: `test/shem/tui/command_dispatch_test.exs`

- [ ] **Step 1: Write failing tests**

Add two new `describe` blocks at the end of `test/shem/tui/command_dispatch_test.exs`, before the final `end`:

```elixir
  describe "parse/1 — /tools command" do
    test "/tools returns {:tools}" do
      assert {:tools} = CommandDispatch.parse("/tools")
    end

    test "/tools with trailing space returns {:tools}" do
      assert {:tools} = CommandDispatch.parse("/tools ")
    end
  end

  describe "parse/1 — /trust command" do
    test "/trust <name> returns {:trust, name}" do
      assert {:trust, "my_tool"} = CommandDispatch.parse("/trust my_tool")
    end

    test "/trust trims whitespace from tool name" do
      assert {:trust, "my_tool"} = CommandDispatch.parse("/trust  my_tool  ")
    end

    test "/trust with no name returns error" do
      assert {:error, msg} = CommandDispatch.parse("/trust")
      assert msg =~ "usage: /trust"
    end

    test "/trust with whitespace-only name returns error" do
      assert {:error, _} = CommandDispatch.parse("/trust   ")
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/tui/command_dispatch_test.exs --seed 0 2>&1 | tail -10
```

Expected: failures — `/tools` and `/trust` parsed as unknown commands.

- [ ] **Step 3: Update `lib/shem/tui/command_dispatch.ex`**

Replace the entire file with:

```elixir
defmodule Shem.TUI.CommandDispatch do
  @spec parse(String.t()) ::
          {:start_agent, String.t(), String.t()}
          | {:stop_agent}
          | {:list_agents}
          | {:redteam, String.t()}
          | {:tools}
          | {:trust, String.t()}
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

      ["tools" | _] ->
        {:tools}

      ["trust" | name_parts] ->
        name = String.trim(Enum.join(name_parts, " "))
        if name == "" do
          {:error, "usage: /trust <tool_name>"}
        else
          {:trust, name}
        end

      ["redteam" | tool_parts] ->
        name = String.trim(Enum.join(tool_parts, " "))
        if name == "" do
          {:error, "usage: /redteam <tool_name>"}
        else
          {:redteam, name}
        end

      _ ->
        {:error, "unknown command: /#{rest}"}
    end
  end

  def parse(text) do
    trimmed = String.trim(text)
    if trimmed == "", do: {:error, "empty input"}, else: {:start_agent, "general", trimmed}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/tui/command_dispatch_test.exs --seed 0 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 5: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/command_dispatch.ex test/shem/tui/command_dispatch_test.exs
git commit -m "feat: CommandDispatch — add /tools and /trust parsing"
```

---

### Task 3: `App` — model fields, command handlers, tick

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Modify: `test/shem/tui/app_test.exs`

- [ ] **Step 1: Write failing tests**

Add new describe blocks at the end of `test/shem/tui/app_test.exs`, before the final `end`:

```elixir
  describe "init/1 — Phase 11 fields" do
    test "model has command_output defaulting to nil" do
      model = App.init(%{})
      assert model.command_output == nil
    end

    test "model has trust_counts defaulting to all-zero map" do
      model = App.init(%{})
      assert model.trust_counts == %{high: 0, medium: 0, low: 0, unrated: 0}
    end
  end

  describe "update/2 — :tick with trust_counts" do
    test ":tick updates trust_counts to a map with the four band keys" do
      model = App.init(%{})
      updated = App.update(model, :tick)
      assert Map.has_key?(updated.trust_counts, :high)
      assert Map.has_key?(updated.trust_counts, :medium)
      assert Map.has_key?(updated.trust_counts, :low)
      assert Map.has_key?(updated.trust_counts, :unrated)
    end
  end

  describe "update/2 — /tools command" do
    test "enter with '/tools' buffer sets command_output and clears buffer" do
      model = %{App.init(%{}) | command_buffer: "/tools"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_buffer == ""
      assert is_binary(result.command_output)
    end
  end

  describe "update/2 — /trust command" do
    test "enter with '/trust unknown_tool' sets command_error for unknown tool" do
      model = %{App.init(%{}) | command_buffer: "/trust __no_such_tool__"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_error =~ "unknown tool"
    end

    test "starting an agent clears command_output" do
      model = %{App.init(%{}) | command_output: "some output", command_buffer: "/agent general do something"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_output == nil
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/tui/app_test.exs --seed 0 2>&1 | tail -10
```

Expected: failures — `command_output` and `trust_counts` not in model.

- [ ] **Step 3: Update `lib/shem/tui/app.ex`**

Replace the entire file with:

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
      command_error: nil,
      command_output: nil,
      trust_counts: %{high: 0, medium: 0, low: 0, unrated: 0}
    }
  end

  @impl true
  def subscribe(_model) do
    Subscription.interval(500, :tick)
  end

  @impl true
  def update(model, msg) do
    case msg do
      {:event, %{ch: ?d, key: 0}} when model.command_buffer == "" ->
        %{model | mode: :dashboard}

      {:event, %{ch: ?i, key: 0}} when model.command_buffer == "" ->
        %{model | mode: :interactive}

      {:event, %{key: @space}} when model.command_buffer == "" ->
        %{model | paused: !model.paused}

      {:event, %{key: @esc}} when model.command_buffer == "" ->
        %{model | paused: true}

      {:event, %{ch: ?/}} when model.command_buffer == "" ->
        %{model | command_buffer: "/"}

      {:event, %{key: @backspace}} ->
        buf = model.command_buffer
        %{model | command_buffer: if(buf == "", do: "", else: String.slice(buf, 0..-2//1))}

      {:event, %{ch: ch}} when model.command_buffer != "" and ch > 0 ->
        %{model | command_buffer: model.command_buffer <> <<ch::utf8>>}

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
                %{model | command_buffer: "", focused_agent: name, command_error: nil, command_output: nil}

              {:error, reason} ->
                %{model | command_error: "failed to start agent: #{inspect(reason)}"}
            end

          {:stop_agent} ->
            if model.focused_agent, do: Shem.Agent.stop(model.focused_agent)
            %{model | command_buffer: "", command_error: nil}

          {:list_agents} ->
            %{model | command_buffer: "", command_error: nil}

          {:tools} ->
            output = format_tools()
            %{model | command_buffer: "", command_output: output, command_error: nil}

          {:trust, tool_name} ->
            case Shem.Lab.Registry.lookup_by_name(tool_name) do
              {:ok, tool} ->
                output = format_trust(tool)
                %{model | command_buffer: "", command_output: output, command_error: nil}

              {:error, :not_found} ->
                %{model | command_error: "unknown tool: #{tool_name}"}
            end

          {:redteam, tool_name} ->
            case Shem.Lab.Registry.lookup_by_name(tool_name) do
              {:ok, tool} ->
                Shem.Adversarial.start_hardening(tool.id)
                %{model | command_buffer: "", command_error: nil}

              {:error, :not_found} ->
                %{model | command_error: "unknown tool: #{tool_name}"}
            end

          {:error, reason} ->
            %{model | command_error: reason}
        end

      :tick ->
        %{
          model
          | event_log_stats: safe_stats(),
            tool_count: safe_tool_count(),
            mcp_client_count: safe_mcp_count(),
            mcp_outbound_count: safe_mcp_outbound_count(),
            cluster_node_count: safe_cluster_count(),
            agents: safe_agent_list(),
            agent_view: safe_agent_view(model.focused_agent),
            trust_counts: safe_trust_counts()
        }

      _ ->
        model
    end
  end

  @impl true
  def render(model) do
    case model.mode do
      :dashboard -> Dashboard.render(model)
      :interactive -> Interactive.render(model)
    end
  end

  defp format_tools do
    tools = Shem.Lab.Registry.all()
    scored = Shem.Trust.Store.all()

    if tools == [] do
      "No Lab tools graduated yet."
    else
      header = "Lab Tools (#{length(tools)})\n"

      lines =
        Enum.map(tools, fn tool ->
          {band, hardenings} =
            case Map.fetch(scored, tool.id) do
              {:ok, score} ->
                count =
                  case Shem.Trust.Store.entry(tool.id) do
                    {:ok, entry} -> entry.hardening_count
                    _ -> 0
                  end

                {score_to_band(score), count}

              :error ->
                {:unrated, 0}
            end

          count_str = if hardenings == 1, do: "1 hardening", else: "#{hardenings} hardenings"
          "  #{String.pad_trailing(tool.name, 24)} #{String.pad_trailing(to_string(band), 10)} #{count_str}"
        end)

      header <> Enum.join(lines, "\n")
    end
  end

  defp format_trust(tool) do
    case Shem.Trust.Store.entry(tool.id) do
      {:ok, entry} ->
        band = score_to_band(entry.score)
        updated = Calendar.strftime(entry.last_updated, "%Y-%m-%d %H:%M:%SZ")

        "#{tool.name}\n" <>
          "  band:       #{band}\n" <>
          "  score:      #{Float.round(entry.score, 3)}\n" <>
          "  hardenings: #{entry.hardening_count}\n" <>
          "  updated:    #{updated}"

      {:error, :unrated} ->
        "#{tool.name}\n  band: unrated\n  never hardened"
    end
  end

  defp safe_trust_counts do
    try do
      all_tools = Shem.Lab.Registry.all()
      scored = Shem.Trust.Store.all()
      base = %{high: 0, medium: 0, low: 0, unrated: 0}

      Enum.reduce(all_tools, base, fn tool, acc ->
        band =
          case Map.fetch(scored, tool.id) do
            {:ok, score} -> score_to_band(score)
            :error -> :unrated
          end

        Map.update!(acc, band, &(&1 + 1))
      end)
    catch
      :exit, _ -> %{high: 0, medium: 0, low: 0, unrated: 0}
    end
  end

  defp score_to_band(score) when score >= 0.8, do: :high
  defp score_to_band(score) when score >= 0.5, do: :medium
  defp score_to_band(_), do: :low

  defp safe_stats do
    try do
      Shem.EventLog.stats()
    catch
      :exit, _ -> %{sessions: 0, total_events: 0}
    end
  end

  defp safe_tool_count do
    try do
      Shem.Lab.Registry.all() |> length()
    catch
      :exit, _ -> 0
    end
  end

  defp safe_mcp_count do
    try do
      Shem.MCP.SessionRegistry.client_count()
    catch
      :exit, _ -> 0
    end
  end

  defp safe_mcp_outbound_count do
    try do
      Shem.MCP.Client.connected_servers()
      |> Enum.count(&(&1.status == :ready))
    catch
      :exit, _ -> 0
    end
  end

  defp safe_cluster_count do
    Shem.Cluster.nodes() |> length()
  end

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
          case GenServer.call(pid, :session_id, 200) do
            session_id when is_binary(session_id) ->
              case AgentView.build(session_id) do
                {:ok, view} -> %{view | agent_name: name}
                :not_found -> nil
              end

            _ ->
              nil
          end
      end
    catch
      :exit, _ -> nil
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/tui/app_test.exs --seed 0 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/app.ex test/shem/tui/app_test.exs
git commit -m "feat: App — command_output, trust_counts, /tools and /trust handlers"
```

---

### Task 4: Dashboard trust summary

**Files:**
- Modify: `lib/shem/tui/views/dashboard.ex`
- Modify: `test/shem/tui/views/dashboard_test.exs`

- [ ] **Step 1: Update `base_model` and write failing tests**

In `test/shem/tui/views/dashboard_test.exs`, update `base_model/0` to include the new fields, and add two new tests at the end.

Replace the `base_model/0` function with:

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
      command_error: nil,
      command_output: nil,
      trust_counts: %{high: 0, medium: 0, low: 0, unrated: 0}
    }
  end
```

Add these tests at the end of the file, before the final `end`:

```elixir
  test "render/1 shows trust band counts from model.trust_counts" do
    model = %{base_model() | trust_counts: %{high: 2, medium: 1, low: 0, unrated: 3}}
    rendered = Dashboard.render(model) |> inspect(limit: :infinity)
    assert rendered =~ "2"
    assert rendered =~ "high"
    assert rendered =~ "3"
    assert rendered =~ "unrated"
  end

  test "render/1 no longer shows 'Lab: idle' static string" do
    rendered = Dashboard.render(base_model()) |> inspect(limit: :infinity)
    refute rendered =~ "Lab: idle"
  end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/tui/views/dashboard_test.exs --seed 0 2>&1 | tail -10
```

Expected: the "no longer shows Lab: idle" test fails (the string is still there).

- [ ] **Step 3: Update `lib/shem/tui/views/dashboard.ex`**

Replace the `"Lab: idle"` label block. Find this in `render/1`:

```elixir
            label(
              content: "Lab: idle",
              attributes: [attribute(:bold)],
              color: color(:magenta)
            )
```

Replace it with:

```elixir
            label(
              content: trust_summary(model.trust_counts),
              attributes: [attribute(:bold)],
              color: color(:magenta)
            )
```

Add this private function at the bottom of the file, before the final `end`:

```elixir
  defp trust_summary(%{high: h, medium: m, low: l, unrated: u}) do
    "Trust: #{h} high  #{m} med  #{l} low  #{u} unrated"
  end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/tui/views/dashboard_test.exs --seed 0 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 5: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/views/dashboard.ex test/shem/tui/views/dashboard_test.exs
git commit -m "feat: Dashboard — replace 'Lab: idle' with live trust band counts"
```

---

### Task 5: Interactive view — `command_output` in turn card

**Files:**
- Modify: `lib/shem/tui/views/interactive.ex`
- Create: `test/shem/tui/views/interactive_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/shem/tui/views/interactive_test.exs`:

```elixir
defmodule Shem.TUI.Views.InteractiveTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.Views.Interactive

  defp base_model do
    %{
      mode: :interactive,
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
      command_error: nil,
      command_output: nil,
      trust_counts: %{high: 0, medium: 0, low: 0, unrated: 0}
    }
  end

  test "render/1 returns a Ratatouille view element" do
    result = Interactive.render(base_model())
    assert is_map(result)
    assert result.tag == :view
  end

  test "render/1 shows 'No active session' when agent_view is nil and command_output is nil" do
    rendered = Interactive.render(base_model()) |> inspect(limit: :infinity)
    assert rendered =~ "No active session"
  end

  test "render/1 shows command_output content when agent_view is nil and command_output is set" do
    model = %{base_model() | command_output: "Lab Tools (2)\n  my_tool   high   3 hardenings"}
    rendered = Interactive.render(model) |> inspect(limit: :infinity)
    assert rendered =~ "my_tool"
    assert rendered =~ "high"
    refute rendered =~ "No active session"
  end

  test "render/1 shows agent view (not command_output) when agent_view is set" do
    agent_view = %{
      status: :running,
      turn_count: 1,
      max_turns: 10,
      current_reasoning: "thinking...",
      last_tool_call: nil,
      history: [],
      recent_events: [],
      agent_name: "agent_1"
    }
    model = %{base_model() | agent_view: agent_view, focused_agent: "agent_1", command_output: "some output"}
    rendered = Interactive.render(model) |> inspect(limit: :infinity)
    assert rendered =~ "thinking..."
    refute rendered =~ "some output"
  end
end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/tui/views/interactive_test.exs --seed 0 2>&1 | tail -10
```

Expected: the "shows command_output" test fails — currently renders "No active session" regardless.

- [ ] **Step 3: Update `lib/shem/tui/views/interactive.ex`**

Add a new `render_turn_card/1` clause between the existing two clauses. Find:

```elixir
  defp render_turn_card(%{agent_view: nil}) do
```

Insert this new clause BEFORE it:

```elixir
  defp render_turn_card(%{agent_view: nil, command_output: output}) when not is_nil(output) do
    panel(title: "Shem // Interactive · Output", color: color(:cyan)) do
      for line <- String.split(output, "\n") do
        label(content: line, color: color(:white))
      end
    end
  end

```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/tui/views/interactive_test.exs --seed 0 2>&1 | tail -5
```

Expected: all 4 tests pass.

- [ ] **Step 5: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/views/interactive.ex test/shem/tui/views/interactive_test.exs
git commit -m "feat: Interactive view — render command_output in turn card when no active agent"
```

---

## Self-Review

**Spec coverage:**
- ✅ `Trust.Store.entry/1` returns full entry — Task 1
- ✅ `/tools` command → `{:tools}` — Task 2
- ✅ `/trust <name>` command → `{:trust, name}` — Task 2
- ✅ `/trust` no name → error — Task 2
- ✅ `command_output` model field — Task 3
- ✅ `trust_counts` model field — Task 3
- ✅ `/tools` handler formats Lab tools with band + hardening count — Task 3
- ✅ `/trust <name>` handler formats full entry; unknown tool sets command_error — Task 3
- ✅ Starting agent clears `command_output` — Task 3
- ✅ `:tick` populates `trust_counts` via `safe_trust_counts/0` — Task 3
- ✅ Unrated tools counted by comparing Lab.Registry vs Trust.Store keys — Task 3 (`safe_trust_counts/0`)
- ✅ Dashboard replaces "Lab: idle" with trust band counts — Task 4
- ✅ Interactive turn card renders `command_output` when agent_view is nil — Task 5
- ✅ Agent view takes priority over `command_output` when active — Task 5

**Placeholder scan:** None.

**Type consistency:**
- `Trust.Store.entry/1` defined in Task 1, called in Task 3 (`format_tools/0`, `format_trust/1`) ✅
- `score_to_band/1` defined once in `App` (Task 3), used in `safe_trust_counts/0` and `format_tools/0` ✅
- `trust_counts` map shape `%{high:, medium:, low:, unrated:}` consistent across Task 3 init, Task 3 tick, Task 4 render, Task 5 base_model ✅
- `command_output` is `nil | string` throughout Tasks 3, 4, 5 ✅
