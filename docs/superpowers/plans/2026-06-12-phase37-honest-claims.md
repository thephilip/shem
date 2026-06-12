# Phase 37 — Honest Claims — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make three manifest claims true: real pause-and-steer on the focused agent, property-gated tool graduation, and a hash-chained (verifiable) EventLog.

**Architecture:** Three independent sections. Pause rides the existing `:run_turn` drop-guard in `Agent.Server` (status flip + message injection). The property gate is a source-scan in `GraduationGate` plus a new non-hardening `Trust.Store.seed/2`. The hash chain is a pure `EventLog.Chain` module wired into the EventLog GenServer's append path, with per-session `last_hash` tracked on the `Session` struct, exposed via `EventLog.verify_chain/1` and one REST endpoint.

**Tech Stack:** Elixir/OTP, `:crypto` (sha256), StreamData (promoted to runtime dep), existing EventLog/Trust/Agent infrastructure.

**Spec:** `docs/superpowers/specs/2026-06-12-phase37-honest-claims-design.md`

**Two refinements vs. the spec (verified against code, carry into the spec doc in Task 6):**
1. **`Trust.Store.seed/2` instead of `record/2` with a new outcome.** `record/2` increments `hardening_count` — seeding through it would make `/tools` display "1 hardening" for a never-hardened tool, an honesty bug in the Honest Claims phase. `seed/2` writes `%{score: 0.5, hardening_count: 0}` only if the tool is unrated.
2. **No fork hash-stripping needed.** `Shem.LLM.Branch` replays events through normal `EventLog.append` into a brand-new session (`build_prefix_queue` + `run_with_pipeline`) — it never copies Event structs. Forked sessions therefore get fresh, valid chains automatically.

