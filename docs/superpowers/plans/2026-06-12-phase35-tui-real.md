# Phase 35 — TUI: Make It Real — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the TUI's remaining placeholder data with live values and add the four interaction upgrades from the spec: agent list panel with arrow-key focus, slash-command autocomplete, multiline prompt input, and a readable conversation transcript in the history view.

**Architecture:** The Ratatouille app loop (`Shem.TUI.App`) already polls most data on `:tick`; this phase extends the model with system/budget stats (throttled to every 10th tick), adds two new pure modules (`SystemStats`, `Autocomplete`), one new `Agent.Server` call (`:info`, replacing two calls with one), and a pure `AgentView.transcript/1` fold. Views are restructured, not redesigned. No changes to the Ratatouille runtime supervisor or the ex_termbox waf patch.

**Tech Stack:** Elixir, Ratatouille 0.5 / ex_termbox 1.0.2, `:os_mon` (cpu_sup/memsup), existing EventLog/BudgetServer/StreamSink.

**Spec:** `docs/superpowers/specs/2026-06-11-phase35-tui-real-design.md`

**Deliberate deviations from spec (verified against reality, document in commit messages where relevant):**
1. **Token spend, not dollars.** `LLM.BudgetServer` tracks tokens (`tokens_used` / `global_limit`), not dollars, and nothing tracks lifetime spend. The dashboard shows `Tokens: <used> / <limit> session`. Building a persistent dollar ledger is out of scope (YAGNI — belongs with budget work in Phase 37 if ever).
2. **Alt+Enter, not Shift+Enter, for newline.** Terminals send the same byte (CR) for Enter and Shift+Enter; termbox cannot distinguish them (the `ExTermbox.Event.mod` field only reports Alt). Alt+Enter is detectable (`mod: 1`) and is the established TUI convention. The status-bar hint documents it.
3. **GPU omitted** from system stats (spec explicitly allows: "GPU optional/omitted if unavailable").
4. The dashboard's MCP/cluster/trust/session labels are **already live** (spec's table was written against an older snapshot) — only agent count, CPU/MEM, spend, and the hardcoded `localhost` host string need wiring.

**Key codebase facts for the implementer (verified):**
- `Shem.TUI.App.update/2` is a flat `case msg do` with pattern-match clauses — **clause order matters**. Mode-specific clauses (`:multiline_input`, `:history`) come before normal-mode clauses. New clauses must be placed exactly where each task says.
- Key constants in app.ex: `@esc 27`, `@backspace 127`, `@space ?\s`, `@enter 13`, `@tab 9`, `@arrow_up 65517`, `@arrow_down 65516`, `@ctrl_k 11`.
- Events arrive as `{:event, %ExTermbox.Event{}}` — fields `type, mod, key, ch, ...`; `mod: 1` = Alt.
- `:tick` fires every 100ms (`Subscription.interval(100, :tick)`).
- All data accessors in app.ex are `safe_*` functions wrapping calls in `try/catch :exit` with neutral fallbacks — every new accessor must follow this pattern (the TUI must never crash because a GenServer is down).
- `Shem.LLM.BudgetServer.status/0` returns the full state map: `%{global_limit: int, soft_threshold: float, tokens_used: int, soft_warned?: bool}`.
- `:os_mon` is NOT currently in `extra_applications` (mix.exs line 18: `[:logger]`).
- `Agent.Server` has `handle_call(:status)` → `{:ok, status}` and `handle_call(:session_id)` → bare binary. State has `:status`, `:turn_count`, `:session_id` fields.
- `CommandDispatch.commands/0` returns `[{cmd_string, description}]` (18 entries; several share a first token, e.g. three `/preset ...` variants).
- `AgentView.from_events/1` folds EventLog events; `:llm_call_completed` payload has `[:content]`; `:agent_tool_result` payload has `[:tool]` AND `[:result]`; `:agent_started` payload has `[:task]`; `:user_message` payload has `[:content]`.
- TUI tests live in `test/shem/tui/`; they call `App.update(model, msg)` / pure functions directly, `async: false`. `App.init(%{})` builds a model but triggers Welcome-marker file I/O — tests build models by hand or via helper (see existing `test/shem/tui/app_test.exs` for the established pattern — read it before writing App tests).
- Run only the named test files during a task; the full suite runs in Task 6.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/shem/tui/system_stats.ex` (create) | os_mon polling + formatting, nil-safe |
| `lib/shem/tui/autocomplete.ex` (create) | pure suggestion/completion logic |
| `lib/shem/tui/app.ex` (modify) | model fields, tick throttling, arrow/Tab/Alt+Enter clauses |
| `lib/shem/tui/views/dashboard.ex` (modify) | live agent count, tokens, CPU/MEM, mcp_host |
| `lib/shem/tui/views/interactive.ex` (modify) | 3-column layout (agent list / output / events), autocomplete overlay, multiline prompt |
| `lib/shem/tui/views/history.ex` (modify) | transcript rendering in detail pane |
| `lib/shem/agent/server.ex` (modify) | add `handle_call(:info)` |
| `lib/shem/tui/agent_view.ex` (modify) | add `transcript/1` |
| `mix.exs` (modify) | add `:os_mon` to extra_applications |

---

### Task 1: SystemStats + live dashboard data

**Files:**
- Modify: `mix.exs` (line ~18)
- Create: `lib/shem/tui/system_stats.ex`
- Modify: `lib/shem/tui/app.ex` (model init, `:tick` clause, new safe helpers)
- Modify: `lib/shem/tui/views/dashboard.ex` (lines 10–18, 26–30)
- Test: `test/shem/tui/system_stats_test.exs` (create), `test/shem/tui/app_test.exs` (append)

- [ ] **Step 1: Add `:os_mon` to mix.exs**

```elixir
      extra_applications: [:logger, :os_mon],