**Key codebase facts (verified):**
- `Agent.Server` state: `%{name, config, history, session_id, turn_count, status, done_reason, awaiting}`. `handle_info(:run_turn, %{status: s} = state) when s != :running` DROPS the message (lib/shem/agent/server.ex:94) — this is the pause seam. Tool execution happens synchronously inside `handle_info(:run_turn, ...)`, so a `pause` call queued during a long tool run is processed at the turn boundary, **before** the end-of-turn self-sent `:run_turn` (calls that arrived during the handle_info are earlier in the mailbox) — pause is deterministic at the next boundary.
- `Shem.Agent` public functions guard `GenServer.call` with `try/catch :exit` (see `status/1`) — follow that pattern.
- EventLog GenServer state: `%{sessions: %{session_id => {handle, %Session{}}}, store: module}`. Append path: `handle_call({:append, ...})` at lib/shem/event_log.ex:106 creates `Event.new/4` then `store.append`. `Session` struct: `[:id, :started_at, :ended_at, event_count: 0]`.
- `Event` struct: `[:id, :session_id, :parent_id, :type, :payload, :timestamp]`, `@enforce_keys [:id, :session_id, :type, :payload, :timestamp]`.
- `Trust.Store`: DETS entries `{tool_id, %{tool_id, score, last_updated, hardening_count}}`; score formula clauses `compute_outcome_score/2` end in a catch-all `(_outcome, _rounds) -> 0.0`. Bands: ≥0.8 high, ≥0.5 medium, <0.5 low.
- `GraduationGate.run/3` (lib/shem/lab/graduation_gate.ex): on pass, builds `%Tool{..., metadata: %{}}`, `Workspace.graduate`, `Registry.register`, fires `Adversarial.start_hardening` (returns `{:ok, :disabled}` in test env).
- `mix.exs` deps: `{:stream_data, "~> 1.0", only: :test}`.
- REST sessions handler `lib/shem/rest/handlers/sessions.ex`: routes `get "/"`, `get "/:id/events"`, `post "/:id/fork"`, `match _`. Check its existing JSON-reply helper and reuse it.
- Test env: `executor_backend :local`, `executor_timeout_ms: 200` (override per-test via `Application.put_env` + `on_exit` restore). `StubTransport` FIFO queue; agent tests in `test/shem/agent/server_test.exs` have `stub/2` + `start_agent/2` helpers AND existing tool-call stub examples — copy their exact tool-call response format for the e2e test (check what JSON shape the stub content uses for tool calls, and the exact `args` key the `shell` builtin expects — grep `dispatch_builtin("shell"` in lib/shem/agent/tool_dispatch.ex).
- TUI: `model.paused` is currently a display-only flag (SPACE toggles at app.ex ~line 170, Esc sets it at ~line 173). Views pattern-match `%{paused: true}` (dashboard status bar; interactive `prompt_title`/`prompt_color`/`prompt_lines`). The `:tick` clause recomputes model fields each 100ms. `base_model/0` exists in test/shem/tui/app_test.exs.
- MCP `agent_status` (Phase 36) converts status via `Atom.to_string` — `:paused` flows through automatically; only the router descriptor TEXT needs updating.
- Run only named test files per task; full suite in Task 6.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/shem/agent/server.ex` (modify) | `:pause` / `{:steer, text}` / `:unpause` handle_calls |
| `lib/shem/agent.ex` (modify) | `pause/1`, `steer/2`, `unpause/1` public API |
| `lib/shem/tui/app.ex` (modify) | SPACE toggles real pause; Esc-pause removed; `paused` derived on tick; Enter steers when paused |
| `lib/shem/tui/views/interactive.ex` (modify) | `:paused` dot/label/color |
| `lib/shem/mcp/router.ex` (modify) | descriptor text: paused status + property-gate note |
| `lib/shem/trust/store.ex` (modify) | `seed/2` |
| `lib/shem/lab/graduation_gate.ex` (modify) | property detection, metadata, seeding |
| `mix.exs` (modify) | stream_data → runtime dep |
| `lib/shem/event_log/chain.ex` (create) | pure hash-chain: genesis/next/verify |
| `lib/shem/event_log/event.ex` (modify) | `hash` field |
| `lib/shem/event_log/session.ex` (modify) | `last_hash` field |
| `lib/shem/event_log.ex` (modify) | append chains hashes; reopen seeds; `verify_chain/1` |
| `lib/shem/rest/handlers/sessions.ex` (modify) | `GET /:id/verify` |

---

### Task 1: Agent.Server pause / steer / unpause

**Files:**
- Modify: `lib/shem/agent/server.ex` (new handle_call clauses after `{:set_fence, ...}`)
- Modify: `lib/shem/agent.ex` (three public functions)
- Test: `test/shem/agent/server_test.exs` (append)

- [ ] **Step 1: Write the failing tests** (append; the file has `stub/2`, `start_agent/2`; read its existing tool-call test first to copy the stub format for the e2e test)

```elixir
  describe "pause / steer / unpause" do
    test "pause on a waiting conversational agent is rejected" do
      stub("hello!")
      config = %Agent.Config{task: "chat", system_prompt: "s", conversational: true}
      {:ok, name, _sid} = Agent.start(config)
      assert {:ok, :waiting} = Agent.await(name, 2_000)

      assert {:error, :not_running} = Agent.pause(name)
      assert {:error, :not_paused} = Agent.steer(name, "nope")
      assert {:error, :not_paused} = Agent.unpause(name)
      Agent.stop(name)
    end

    test "pause/steer/unpause on an unknown agent returns not_found" do
      assert {:error, :not_found} = Agent.pause("agent_NOPE")
      assert {:error, :not_found} = Agent.steer("agent_NOPE", "x")
      assert {:error, :not_found} = Agent.unpause("agent_NOPE")
    end

    test "full cycle: pause mid-task, steer, unpause, finish with steering applied" do
      # slow down the executor so turn 1's shell call holds the server in
      # handle_info long enough for our pause call to queue behind it
      prev = Application.get_env(:shem, :executor_timeout_ms)
      Application.put_env(:shem, :executor_timeout_ms, 2_000)
      on_exit(fn -> Application.put_env(:shem, :executor_timeout_ms, prev) end)

      # turn 1: tool call (shell sleep). turn 2: final answer.
      stub(~s({"tool": "shell", "args": {"command": "sleep 0.5"}}))
      stub("done after steering")

      config = %Agent.Config{task: "long task", system_prompt: "s", max_turns: 10}
      {:ok, name, sid} = Agent.start(config)

      # the server is inside turn 1 (shell sleep); this call queues and is
      # processed at the turn boundary, before the end-of-turn :run_turn
      Process.sleep(100)
      assert :ok = Agent.pause(name)
      assert {:ok, :paused} = Agent.status(name)

      assert :ok = Agent.steer(name, "actually, summarize instead")
      assert :ok = Agent.unpause(name)
      assert {:ok, :done} = Agent.await(name, 5_000)

      {:ok, events} = Shem.EventLog.events(sid)
      types = Enum.map(events, & &1.type)
      assert :agent_paused in types
      assert :agent_steered in types
      assert :agent_unpaused in types

      steered = Enum.find(events, &(&1.type == :agent_steered))
      assert steered.payload.content == "actually, summarize instead"

      done = Enum.find(events, &(&1.type == :agent_done))
      assert done.payload.content == "done after steering"
      Agent.stop(name)
    end

    test "a queued :run_turn is dropped while paused (no extra turn executes)" do
      # pure state-machine check against the server callbacks
      sid = "ses_PAUSE_#{System.unique_integer([:positive])}"
      {:ok, ^sid} = Shem.EventLog.start_session(sid)

      state = %{
        name: "agent_pausetest",
        config: %Agent.Config{task: "t", system_prompt: "s"},
        history: [],
        session_id: sid,
        turn_count: 1,
        status: :running,
        done_reason: nil,
        awaiting: []
      }

      {:reply, :ok, paused} = Shem.Agent.Server.handle_call(:pause, {self(), make_ref()}, state)
      assert paused.status == :paused

      # the drop-guard must swallow :run_turn without touching state
      {:noreply, same} = Shem.Agent.Server.handle_info(:run_turn, paused)
      assert same.status == :paused
      assert same.turn_count == 1

      # unpause flips status and re-arms the loop (self() receives :run_turn)
      {:reply, :ok, running} =
        Shem.Agent.Server.handle_call(:unpause, {self(), make_ref()}, paused)

      assert running.status == :running
      assert_received :run_turn
    end
  end