```

Run `mix compile` to confirm it boots. Note: os_mon may print alarm reports at startup in dev — that's expected and harmless.

- [ ] **Step 2: Write the failing tests for SystemStats**

`test/shem/tui/system_stats_test.exs`:

```elixir
defmodule Shem.TUI.SystemStatsTest do
  use ExUnit.Case, async: false

  alias Shem.TUI.SystemStats

  test "empty/0 returns all-nil stats" do
    assert SystemStats.empty() == %{cpu: nil, mem_used_mb: nil, mem_total_mb: nil}
  end

  test "collect/0 returns a map with the three keys and never raises" do
    stats = SystemStats.collect()
    assert Map.keys(stats) |> Enum.sort() == [:cpu, :mem_total_mb, :mem_used_mb]
  end

  test "format/1 renders dashes when nothing is available" do
    assert SystemStats.format(SystemStats.empty()) == "CPU: --   MEM: --"
  end

  test "format/1 renders cpu and memory when present" do
    assert SystemStats.format(%{cpu: 12.5, mem_used_mb: 3200, mem_total_mb: 16000}) ==
             "CPU: 12.5%   MEM: 3200/16000 MB"
  end

  test "format/1 renders partial data" do
    assert SystemStats.format(%{cpu: nil, mem_used_mb: 3200, mem_total_mb: 16000}) ==
             "CPU: --   MEM: 3200/16000 MB"

    assert SystemStats.format(%{cpu: 7.0, mem_used_mb: nil, mem_total_mb: nil}) ==
             "CPU: 7.0%   MEM: --"
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `mix test test/shem/tui/system_stats_test.exs`
Expected: FAIL — module not available

- [ ] **Step 4: Implement SystemStats**

`lib/shem/tui/system_stats.ex`:

```elixir
defmodule Shem.TUI.SystemStats do
  @moduledoc """
  Host metrics for the dashboard, via :os_mon (cpu_sup + memsup).

  Every accessor degrades to nil instead of raising — os_mon may be missing
  on some platforms, still warming up, or its servers may be restarting.
  """

  @type t :: %{
          cpu: number() | nil,
          mem_used_mb: non_neg_integer() | nil,
          mem_total_mb: non_neg_integer() | nil
        }

  @spec empty() :: t()
  def empty, do: %{cpu: nil, mem_used_mb: nil, mem_total_mb: nil}

  @spec collect() :: t()
  def collect do
    %{cpu: cpu_percent(), mem_used_mb: nil, mem_total_mb: nil}
    |> put_memory()
  end

  @spec format(t()) :: String.t()
  def format(stats) do
    cpu =
      case stats.cpu do
        nil -> "--"
        n -> "#{n}%"
      end

    mem =
      case stats do
        %{mem_used_mb: used, mem_total_mb: total} when is_integer(used) and is_integer(total) ->
          "#{used}/#{total} MB"

        _ ->
          "--"
      end

    "CPU: #{cpu}   MEM: #{mem}"
  end

  defp cpu_percent do
    case :cpu_sup.util() do
      util when is_number(util) -> Float.round(util * 1.0, 1)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp put_memory(stats) do
    case :memsup.get_system_memory_data() do
      data when is_list(data) ->
        total = Keyword.get(data, :total_memory) || Keyword.get(data, :system_total_memory)
        avail = Keyword.get(data, :available_memory) || Keyword.get(data, :free_memory)

        case total do
          t when is_integer(t) ->
            used = t - (avail || 0)
            %{stats | mem_used_mb: div(used, 1_048_576), mem_total_mb: div(t, 1_048_576)}

          _ ->
            stats
        end

      _ ->
        stats
    end
  rescue
    _ -> stats
  catch
    :exit, _ -> stats
  end
end
```

- [ ] **Step 5: Run to verify pass**

Run: `mix test test/shem/tui/system_stats_test.exs`
Expected: 5 tests, 0 failures

- [ ] **Step 6: Wire into App model + tick (throttled)**

In `lib/shem/tui/app.ex`:

a) Add to the `init/1` model map:

```elixir
      tick_count: 0,
      system_stats: Shem.TUI.SystemStats.empty(),
      budget: %{tokens_used: 0, global_limit: 0},
```

b) In the `:tick` clause, change the first model update to increment the counter and refresh slow stats every 10th tick (1s — `cpu_sup.util/0` measures utilization since its previous call, so 10Hz polling would produce noise):

```elixir
      :tick ->
        tick_count = model.tick_count + 1

        {system_stats, budget} =
          if rem(tick_count, 10) == 1 do
            {Shem.TUI.SystemStats.collect(), safe_budget()}
          else
            {model.system_stats, model.budget}
          end

        model = %{
          model
          | tick_count: tick_count,
            system_stats: system_stats,
            budget: budget,
            event_log_stats: safe_stats(),
            tool_count: safe_tool_count(),
            mcp_client_count: safe_mcp_count(),
            mcp_outbound_count: safe_mcp_outbound_count(),
            cluster_node_count: safe_cluster_count(),
            agents: safe_agent_list(),
            agent_view: safe_agent_view(model.focused_agent),
            trust_counts: safe_trust_counts()
        }
```

(The rest of the `:tick` clause — stream-sink draining, streaming-buffer clearing, shadow update — is untouched.)

c) Add the safe accessor with the other `safe_*` helpers:

```elixir
  defp safe_budget do
    try do
      status = Shem.LLM.BudgetServer.status()
      %{tokens_used: status.tokens_used, global_limit: status.global_limit}
    catch
      :exit, _ -> %{tokens_used: 0, global_limit: 0}
    end
  end
```

- [ ] **Step 7: Live dashboard labels**

In `lib/shem/tui/views/dashboard.ex` replace the three placeholder labels (lines 10–18):