```

If the tool-call stub format in this file's existing tests differs from the plain-JSON-in-content shape above (e.g. native `tool_calls:` on the Response struct), use the file's existing format for the "full cycle" test — the shape that actually drives `ToolDispatch` through the `shell` builtin. Same for the shell `args` key (`"command"` vs `"cmd"`): copy whatever `dispatch_builtin("shell"` expects.

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/shem/agent/server_test.exs`
Expected: FAIL — `Shem.Agent.pause/1 is undefined`

- [ ] **Step 3: Implement the server clauses** — in `lib/shem/agent/server.ex`, after the `{:set_fence, ...}` clause:

```elixir
  def handle_call(:pause, _from, %{status: :running} = state) do
    EventLog.append(state.session_id, :agent_paused, %{turn: state.turn_count})
    {:reply, :ok, %{state | status: :paused}}
  end

  def handle_call(:pause, _from, state), do: {:reply, {:error, :not_running}, state}

  def handle_call({:steer, text}, _from, %{status: :paused} = state) do
    EventLog.append(state.session_id, :agent_steered, %{content: text})
    {:reply, :ok, %{state | history: state.history ++ [%{role: :user, content: text}]}}
  end

  def handle_call({:steer, _text}, _from, state), do: {:reply, {:error, :not_paused}, state}

  def handle_call(:unpause, _from, %{status: :paused} = state) do
    EventLog.append(state.session_id, :agent_unpaused, %{turn: state.turn_count})
    send(self(), :run_turn)
    {:reply, :ok, %{state | status: :running}}
  end

  def handle_call(:unpause, _from, state), do: {:reply, {:error, :not_paused}, state}
```

- [ ] **Step 4: Implement the public API** — in `lib/shem/agent.ex`, after `status/1`:

```elixir
  @spec pause(String.t()) :: :ok | {:error, :not_found | :not_running}
  def pause(name), do: agent_call(name, :pause)

  @spec steer(String.t(), String.t()) :: :ok | {:error, :not_found | :not_paused}
  def steer(name, text), do: agent_call(name, {:steer, text})

  @spec unpause(String.t()) :: :ok | {:error, :not_found | :not_paused}
  def unpause(name), do: agent_call(name, :unpause)

  defp agent_call(name, msg) do
    case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
      nil ->
        {:error, :not_found}

      pid ->
        try do
          GenServer.call(pid, msg)
        catch
          :exit, _ -> {:error, :not_found}
        end
    end
  end
```

- [ ] **Step 5: Run to verify pass**

Run: `mix test test/shem/agent/server_test.exs`
Expected: all pass (the full-cycle test takes ~1s due to the sleep)

- [ ] **Step 6: Commit**

```bash
git add lib/shem/agent/server.ex lib/shem/agent.ex test/shem/agent/server_test.exs
git commit -m "feat: real agent pause/steer/unpause — status flip rides the :run_turn drop-guard"
```

---

### Task 2: TUI pause wiring

**Files:**
- Modify: `lib/shem/tui/app.ex` (SPACE clause, Esc clause removal, tick derivation, Enter steer routing)
- Modify: `lib/shem/tui/views/interactive.ex` (`:paused` dot/label/color)
- Modify: `lib/shem/mcp/router.ex` (agent_status descriptor text)
- Test: `test/shem/tui/app_test.exs` (append)

- [ ] **Step 1: Write the failing tests** (append to app_test.exs)

```elixir
  describe "real pause (SPACE) and steering" do
    @space ?\s

    test "SPACE with no focused agent is a no-op" do
      model = %{base_model() | mode: :interactive}
      updated = App.update(model, {:event, %{key: @space, ch: 0, mod: 0}})
      assert updated.paused == false
    end

    test "SPACE on a vanished agent leaves the model unchanged" do
      model = %{
        base_model()
        | mode: :interactive,
          focused_agent: "agent_GONE",
          agents: [%{name: "agent_GONE", pid: self(), status: :running, session_id: nil, turn_count: 1}]
      }

      updated = App.update(model, {:event, %{key: @space, ch: 0, mod: 0}})
      assert updated.paused == false
    end

    test "Esc no longer sets paused" do
      model = %{base_model() | mode: :interactive}
      updated = App.update(model, {:event, %{key: 27, ch: 0, mod: 0}})
      assert updated.paused == false
    end

    test ":tick derives paused from the focused agent's real status" do
      Shem.LLM.StubTransport.Server.reset()

      Shem.LLM.StubTransport.Server.push_response(
        {:ok, %Shem.LLM.Response{content: "hi", tokens_used: 5, model: :default, latency_ms: 1}}
      )

      config = %Shem.Agent.Config{task: "chat", system_prompt: "s", conversational: true}
      {:ok, name, _sid} = Shem.Agent.start(config)
      {:ok, :waiting} = Shem.Agent.await(name, 2_000)
      on_exit(fn -> Shem.Agent.stop(name) end)

      # waiting agent: paused must derive false
      model = %{base_model() | focused_agent: name}
      ticked = App.update(model, :tick)
      assert ticked.paused == false
    end

    test "Enter steers instead of conversing when the focused agent is paused" do
      model = %{
        base_model()
        | mode: :interactive,
          paused: true,
          focused_agent: "agent_GONE",
          command_buffer: "change course"
      }

      updated = App.update(model, {:event, %{key: 13, ch: 0, mod: 0}})
      # agent_GONE doesn't exist -> steer fails -> error surfaced, buffer kept behavior:
      assert updated.command_error =~ "steer failed"
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/shem/tui/app_test.exs`
Expected: "Esc no longer sets paused" and "Enter steers" FAIL (Esc currently sets `paused: true`; Enter currently routes to conversational)

- [ ] **Step 3: Implement in app.ex**

a) Replace the SPACE clause (currently `%{model | paused: !model.paused}`):

```elixir
      {:event, %{key: @space}} when model.command_buffer == "" ->
        toggle_pause_focused(model)
```