```elixir
            label(content: agents_line(model.agents), color: color(:white))
            label(content: "")
            label(content: Shem.TUI.SystemStats.format(model.system_stats), color: color(:cyan))
            label(content: "")

            label(
              content: "Tokens: #{model.budget.tokens_used} / #{model.budget.global_limit} session",
              color: color(:yellow)
            )
```

Replace the hardcoded `localhost` in the MCP label (line ~28):

```elixir
            label(
              content:
                "MCP: #{Application.get_env(:shem, :mcp_host, "127.0.0.1")}:#{Application.get_env(:shem, :mcp_port, 4000)} — #{model.mcp_client_count} connected",
              color: color(:cyan)
            )
```

Add private helpers at the bottom:

```elixir
  defp agents_line(agents) do
    running = Enum.count(agents, &(&1.status == :running))
    "Agents: #{length(agents)} active (#{running} running)"
  end
```

- [ ] **Step 8: App test for the tick wiring** (append to `test/shem/tui/app_test.exs`, following its existing model-construction pattern — read the file first)

```elixir
  describe "dashboard live stats" do
    test ":tick populates system_stats and budget on the first tick" do
      model = base_model()
      updated = App.update(model, :tick)
      assert %{cpu: _, mem_used_mb: _, mem_total_mb: _} = updated.system_stats
      assert %{tokens_used: used, global_limit: limit} = updated.budget
      assert is_integer(used) and is_integer(limit)
      assert updated.tick_count == 1
    end

    test ":tick only refreshes system stats every 10th tick" do
      model = %{base_model() | tick_count: 1, system_stats: %{cpu: 99.9, mem_used_mb: 1, mem_total_mb: 2}}
      updated = App.update(model, :tick)
      # tick 2: not a refresh tick — stats carried over unchanged
      assert updated.system_stats == %{cpu: 99.9, mem_used_mb: 1, mem_total_mb: 2}
    end
  end
```

If `app_test.exs` has no `base_model/0` helper, add one that builds the full init map by hand (copy the map from `App.init/1`, replacing the Welcome check with `show_welcome: false`) — do NOT call `App.init/1` in tests (it touches the welcome marker file).

- [ ] **Step 9: Run the TUI tests**

Run: `mix test test/shem/tui/`
Expected: all pass

- [ ] **Step 10: Commit**

```bash
git add mix.exs lib/shem/tui/system_stats.ex lib/shem/tui/app.ex lib/shem/tui/views/dashboard.ex test/shem/tui/system_stats_test.exs test/shem/tui/app_test.exs
git commit -m "feat: live dashboard — agent count, os_mon CPU/MEM, token budget, mcp_host"
```

---

### Task 2: Agent.Server :info call + agent list panel + arrow-key focus

**Files:**
- Modify: `lib/shem/agent/server.ex` (after `handle_call(:session_id)`, ~line 28)
- Modify: `lib/shem/tui/app.ex` (`safe_agent_list/0`, Tab clause, new arrow clauses)
- Modify: `lib/shem/tui/views/interactive.ex` (layout restructure)
- Test: `test/shem/agent/server_test.exs` (append), `test/shem/tui/app_test.exs` (append)

- [ ] **Step 1: Failing test for `:info`** (append to `test/shem/agent/server_test.exs`, which has `stub/1` and `start_agent/2` helpers)

```elixir
  describe ":info call" do
    test "returns status, turn_count and session_id in one call" do
      stub("done")
      name = start_agent("info test")
      assert {:ok, :done} = Agent.await(name, 2_000)

      pid = GenServer.whereis(Shem.ProcessRegistry.via_tuple(name))
      info = GenServer.call(pid, :info)
      assert %{status: :done, turn_count: 1, session_id: "ses_" <> _} = info
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/shem/agent/server_test.exs`
Expected: FAIL — `FunctionClauseError` (no `handle_call(:info, ...)` clause) or similar

- [ ] **Step 3: Implement `:info`** — in `lib/shem/agent/server.ex`, after the `handle_call(:session_id, ...)` clause:

```elixir
  def handle_call(:info, _from, state) do
    {:reply,
     %{status: state.status, turn_count: state.turn_count, session_id: state.session_id}, state}
  end
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/shem/agent/server_test.exs`
Expected: all pass

- [ ] **Step 5: Use `:info` in `safe_agent_list/0`** — in `lib/shem/tui/app.ex`, replace the body of the `Enum.map` (currently two `GenServer.call`s per agent) with one:

```elixir
  defp safe_agent_list do
    try do
      Horde.DynamicSupervisor.which_children(Shem.AgentSupervisor)
      |> Enum.filter(fn {_id, pid, _, _} -> is_pid(pid) end)
      |> Enum.map(fn {id, pid, _, _} ->
        case safe_info(pid) do
          %{status: status, turn_count: turns, session_id: sid} ->
            %{name: id, pid: pid, status: status, session_id: sid, turn_count: turns}

          nil ->
            %{name: id, pid: pid, status: :unknown, session_id: nil, turn_count: 0}
        end
      end)
    catch
      :exit, _ -> []
    end
  end

  defp safe_info(pid) do
    try do
      GenServer.call(pid, :info, 100)
    catch
      :exit, _ -> nil
    end
  end
```

- [ ] **Step 6: Arrow-key focus cycling** — in `lib/shem/tui/app.ex`:

a) Replace the existing Tab clause's body with a call to a shared helper, and add arrow clauses. The arrow clauses go right after the Tab clause (their guards are disjoint from history mode — those clauses match `mode == :history` earlier — and from autocomplete, which guards on `command_buffer` starting with `/`):

```elixir
      {:event, %{key: @tab}} when model.command_buffer == "" ->
        cycle_focus(model, 1)

      {:event, %{key: @arrow_down}} when model.mode == :interactive and model.command_buffer == "" ->
        cycle_focus(model, 1)

      {:event, %{key: @arrow_up}} when model.mode == :interactive and model.command_buffer == "" ->
        cycle_focus(model, -1)
```