b) DELETE the Esc clause (`{:event, %{key: @esc}} when model.command_buffer == "" -> %{model | paused: true}`).

c) Add the helper near `cycle_focus/2` — current status read from `model.agents` (already refreshed every tick), result applied only when the server call succeeds:

```elixir
  defp toggle_pause_focused(%{focused_agent: nil} = model), do: model

  defp toggle_pause_focused(%{focused_agent: name} = model) do
    current = Enum.find(model.agents, &(&1.name == name))

    case current && current.status do
      :running ->
        case Shem.Agent.pause(name) do
          :ok ->
            %{model | paused: true,
              command_output: "paused #{name} — type to steer, SPACE to resume",
              command_error: nil}

          {:error, _} ->
            model
        end

      :paused ->
        case Shem.Agent.unpause(name) do
          :ok -> %{model | paused: false, command_output: nil}
          {:error, _} -> model
        end

      _ ->
        model
    end
  end
```

d) In the `:tick` clause, derive `paused` from the freshly computed agent list. Restructure the head of the clause so `agents` is computed once:

```elixir
      :tick ->
        tick_count = model.tick_count + 1

        {system_stats, budget} =
          if rem(tick_count, 10) == 1 do
            {Shem.TUI.SystemStats.collect(), safe_budget()}
          else
            {model.system_stats, model.budget}
          end

        agents = safe_agent_list()

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
            agents: agents,
            paused: focused_paused?(agents, model.focused_agent),
            agent_view: safe_agent_view(model.focused_agent),
            trust_counts: safe_trust_counts()
        }
```

with:

```elixir
  defp focused_paused?(_agents, nil), do: false

  defp focused_paused?(agents, name),
    do: Enum.any?(agents, &(&1.name == name and &1.status == :paused))
```

(The rest of the `:tick` clause is untouched.)

e) In the Enter dispatch, the plain-text (non-slash) branch currently goes straight to the conversational `case`. Route to steering first:

```elixir
        else
          # Plain text: steer a paused agent, otherwise conversational mode
          text = String.trim(model.command_buffer)

          if model.paused and model.focused_agent do
            case Shem.Agent.steer(model.focused_agent, text) do
              :ok ->
                %{model | command_buffer: "",
                  command_output: "steered — SPACE to resume", command_error: nil}

              {:error, reason} ->
                %{model | command_error: "steer failed: #{inspect(reason)}", command_output: nil}
            end
          else
            case model.active_conversational_agent do
              ...existing conversational logic, unchanged, just re-indented...
            end
          end
        end
```

- [ ] **Step 4: Paused rendering** — in `lib/shem/tui/views/interactive.ex` add clauses to the existing helpers (each currently lacks `:paused`):

```elixir
  defp agent_status_dot(:paused), do: "⏸"
```
(insert before the `(_)` catch-all in `agent_status_dot/1`)

```elixir
  defp agent_status_color(:paused), do: color(:yellow)
```
(before the catch-all in `agent_status_color/1`)

```elixir
  defp status_label(:paused), do: "paused"
```
(before the catch-all in `status_label/1`)

```elixir
  defp status_color(:paused), do: color(:yellow)
```
(before the catch-all in `status_color/1`)