b) Add the helper (private, near `start_stream_sink_for_focused/1`):

```elixir
  defp cycle_focus(model, delta) do
    case model.agents do
      [] ->
        model

      agents ->
        names = Enum.map(agents, & &1.name)

        idx =
          case model.focused_agent do
            nil ->
              if delta > 0, do: 0, else: length(names) - 1

            current ->
              current_idx = Enum.find_index(names, &(&1 == current)) || 0
              rem(current_idx + delta + length(names), length(names))
          end

        model = %{model | focused_agent: Enum.at(names, idx)}
        start_stream_sink_for_focused(model)
    end
  end
```

- [ ] **Step 7: Interactive layout — left agent list, center output, right events** — in `lib/shem/tui/views/interactive.ex`, replace the main `render/1` (non-multiline clause) layout:

```elixir
  def render(model) do
    view do
      row do
        column(size: 3) do
          render_agent_list(model)
        end

        column(size: 6) do
          render_turn_card(model)
        end

        column(size: 3) do
          render_event_log(model)
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
```

Replace `render_agent_switcher/1` (both clauses) with a vertical list panel:

```elixir
  defp render_agent_list(%{agents: []}) do
    panel(title: "Agents", color: color(:white)) do
      label(content: "none running", color: color(:white))
      label(content: "")
      label(content: "type a task +", color: color(:cyan))
      label(content: "Enter to start", color: color(:cyan))
    end
  end

  defp render_agent_list(%{agents: agents, focused_agent: focused}) do
    panel(title: "Agents (#{length(agents)})", color: color(:white)) do
      for a <- agents do
        marker = if a.name == focused, do: "●", else: "○"

        [
          label(
            content: "#{marker} #{a.name}",
            color: if(a.name == focused, do: color(:cyan), else: color(:white)),
            attributes: if(a.name == focused, do: [attribute(:bold)], else: [])
          ),
          label(content: "  #{agent_status_dot(a.status)} #{a.status} · t#{a.turn_count}", color: agent_status_color(a.status))
        ]
      end
    end
  end

  defp agent_status_dot(:running), do: "▶"
  defp agent_status_dot(:done), do: "✓"
  defp agent_status_dot(:error), do: "✗"
  defp agent_status_dot(:waiting), do: "◌"
  defp agent_status_dot(_), do: "?"

  defp agent_status_color(:running), do: color(:cyan)
  defp agent_status_color(:done), do: color(:green)
  defp agent_status_color(:error), do: color(:red)
  defp agent_status_color(:waiting), do: color(:yellow)
  defp agent_status_color(_), do: color(:white)
```