The `%{paused: true}` clauses of `prompt_title/1`, `prompt_color/1`, `prompt_lines/1` (and dashboard's status bar trio) stay EXACTLY as they are — `model.paused` is now derived from the focused agent's real status, so their copy ("PAUSED — press SPACE to resume", "Type a prompt to steer") finally tells the truth.

- [ ] **Step 5: MCP descriptor text** — in `lib/shem/mcp/router.ex`, update the `agent_status` descriptor description from `running|waiting|done|error` to `running|waiting|paused|done|error`.

- [ ] **Step 6: Run the TUI tests**

Run: `mix test test/shem/tui/ test/shem/mcp/router_test.exs`
Expected: all pass

- [ ] **Step 7: Commit**

```bash
git add lib/shem/tui/app.ex lib/shem/tui/views/interactive.ex lib/shem/mcp/router.ex test/shem/tui/app_test.exs
git commit -m "feat: SPACE pauses the focused agent for real; typed input steers it"
```

---

### Task 3: Property-gated graduation

**Files:**
- Modify: `mix.exs` (stream_data dep)
- Modify: `lib/shem/trust/store.ex` (`seed/2`)
- Modify: `lib/shem/lab/graduation_gate.ex` (detection + metadata + seeding)
- Modify: `lib/shem/mcp/router.ex` (graduate_tool descriptor text)
- Test: `test/shem/trust/store_test.exs` (append), `test/shem/lab/graduation_gate_test.exs` (append)

- [ ] **Step 1: Promote stream_data** — in `mix.exs` change:

```elixir
      {:stream_data, "~> 1.0", only: :test},
```
to:
```elixir
      {:stream_data, "~> 1.0"},
```

Run `mix deps.get && mix compile` — clean.

- [ ] **Step 2: Failing tests for `Trust.Store.seed/2`** (append to test/shem/trust/store_test.exs — read its setup first; it flushes the store):

```elixir
  describe "seed/2" do
    test "seeds an unrated tool at the given score with zero hardenings" do
      assert {:ok, :seeded} = Store.seed("tool_seed_1", 0.5)
      assert {:ok, 0.5} = Store.score("tool_seed_1")
      assert {:ok, entry} = Store.entry("tool_seed_1")
      assert entry.hardening_count == 0
    end

    test "refuses to clobber an already-rated tool" do
      :ok = Store.record("tool_seed_2", %{outcome: :clean, rounds: 1})
      assert {:error, :already_rated} = Store.seed("tool_seed_2", 0.5)
      assert {:ok, 1.0} = Store.score("tool_seed_2")
    end
  end
```

(Match the test file's existing alias — it may alias `Shem.Trust.Store` as `Store`.)

- [ ] **Step 3: Run to verify failure**

Run: `mix test test/shem/trust/store_test.exs`
Expected: FAIL — `seed/2 undefined`

- [ ] **Step 4: Implement `seed/2`** — in `lib/shem/trust/store.ex`:

Client function after `record/2`:

```elixir
  @spec seed(String.t(), float()) :: {:ok, :seeded} | {:error, :already_rated}
  def seed(tool_id, score) do
    GenServer.call(__MODULE__, {:seed, tool_id, score})
  end
```

Handler after the `{:record, ...}` clause:

```elixir
  def handle_call({:seed, tool_id, score}, _from, state) do
    case :dets.lookup(state.table, tool_id) do
      [{^tool_id, _entry}] ->
        {:reply, {:error, :already_rated}, state}

      [] ->
        entry = %{
          tool_id: tool_id,
          score: score,
          last_updated: DateTime.utc_now(),
          hardening_count: 0
        }

        :ok = :dets.insert(state.table, {tool_id, entry})
        {:reply, {:ok, :seeded}, state}
    end
  end
```

Run the store tests — pass.

- [ ] **Step 5: Failing tests for the gate** (append to test/shem/lab/graduation_gate_test.exs — read its setup first; it configures lab_dir and flushes registries):

```elixir
  describe "property-gated graduation" do
    test "a tool without property tests graduates seeded at trust :medium" do
      source = """
      defmodule NoPropTool1 do
        def run(_args), do: :ok
      end
      """

      test_src = """
      defmodule NoPropTool1Test do
        def run, do: :ok
      end
      """

      assert {:ok, tool} = GraduationGate.run(source, test_src)
      assert tool.metadata.property_tested == false
      assert {:ok, 0.5} = Shem.Trust.Store.score(tool.id)
    end

    test "a tool with a passing StreamData property graduates unrated" do
      source = """
      defmodule PropTool1 do
        def run(args), do: {:ok, args}
      end
      """

      test_src = """
      defmodule PropTool1Test do
        def run do
          {:ok, _} =
            StreamData.check_all(StreamData.integer(), [initial_seed: 42], fn i ->
              case PropTool1.run(i) do
                {:ok, ^i} -> {:ok, i}
                other -> {:error, other}
              end
            end)

          :ok
        end
      end
      """

      assert {:ok, tool} = GraduationGate.run(source, test_src)
      assert tool.metadata.property_tested == true
      assert {:error, :unrated} = Shem.Trust.Store.score(tool.id)
    end

    test "a failing property still fails the gate" do
      source = """
      defmodule PropTool2 do
        def run(_args), do: :wrong
      end
      """

      test_src = """
      defmodule PropTool2Test do
        def run do
          {:ok, _} =
            StreamData.check_all(StreamData.integer(), [initial_seed: 42], fn _i ->
              {:error, :always_fails}
            end)

          :ok
        end
      end
      """

      assert {:error, _, _} = GraduationGate.run(source, test_src)
    end
  end
```

If `StreamData.check_all/3`'s option or return shape differs in the installed version (check `deps/stream_data/lib/stream_data.ex` for the `check_all` spec), adjust the test sources to the real API — the intent is: a genuine generated-input property that passes in test 2 and fails in test 3.

- [ ] **Step 6: Run to verify failure**

Run: `mix test test/shem/lab/graduation_gate_test.exs`
Expected: the two new metadata/seed assertions FAIL (metadata is `%{}` today; no seeding happens)

- [ ] **Step 7: Implement the gate change** — in `lib/shem/lab/graduation_gate.ex`, inside the success branch where the `%Tool{}` is built:

```elixir
      {:ok, :ok} ->
        with {:ok, module} <- extract_module(source) do
          property? = property_tested?(test_source)
          id = unique_id(module)

          tool = %Tool{
            id: id,
            name: module |> Atom.to_string() |> String.split(".") |> List.last(),
            module: module,
            source: source,
            test_source: test_source,
            constraints: constraints,
            graduated_at: DateTime.utc_now(),
            metadata: %{property_tested: property?}
          }

          :ok = Workspace.graduate(tool)
          :ok = Registry.register(tool)
          unless property?, do: seed_trust(tool.id)
          Shem.Adversarial.start_hardening(tool.id)
          {:ok, tool}
        else
          {:error, :compile, reason} -> {:error, :compile, reason}
        end
```

with two private helpers at the bottom:

```elixir
  # The heuristic is the cheap half of the gate: presence of a StreamData
  # invocation. The substantive half is that the property must PASS inside
  # the executor like any other test.
  defp property_tested?(test_source), do: test_source =~ ~r/check_all|StreamData\./

  @no_property_seed 0.5
  defp seed_trust(tool_id) do
    Shem.Trust.Store.seed(tool_id, @no_property_seed)
  catch
    :exit, _ -> {:error, :store_down}
  end
```

(Module attributes can't be defined after first use inside a function — put `@no_property_seed 0.5` at the top of the module with the other attributes if the compiler complains.)

- [ ] **Step 8: graduate_tool descriptor** — in `lib/shem/mcp/router.ex`, update the `graduate_tool` descriptor description to:

```
"Atomically compile, test, and register a tool. Fails with details if tests fail. Include at least one StreamData property (StreamData.check_all) in test_source — tools without property tests graduate at reduced trust (:medium)."
```

- [ ] **Step 9: Run the affected suites**

Run: `mix test test/shem/lab/ test/shem/trust/ test/shem/mcp/router_test.exs`
Expected: all pass. NOTE: other graduation-gate consumers' tests (tool_dispatch, adversarial) build tools through the gate — if any asserts `metadata == %{}`, update it to the new shape.

- [ ] **Step 10: Commit**

```bash
git add mix.exs mix.lock lib/shem/trust/store.ex lib/shem/lab/graduation_gate.ex lib/shem/mcp/router.ex test/shem/trust/store_test.exs test/shem/lab/graduation_gate_test.exs
git commit -m "feat: property-gated graduation — example-only tools seed at trust :medium"
```

---

### Task 4: EventLog.Chain (pure hash chain)

**Files:**
- Create: `lib/shem/event_log/chain.ex`
- Modify: `lib/shem/event_log/event.ex` (hash field)
- Test: `test/shem/event_log/chain_test.exs` (create)

- [ ] **Step 1: Add the hash field** — in `lib/shem/event_log/event.ex`:

```elixir
  defstruct [:id, :session_id, :parent_id, :type, :payload, :timestamp, :hash]
```

and extend the typespec:

```elixir
          hash: String.t() | nil,
```

(`@enforce_keys` unchanged; `Event.new/4` leaves hash nil — the EventLog assigns it at append time in Task 5.)

- [ ] **Step 2: Write the failing tests** — `test/shem/event_log/chain_test.exs`:

```elixir
defmodule Shem.EventLog.ChainTest do
  use ExUnit.Case, async: true

  alias Shem.EventLog.{Chain, Event}

  @sid "ses_CHAIN_TEST"

  defp event(type, payload) do
    Event.new(@sid, type, payload)
  end

  defp chained(events) do
    {hashed, _} =
      Enum.map_reduce(events, Chain.genesis(@sid), fn e, prev ->
        h = Chain.next(prev, e)
        {%{e | hash: h}, h}
      end)

    hashed
  end

  test "genesis is deterministic per session" do
    assert Chain.genesis(@sid) == Chain.genesis(@sid)
    refute Chain.genesis(@sid) == Chain.genesis("ses_OTHER")
  end

  test "a correctly chained list verifies" do
    events = chained([event(:a, %{x: 1}), event(:b, %{x: 2}), event(:c, %{x: 3})])
    assert {:ok, :verified, 3} = Chain.verify(events, @sid)
  end

  test "an all-nil-hash list is legacy" do
    events = [event(:a, %{x: 1}), event(:b, %{x: 2})]
    assert {:ok, :legacy, 2} = Chain.verify(events, @sid)
  end

  test "empty list is legacy with zero events" do
    assert {:ok, :legacy, 0} = Chain.verify([], @sid)
  end

  test "a tampered payload is detected at the exact event" do
    [e1, e2, e3] = chained([event(:a, %{x: 1}), event(:b, %{x: 2}), event(:c, %{x: 3})])
    tampered = %{e2 | payload: %{x: 666}}
    assert {:error, {:broken_at, broken_id}} = Chain.verify([e1, tampered, e3], @sid)
    assert broken_id == e2.id
  end

  test "a relinked chain (recomputed after tamper) breaks at the next event" do
    [e1, e2, e3] = chained([event(:a, %{x: 1}), event(:b, %{x: 2}), event(:c, %{x: 3})])
    # attacker rewrites e2's payload AND recomputes e2's hash — but e3's
    # stored hash no longer chains from the forged e2 hash
    forged_payload = %{x: 666}
    forged_e2 = %{e2 | payload: forged_payload, hash: Chain.next(e1.hash, %{e2 | payload: forged_payload})}
    assert {:error, {:broken_at, broken_id}} = Chain.verify([e1, forged_e2, e3], @sid)
    assert broken_id == e3.id
  end

  test "legacy prefix followed by a hashed segment verifies from genesis" do
    legacy = [event(:old1, %{x: 0}), event(:old2, %{x: 0})]
    hashed = chained([event(:new1, %{x: 1}), event(:new2, %{x: 2})])
    assert {:ok, :verified, 4} = Chain.verify(legacy ++ hashed, @sid)
  end

  test "a nil hash after a hashed event is broken" do
    [e1, e2] = chained([event(:a, %{x: 1}), event(:b, %{x: 2})])
    gap = Shem.EventLog.Event.new(@sid, :c, %{x: 3})
    assert {:error, {:broken_at, broken_id}} = Chain.verify([e1, e2, gap], @sid)
    assert broken_id == gap.id
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `mix test test/shem/event_log/chain_test.exs`
Expected: FAIL — Chain undefined

- [ ] **Step 4: Implement** — `lib/shem/event_log/chain.ex`:

```elixir
defmodule Shem.EventLog.Chain do
  @moduledoc """
  Per-session hash chain over EventLog events.

  Each event's hash commits to the previous hash and the event's identity,
  type, payload, and timestamp — so any retroactive edit breaks every
  subsequent link. Legacy events (hash: nil) from before the chain existed
  are tolerated as an unverifiable prefix; a nil hash appearing AFTER a
  hashed event is a break.
  """

  alias Shem.EventLog.Event

  @spec genesis(String.t()) :: String.t()
  def genesis(session_id) do
    Base.encode16(:crypto.hash(:sha256, session_id))
  end

  @spec next(String.t(), Event.t()) :: String.t()
  def next(prev_hash, %Event{} = event) do
    Base.encode16(:crypto.hash(:sha256, prev_hash <> canonical(event)))
  end

  @spec verify([Event.t()], String.t()) ::
          {:ok, :verified | :legacy, non_neg_integer()}
          | {:error, {:broken_at, String.t()}}
  def verify(events, session_id) do
    {_legacy_prefix, hashed} = Enum.split_while(events, &is_nil(&1.hash))

    case hashed do
      [] -> {:ok, :legacy, length(events)}
      _ -> walk(hashed, genesis(session_id), length(events))
    end
  end

  defp walk([], _prev, total), do: {:ok, :verified, total}

  defp walk([%Event{hash: nil} = e | _rest], _prev, _total),
    do: {:error, {:broken_at, e.id}}

  defp walk([e | rest], prev, total) do
    if e.hash == next(prev, e) do
      walk(rest, e.hash, total)
    else
      {:error, {:broken_at, e.id}}
    end
  end

  defp canonical(%Event{} = e) do
    :erlang.term_to_binary({e.id, e.session_id, e.type, e.payload, DateTime.to_iso8601(e.timestamp)})
  end
end
```

- [ ] **Step 5: Run to verify pass**

Run: `mix test test/shem/event_log/chain_test.exs`
Expected: 8 tests, 0 failures

- [ ] **Step 6: Commit**

```bash
git add lib/shem/event_log/chain.ex lib/shem/event_log/event.ex test/shem/event_log/chain_test.exs
git commit -m "feat: EventLog.Chain — pure per-session sha256 hash chain with legacy tolerance"
```

---

### Task 5: Wire the chain into EventLog + REST verify endpoint

**Files:**
- Modify: `lib/shem/event_log/session.ex` (`last_hash` field)
- Modify: `lib/shem/event_log.ex` (append chains; reopen seeds; `verify_chain/1`)
- Modify: `lib/shem/rest/handlers/sessions.ex` (`GET /:id/verify`)
- Test: `test/shem/event_log_test.exs` (append), `test/shem/rest/handlers/sessions_test.exs` (append — check the actual REST test path first: `ls test/shem/rest/`)

- [ ] **Step 1: Write the failing tests** (append to test/shem/event_log_test.exs — read its session-setup helpers first):

```elixir
  describe "hash chain" do
    test "appended events carry chained hashes and the session verifies" do
      {:ok, sid} = EventLog.start_session()
      {:ok, e1} = EventLog.append(sid, :one, %{n: 1})
      {:ok, e2} = EventLog.append(sid, :two, %{n: 2})

      assert is_binary(e1.hash)
      assert is_binary(e2.hash)
      assert e2.hash == Shem.EventLog.Chain.next(e1.hash, e2)
      assert {:ok, :verified, 2} = EventLog.verify_chain(sid)
    end

    test "verify_chain on an unknown session is not_found" do
      assert {:error, :not_found} = EventLog.verify_chain("ses_NO_SUCH")
    end
  end
```

And to the REST sessions test file (follow its existing Plug.Test conn pattern):

```elixir
  describe "GET /:id/verify" do
    test "verified session" do
      {:ok, sid} = Shem.EventLog.start_session()
      {:ok, _} = Shem.EventLog.append(sid, :x, %{n: 1})

      conn = request(:get, "/#{sid}/verify")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["verified"] == true
      assert body["events"] == 1
    end

    test "unknown session is 404" do
      conn = request(:get, "/ses_NO_SUCH/verify")
      assert conn.status == 404
    end
  end
```

(`request/2` here stands for the file's existing conn-builder helper — use whatever it actually has; if it builds conns inline, do the same.)

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/shem/event_log_test.exs`
Expected: FAIL — events have nil hash / `verify_chain` undefined

- [ ] **Step 3: Session struct** — in `lib/shem/event_log/session.ex`:

```elixir
  defstruct [:id, :started_at, :ended_at, :last_hash, event_count: 0]
```

with typespec addition `last_hash: String.t() | nil,`.

- [ ] **Step 4: Wire append + reopen + verify** — in `lib/shem/event_log.ex`:

a) Alias the chain: `alias Shem.EventLog.{Chain, Event, Session}` (replace the two existing aliases).

b) The append handler computes and stores the hash. Replace the body of `handle_call({:append, ...})`:

```elixir
  def handle_call({:append, session_id, type, payload, parent_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, session}} when handle != nil ->
        event = Event.new(session_id, type, payload, parent_id)
        prev = session.last_hash || Chain.genesis(session_id)
        event = %{event | hash: Chain.next(prev, event)}

        case state.store.append(handle, event) do
          :ok ->
            updated = %{Session.increment(session) | last_hash: event.hash}
            sessions = Map.put(state.sessions, session_id, {handle, updated})
            {:reply, {:ok, event}, %{state | sessions: sessions}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:ok, {nil, _session}} ->
        {:reply, {:error, :session_ended}, state}

      :error ->
        {:reply, {:error, :session_not_found}, state}
    end
  end
```

(This inlines what `get_active_handle/2` did because the handler now needs the session struct too, not just the handle. `get_active_handle/2` stays for the other handlers.)

c) Reopening an existing session must seed `last_hash` from the stored tail, or the chain would restart at genesis mid-session and break verification. In `handle_call({:start_session, session_id}, ...)`, the `:error` branch becomes:

```elixir
      :error ->
        {:ok, handle} = state.store.open(session_id, event_log_path())

        last_hash =
          case state.store.read_all(handle) do
            {:ok, [_ | _] = events} -> List.last(events).hash
            _ -> nil
          end

        session = %Session{
          id: session_id,
          started_at: DateTime.utc_now(),
          last_hash: last_hash
        }

        sessions = Map.put(state.sessions, session_id, {handle, session})
        {:reply, {:ok, session_id}, %{state | sessions: sessions}}
```

(`last_hash: nil` + the `||` in append covers both the brand-new and the legacy-tail cases: nil → genesis.)

d) Public `verify_chain/1` (client section, after `read_session_events/1`):

```elixir
  @spec verify_chain(String.t()) ::
          {:ok, :verified | :legacy, non_neg_integer()}
          | {:error, {:broken_at, String.t()} | :not_found}
  def verify_chain(session_id) do
    case read_session_events(session_id) do
      {:ok, events} -> Chain.verify(events, session_id)
      {:error, _} -> {:error, :not_found}
    end
  end
```

- [ ] **Step 5: REST endpoint** — in `lib/shem/rest/handlers/sessions.ex`, add before `match _` (reuse the file's existing JSON-reply helper):

```elixir
  get "/:id/verify" do
    case Shem.EventLog.verify_chain(id) do
      {:ok, :verified, n} ->
        send_json(conn, 200, %{verified: true, events: n})

      {:ok, :legacy, n} ->
        send_json(conn, 200, %{verified: "legacy", events: n})

      {:error, {:broken_at, event_id}} ->
        send_json(conn, 200, %{verified: false, broken_at: event_id})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "session not found"})
    end
  end
```

(If the handler's helper is named differently than `send_json`, use its name.)

- [ ] **Step 6: Run the event log + REST + replay/branch suites** (branch/replay re-drive append heavily — they must be unaffected):

Run: `mix test test/shem/event_log_test.exs test/shem/event_log/ test/shem/rest/ test/shem/llm/`
Expected: all pass. Watch for tests that construct `Event` structs by hand and assert exact struct equality — the new `hash` field defaults nil, which preserves equality for hand-built structs, but any test asserting a struct round-trip through append will now see a non-nil hash; update those assertions to ignore or expect the hash.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/event_log/session.ex lib/shem/event_log.ex lib/shem/rest/handlers/sessions.ex test/shem/event_log_test.exs test/shem/rest/
git commit -m "feat: hash-chain EventLog appends; verify_chain/1 + GET /api/sessions/:id/verify"
```

---

### Task 6: Full suite, docs sync, spec refinements

**Files:**
- Modify: `docs/superpowers/specs/2026-06-12-phase37-honest-claims-design.md` (two refinement notes)
- Modify: `agent-framework.md` (§2A/§3B/§4 wording — claims now true)

- [ ] **Step 1: Full suite**

Run: `mix test`
Expected: ~960+ tests, 0 failures (baseline 936 + ~25 new). Investigate ANY failure — Task 5 touched the hottest path in the codebase (every event append).

- [ ] **Step 2: Warning check**

Run: `mix compile --force 2>&1 | grep -c "warning:"`
Expected: 1 (the pre-existing unused-opts warning in adversarial/supervisor.ex). No new warnings.

- [ ] **Step 3: Spec refinement notes** — in the Phase 37 spec, update two points to match what shipped:
- §2: `Trust.Store.seed/2` (score 0.5, hardening_count 0, refuses already-rated) replaced the `record/2 + :no_property_tests outcome` mechanism — reason: `record` increments hardening_count, which would display a false "1 hardening".
- §3 fork semantics: replace the "hashes stripped" paragraph with: Branch replays events through normal `EventLog.append` into a new session, so forks carry fresh, valid chains automatically — no stripping needed.

- [ ] **Step 4: Manifest updates** — in `agent-framework.md`:
- §2A (Formal Graduation Gate): keep the claim, it is now true; adjust to the soft-gate reality: "Self-written code is property-gated: tools without StreamData property proofs graduate at reduced trust (:medium) and are visibly penalized until adversarially hardened."
- §3B (Pause-and-Steer): adjust "pauses the background thread scheduler" to "pauses the focused agent at its next turn boundary; typed input is injected as steering context before resume."
- §4 (Cryptographic Audit Trail): keep — now true. Optionally note "per-session sha256 hash chain; `verify_chain/1` and `GET /api/sessions/:id/verify`".

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-06-12-phase37-honest-claims-design.md agent-framework.md
git commit -m "docs: Phase 37 spec refinements; manifest claims updated to match shipped reality"
```

---

## Post-implementation checklist (not separate tasks)

- Update memory `project_shem.md`: Phase 37 ✅; Phase 38 (Launch Demo) becomes next.
- Manual smoke (needs TTY + LLM): start a long task, SPACE mid-run, type steering, SPACE — watch the EventLog via `/history`.
- Success criteria from the spec map: Task 1+2 (pause/steer events observable), Task 3 (trust :medium vs :unrated), Task 4+5 (verified/legacy/broken_at + REST).