Also update the multiline `render/1` clause (the `:multiline_input` preset editor): it calls `render_agent_switcher(model)` in its bottom row — change that call to nothing (delete that bottom `row` block from the multiline clause; the preset editor doesn't need the agent list).

Update the hint line: in `prompt_title/1`, change the default clause to:

```elixir
  defp prompt_title(_), do: "d=Dashboard  ↑↓/Tab=agents  /=command  Alt+Enter=newline"
```

- [ ] **Step 8: App tests for cycling** (append to `test/shem/tui/app_test.exs`)

```elixir
  describe "agent focus cycling" do
    @arrow_up 65517
    @arrow_down 65516

    defp with_agents(model) do
      agents = [
        %{name: "agent_A", pid: self(), status: :running, session_id: nil, turn_count: 1},
        %{name: "agent_B", pid: self(), status: :done, session_id: nil, turn_count: 2}
      ]

      %{model | mode: :interactive, agents: agents}
    end

    test "arrow down focuses the first agent when none focused" do
      model = with_agents(base_model())
      updated = App.update(model, {:event, %{key: @arrow_down, ch: 0, mod: 0}})
      assert updated.focused_agent == "agent_A"
    end

    test "arrow down cycles forward and wraps" do
      model = %{with_agents(base_model()) | focused_agent: "agent_B"}
      updated = App.update(model, {:event, %{key: @arrow_down, ch: 0, mod: 0}})
      assert updated.focused_agent == "agent_A"
    end

    test "arrow up cycles backward" do
      model = %{with_agents(base_model()) | focused_agent: "agent_A"}
      updated = App.update(model, {:event, %{key: @arrow_up, ch: 0, mod: 0}})
      assert updated.focused_agent == "agent_B"
    end

    test "arrows do nothing while typing a command" do
      model = %{with_agents(base_model()) | command_buffer: "/age"}
      updated = App.update(model, {:event, %{key: @arrow_down, ch: 0, mod: 0}})
      assert updated.focused_agent == nil
    end
  end
```

Note: `cycle_focus` calls `start_stream_sink_for_focused/1`, which looks up the agent in the registry — for unregistered fake names it falls through safely and returns the model. If the events in these tests need other fields (e.g. `type:`), match the event-map shape used by existing tests in this file.

- [ ] **Step 9: Run the TUI + agent tests**

Run: `mix test test/shem/tui/ test/shem/agent/server_test.exs`
Expected: all pass

- [ ] **Step 10: Commit**

```bash
git add lib/shem/agent/server.ex lib/shem/tui/app.ex lib/shem/tui/views/interactive.ex test/shem/agent/server_test.exs test/shem/tui/app_test.exs
git commit -m "feat: agent list panel with arrow-key focus; Agent.Server :info call"
```

---

### Task 3: Slash-command autocomplete

**Files:**
- Create: `lib/shem/tui/autocomplete.ex`
- Modify: `lib/shem/tui/app.ex` (model field, arrow/Tab/typing clauses)
- Modify: `lib/shem/tui/views/interactive.ex` (overlay panel)
- Test: `test/shem/tui/autocomplete_test.exs` (create), `test/shem/tui/app_test.exs` (append)

- [ ] **Step 1: Failing tests for the pure module**

`test/shem/tui/autocomplete_test.exs`:

```elixir
defmodule Shem.TUI.AutocompleteTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.Autocomplete

  @commands [
    {"/help", "Show this command list (searchable)"},
    {"/preset <name>", "Switch preset"},
    {"/preset list", "List all available presets"},
    {"/agents", "List all running agents"},
    {"/agent <preset> <task>", "Start an agent"}
  ]

  describe "suggest/2" do
    test "matches commands whose first token starts with the typed token" do
      suggestions = Autocomplete.suggest("/pre", @commands)
      assert Enum.map(suggestions, &elem(&1, 0)) == ["/preset <name>", "/preset list"]
    end

    test "bare slash suggests everything" do
      assert length(Autocomplete.suggest("/", @commands)) == 5
    end

    test "matching is on the first token only — arguments don't break it" do
      suggestions = Autocomplete.suggest("/agent gen", @commands)
      assert Enum.map(suggestions, &elem(&1, 0)) == ["/agent <preset> <task>"]
    end

    test "/agents and /agent are distinct prefixes" do
      suggestions = Autocomplete.suggest("/agents", @commands)
      assert Enum.map(suggestions, &elem(&1, 0)) == ["/agents"]
    end

    test "non-slash buffers suggest nothing" do
      assert Autocomplete.suggest("hello", @commands) == []
      assert Autocomplete.suggest("", @commands) == []
    end

    test "no match suggests nothing" do
      assert Autocomplete.suggest("/zzz", @commands) == []
    end
  end

  describe "complete/1" do
    test "completes to the command's first token plus a space" do
      assert Autocomplete.complete({"/preset <name>", "Switch preset"}) == "/preset "
      assert Autocomplete.complete({"/help", "..."}) == "/help "
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/shem/tui/autocomplete_test.exs`
Expected: FAIL — module not available

- [ ] **Step 3: Implement**

`lib/shem/tui/autocomplete.ex`:

```elixir
defmodule Shem.TUI.Autocomplete do
  @moduledoc """
  Pure suggestion logic for the slash-command overlay.

  Suggestions match on the command's first token, so `/agent gen` still
  suggests `/agent <preset> <task>` while the user types arguments.
  """

  @type command :: {String.t(), String.t()}

  @spec suggest(String.t(), [command()]) :: [command()]
  def suggest("/" <> _ = buffer, commands) do
    typed = buffer |> String.split(" ", parts: 2) |> hd()

    Enum.filter(commands, fn {cmd, _desc} ->
      cmd_token = cmd |> String.split(" ", parts: 2) |> hd()
      String.starts_with?(cmd_token, typed)
    end)
  end

  def suggest(_buffer, _commands), do: []

  @spec complete(command()) :: String.t()
  def complete({cmd, _desc}) do
    token = cmd |> String.split(" ", parts: 2) |> hd()
    token <> " "
  end
end
```

(Semantics check: typing `/agents` suggests only `/agents` — the `/agent <...>` first token `/agent` does not start with `/agents`. Typing `/agent` suggests both `/agent ...` and `/agents` — useful, intended.)

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/shem/tui/autocomplete_test.exs`
Expected: 8 tests, 0 failures

- [ ] **Step 5: Wire into App** — in `lib/shem/tui/app.ex`:

a) Add `ac_index: 0` to the `init/1` model map.

b) Reset `ac_index` whenever the buffer changes. Modify these three existing clauses:

```elixir
      {:event, %{ch: ?/}} when model.command_buffer == "" ->
        %{model | command_buffer: "/", ac_index: 0}

      {:event, %{key: @backspace}} ->
        buf = model.command_buffer
        %{model | ac_index: 0, command_buffer: if(buf == "", do: "", else: String.slice(buf, 0..-2//1))}

      {:event, %{ch: ch}} when model.command_buffer != "" and ch > 0 ->
        %{model | command_buffer: model.command_buffer <> <<ch::utf8>>, ac_index: 0}
```

c) Add autocomplete navigation/completion clauses. Guards cannot call `String.starts_with?/2` (not guard-safe), so each clause guards on `command_buffer != ""` and branches on the slash prefix in the body. These clauses are disjoint from the Task 2 cycle clauses (which require an EMPTY buffer); place them directly after the Task 2 arrow clauses:

```elixir
      {:event, %{key: @arrow_down}} when model.command_buffer != "" ->
        if String.starts_with?(model.command_buffer, "/") do
          max_index = length(current_suggestions(model)) - 1
          %{model | ac_index: min(model.ac_index + 1, max(max_index, 0))}
        else
          model
        end

      {:event, %{key: @arrow_up}} when model.command_buffer != "" ->
        if String.starts_with?(model.command_buffer, "/") do
          %{model | ac_index: max(model.ac_index - 1, 0)}
        else
          model
        end

      {:event, %{key: @tab}} when model.command_buffer != "" ->
        if String.starts_with?(model.command_buffer, "/") do
          case Enum.at(current_suggestions(model), model.ac_index) do
            nil -> model
            suggestion -> %{model | command_buffer: Shem.TUI.Autocomplete.complete(suggestion), ac_index: 0}
          end
        else
          model
        end
```

These clauses (guard: `command_buffer != ""`) are disjoint from the Task 2 cycle clauses (guard: `command_buffer == ""`), so order between the two groups doesn't matter — but they MUST come before the generic `{:event, %{ch: ch}} when model.command_buffer != ""` clause? No — Tab/arrows arrive with `ch: 0`, and that clause requires `ch > 0`, so no conflict. Place the three new clauses directly after the Task 2 arrow clauses.

d) Add the helper:

```elixir
  defp current_suggestions(model) do
    Shem.TUI.Autocomplete.suggest(model.command_buffer, CommandDispatch.commands())
  end
```

- [ ] **Step 6: Overlay panel in Interactive** — in `lib/shem/tui/views/interactive.ex`, in the main `render/1` clause, insert an overlay row between the content row and the prompt row, rendered only while typing a command:

```elixir
      ...existing content row...

      row do
        column(size: 12) do
          render_autocomplete(model)
        end
      end

      ...existing prompt row...
```

Wait — rendering an empty row when not typing wastes a line. Instead make `render_autocomplete/1` return the prompt row's panel content too? No — keep it simple: Ratatouille tolerates conditionally empty panels poorly, so gate the whole row. Ratatouille views are built from the element list returned by the `view do` block; conditional rows are done by building the row list. Use this structure for the main render clause:

```elixir
  def render(model) do
    rows =
      [content_row(model)] ++
        autocomplete_rows(model) ++
        [prompt_row(model)]

    view(do: rows)
  end

  defp content_row(model) do
    row do
      column(size: 3) do
        render_agent_list(model)
      end

      column(size: 6) do
        render_turn_card(model)
      end

      column(size: 3) do
        render_event_log(model)
      end
    end
  end

  defp autocomplete_rows(%{command_buffer: "/" <> _} = model) do
    suggestions =
      Shem.TUI.Autocomplete.suggest(model.command_buffer, Shem.TUI.CommandDispatch.commands())
      |> Enum.take(6)

    if suggestions == [] do
      []
    else
      [
        row do
          column(size: 12) do
            panel(title: "Commands · ↑↓ select · Tab complete", color: color(:cyan)) do
              for {{cmd, desc}, i} <- Enum.with_index(suggestions) do
                marker = if i == model.ac_index, do: "▸", else: " "

                label(
                  content: "#{marker} #{String.pad_trailing(cmd, 28)} #{desc}",
                  color: if(i == model.ac_index, do: color(:cyan), else: color(:white)),
                  attributes: if(i == model.ac_index, do: [attribute(:bold)], else: [])
                )
              end
            end
          end
        end
      ]
    end
  end

  defp autocomplete_rows(_model), do: []

  defp prompt_row(model) do
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
```

Note: `ac_index` may exceed `length(suggestions) - 1` if suggestions narrowed since the last arrow press (typing resets it to 0, so this only matters transiently) — `Enum.at` in the Tab handler returns nil and is handled; the renderer just won't highlight anything if `ac_index` is past the visible 6. Acceptable.

- [ ] **Step 7: App tests** (append to `test/shem/tui/app_test.exs`)

```elixir
  describe "slash-command autocomplete" do
    @tab 9

    test "typing resets ac_index" do
      model = %{base_model() | command_buffer: "/pre", ac_index: 2}
      updated = App.update(model, {:event, %{ch: ?s, key: 0, mod: 0}})
      assert updated.ac_index == 0
      assert updated.command_buffer == "/pres"
    end

    test "arrow down moves the selection" do
      model = %{base_model() | command_buffer: "/preset", ac_index: 0}
      updated = App.update(model, {:event, %{key: 65516, ch: 0, mod: 0}})
      assert updated.ac_index == 1
    end

    test "arrow up clamps at zero" do
      model = %{base_model() | command_buffer: "/preset", ac_index: 0}
      updated = App.update(model, {:event, %{key: 65517, ch: 0, mod: 0}})
      assert updated.ac_index == 0
    end

    test "tab completes the selected suggestion" do
      model = %{base_model() | command_buffer: "/he", ac_index: 0}
      updated = App.update(model, {:event, %{key: @tab, ch: 0, mod: 0}})
      assert updated.command_buffer == "/help "
    end

    test "tab with no matches leaves the buffer alone" do
      model = %{base_model() | command_buffer: "/zzz", ac_index: 0}
      updated = App.update(model, {:event, %{key: @tab, ch: 0, mod: 0}})
      assert updated.command_buffer == "/zzz"
    end
  end
```

(The "/preset" arrow test relies on `CommandDispatch.commands/0` having ≥2 entries whose first token starts with `/preset` — it has three.)

- [ ] **Step 8: Run TUI tests**

Run: `mix test test/shem/tui/`
Expected: all pass

- [ ] **Step 9: Commit**

```bash
git add lib/shem/tui/autocomplete.ex lib/shem/tui/app.ex lib/shem/tui/views/interactive.ex test/shem/tui/autocomplete_test.exs test/shem/tui/app_test.exs
git commit -m "feat: slash-command autocomplete overlay — arrows select, Tab completes"
```

---

### Task 4: Multiline prompt input (Alt+Enter)

**Files:**
- Modify: `lib/shem/tui/app.ex` (one new clause)
- Modify: `lib/shem/tui/views/interactive.ex` (`prompt_row`/`prompt_content` render newlines)
- Test: `test/shem/tui/app_test.exs` (append)

- [ ] **Step 1: Failing tests**

```elixir
  describe "multiline prompt (Alt+Enter)" do
    @enter 13

    test "alt+enter appends a newline to a non-empty buffer" do
      model = %{base_model() | mode: :interactive, command_buffer: "first line"}
      updated = App.update(model, {:event, %{key: @enter, mod: 1, ch: 0}})
      assert updated.command_buffer == "first line\n"
    end

    test "alt+enter on an empty buffer does nothing" do
      model = %{base_model() | mode: :interactive, command_buffer: ""}
      updated = App.update(model, {:event, %{key: @enter, mod: 1, ch: 0}})
      assert updated.command_buffer == ""
    end

    test "plain enter still submits (buffer cleared) for slash commands" do
      model = %{base_model() | mode: :interactive, command_buffer: "/agents"}
      updated = App.update(model, {:event, %{key: @enter, mod: 0, ch: 0}})
      assert updated.command_buffer == ""
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/shem/tui/app_test.exs`
Expected: the alt+enter tests FAIL (plain-enter submit may already pass — the clause `{:event, %{key: @enter}}` matches regardless of `mod`, which is exactly the bug this task fixes)

- [ ] **Step 3: Implement** — in `lib/shem/tui/app.ex`:

Add the Alt+Enter clause IMMEDIATELY BEFORE the `{:event, %{key: @enter}} when model.command_buffer != ""` dispatch clause (map patterns ignore extra keys, so the plain-enter clause would otherwise swallow Alt+Enter):

```elixir
      {:event, %{key: @enter, mod: 1}} when model.command_buffer != "" ->
        %{model | command_buffer: model.command_buffer <> "\n"}
```

(`mod: 1` is `TB_MOD_ALT`. Empty-buffer Alt+Enter needs no clause — with `command_buffer == ""` it falls through: in the `""` state plain `@enter` has no matching clause either, so it reaches the catch-all `_ -> model`. Verify: the multiline_input-mode and help-overlay clauses are higher and gated by mode/flag — they don't interfere in :interactive.)

- [ ] **Step 4: Render the multiline buffer** — in `lib/shem/tui/views/interactive.ex`, replace the single prompt content label inside `prompt_row/1`:

```elixir
  defp prompt_row(model) do
    row do
      column(size: 12) do
        panel(title: prompt_title(model), color: prompt_color(model)) do
          for line <- prompt_lines(model) do
            label(content: line, color: color(:white))
          end

          label(
            content: if(model.command_error, do: "Error: #{model.command_error}", else: ""),
            color: color(:red)
          )
        end
      end
    end
  end

  defp prompt_lines(%{paused: true}), do: ["PAUSED — press SPACE to resume."]
  defp prompt_lines(%{command_buffer: ""}), do: ["> _"]

  defp prompt_lines(%{command_buffer: buf}) do
    lines = String.split(buf, "\n")
    {init, [last]} = Enum.split(lines, -1)
    Enum.map(init, &("> " <> &1)) ++ ["> #{last}_"]
  end
```

Delete the now-unused `prompt_content/1` clauses (or leave `prompt_content` deleted entirely if nothing else calls it — check `dashboard.ex` has its OWN `status_bar_content`, which is separate; only interactive.ex's copy goes).

- [ ] **Step 5: Run TUI tests**

Run: `mix test test/shem/tui/`
Expected: all pass

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/app.ex lib/shem/tui/views/interactive.ex test/shem/tui/app_test.exs
git commit -m "feat: multiline prompt input — Alt+Enter inserts newline (Shift+Enter is indistinguishable from Enter in terminals)"
```

---

### Task 5: History view — conversation transcript

**Files:**
- Modify: `lib/shem/tui/agent_view.ex` (add `transcript/1`)
- Modify: `lib/shem/tui/views/history.ex` (detail pane renders transcript)
- Modify: `lib/shem/tui/app.ex` (`load_history_detail/2` carries events through)
- Test: `test/shem/tui/agent_view_test.exs` (append)

- [ ] **Step 1: Failing tests** (append to `test/shem/tui/agent_view_test.exs`, which has `open/1` and `session_id/0` helpers)

```elixir
  describe "transcript/1" do
    test "folds a session into user/assistant/tool entries" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "review my code", model: :default, max_turns: 20})
      EventLog.append(id, :agent_turn_started, %{turn: 1})
      EventLog.append(id, :llm_call_completed, %{content: "Let me look at the files."})
      EventLog.append(id, :agent_tool_called, %{tool: "read_file", args: %{path: "mix.exs"}})
      EventLog.append(id, :agent_tool_result, %{tool: "read_file", result: "defmodule Shem.MixProject do ..."})
      EventLog.append(id, :agent_turn_started, %{turn: 2})
      EventLog.append(id, :llm_call_completed, %{content: "The project looks healthy."})
      EventLog.append(id, :agent_done, %{reason: :answer, content: "The project looks healthy."})

      {:ok, events} = EventLog.events(id)
      transcript = AgentView.transcript(events)

      assert [
               {:user, "review my code"},
               {:assistant, "Let me look at the files."},
               {:tool, tool_line},
               {:assistant, "The project looks healthy."}
             ] = transcript

      assert tool_line =~ "read_file"
      assert tool_line =~ "defmodule"
    end

    test "includes follow-up user messages from conversational sessions" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "hi", model: :default, max_turns: 20})
      EventLog.append(id, :llm_call_completed, %{content: "hello!"})
      EventLog.append(id, :user_message, %{content: "what can you do?"})
      EventLog.append(id, :llm_call_completed, %{content: "lots of things"})

      {:ok, events} = EventLog.events(id)

      assert AgentView.transcript(events) == [
               {:user, "hi"},
               {:assistant, "hello!"},
               {:user, "what can you do?"},
               {:assistant, "lots of things"}
             ]
    end

    test "skips empty llm content and collapses tool results to one line" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(id, :llm_call_completed, %{content: nil})
      EventLog.append(id, :agent_tool_result, %{tool: "shell", result: "line1\nline2\nline3"})

      {:ok, events} = EventLog.events(id)
      assert [{:user, "t"}, {:tool, line}] = AgentView.transcript(events)
      refute line =~ "\n"
    end

    test "empty event list yields empty transcript" do
      assert AgentView.transcript([]) == []
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/shem/tui/agent_view_test.exs`
Expected: FAIL — `transcript/1` undefined

- [ ] **Step 3: Implement** — append to `lib/shem/tui/agent_view.ex`:

```elixir
  @doc """
  Folds session events into a chat transcript: who said what, with tool
  calls collapsed to one-line summaries.
  """
  @spec transcript([Shem.EventLog.Event.t()]) ::
          [{:user | :assistant | :tool, String.t()}]
  def transcript(events) do
    Enum.flat_map(events, fn event ->
      case event.type do
        :agent_started ->
          [{:user, event.payload[:task] || ""}]

        :user_message ->
          [{:user, event.payload[:content] || ""}]

        :llm_call_completed ->
          case event.payload[:content] do
            content when is_binary(content) and content != "" -> [{:assistant, content}]
            _ -> []
          end

        :agent_tool_result ->
          result =
            (event.payload[:result] || "")
            |> to_string()
            |> String.replace("\n", " ")
            |> truncate_line(80)

          [{:tool, "⚙ #{event.payload[:tool]} → #{result}"}]

        _ ->
          []
      end
    end)
  end

  defp truncate_line(str, max) when byte_size(str) <= max, do: str
  defp truncate_line(str, max), do: String.slice(str, 0, max) <> "…"
```

(Note: `:agent_done` is intentionally skipped — its content duplicates the final `:llm_call_completed` entry.)

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/shem/tui/agent_view_test.exs`
Expected: all pass

- [ ] **Step 5: Carry events into the history detail** — in `lib/shem/tui/app.ex`, `load_history_detail/2` currently returns an AgentView struct; the transcript needs the raw events too. Change it to return a map of both:

```elixir
  defp load_history_detail(sessions, cursor) do
    case Enum.at(sessions, cursor) do
      nil ->
        nil

      %{session_id: session_id} ->
        case Shem.EventLog.read_session_events(session_id) do
          {:ok, events} ->
            %{
              view: Shem.TUI.AgentView.from_events(events),
              transcript: Shem.TUI.AgentView.transcript(events)
            }

          _ ->
            nil
        end
    end
  end
```

(There is one other consumer: search app.ex for `history_detail` — the `:history` mode arrow/entry clauses just store what this returns, and `Views.History.render` reads it. No other call sites.)

- [ ] **Step 6: Render the transcript** — in `lib/shem/tui/views/history.ex`, the detail clause currently destructures `%{history_detail: view, ...}` where view was an AgentView. Update to the new shape and replace the TURN HISTORY / LAST TOOL CALL / REASONING sections with the transcript:

```elixir
  defp render_session_detail(%{history_detail: %{view: view, transcript: transcript}, history_sessions: sessions, history_cursor: cursor}) do
    summary = Enum.at(sessions, cursor)
    title = if summary, do: "#{summary.session_id} · #{summary.task || "(no task)"}", else: "Session Detail"

    status_str =
      case view.status do
        :done -> "done"
        :error -> "error"
        :running -> "running"
        _ -> "unknown"
      end

    panel(title: title, color: status_color(view.status)) do
      label(
        content: "#{status_str} · #{view.turn_count} turns",
        attributes: [attribute(:bold)],
        color: status_color(view.status)
      )

      label(content: "")

      if transcript == [] do
        label(content: "No conversation recorded.", color: color(:white))
      else
        for entry <- transcript do
          transcript_labels(entry)
        end
      end
    end
  end

  defp transcript_labels({:user, text}) do
    [first | rest] = String.split(text, "\n")

    [
      label(content: "you ▸ #{first}", attributes: [attribute(:bold)], color: color(:cyan))
    ] ++ Enum.map(rest, &label(content: "      #{&1}", color: color(:cyan)))
  end

  defp transcript_labels({:assistant, text}) do
    [first | rest] = String.split(text, "\n")

    [
      label(content: "shem ▸ #{first}", color: color(:white))
    ] ++ Enum.map(rest, &label(content: "       #{&1}", color: color(:white)))
  end

  defp transcript_labels({:tool, line}) do
    [label(content: "  #{line}", color: color(:yellow))]
  end
```

The `%{history_detail: nil, ...}` clauses are unchanged (they pattern-match nil before this clause).

- [ ] **Step 7: Run TUI tests**

Run: `mix test test/shem/tui/`
Expected: all pass. If any existing test constructs a model with `history_detail:` holding an AgentView struct, update it to the new `%{view: ..., transcript: ...}` shape.

- [ ] **Step 8: Commit**

```bash
git add lib/shem/tui/agent_view.ex lib/shem/tui/views/history.ex lib/shem/tui/app.ex test/shem/tui/agent_view_test.exs
git commit -m "feat: history detail renders a readable conversation transcript"
```

---

### Task 6: Full-suite verification + smoke check

**Files:** none new

- [ ] **Step 1: Full suite**

Run: `mix test`
Expected: ~920 tests, 0 failures. The exact count grows by roughly 20 over the 903 baseline. If anything outside `tui/` fails, investigate — Task 1's `:os_mon` addition is the only change with app-wide reach (it may add SASL alarm noise to output; noise is acceptable, failures are not).

- [ ] **Step 2: Compile-warning check**

Run: `mix compile --warnings-as-errors 2>&1 | tail -20`
Expected: clean (two pre-existing warnings in `tui/app.ex:129` / `adversarial/supervisor.ex:4` may exist — do not introduce NEW warnings; fix any that the new code created, e.g. the unused `prompt_content/1`).

- [ ] **Step 3: Manual smoke (best-effort)**

The TUI cannot run headlessly in CI, but compile-render coverage exists via the view tests. If a TTY is available: `mix run --no-halt`, verify dashboard shows live CPU/MEM and token counts, `/pre` shows the overlay, Tab completes, Alt+Enter adds a line, `h` opens history with transcripts. Report whatever was verifiable.

- [ ] **Step 4: Commit anything outstanding**

```bash
git status --short   # should be clean; commit stragglers if any
```

---

## Post-implementation checklist (not separate tasks)

- Update memory `project_shem.md`: Phase 35 ✅ section; Phase 37 becomes next.
- The spec's success criteria to verify against: live dashboard values; `/` overlay with Tab completion; newline insertion in the prompt (Alt+Enter — documented deviation); agent list with live focus switching; readable history transcript.
