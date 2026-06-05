# Phase 6b: Timeline Branching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Shem.LLM.Branch` — fork an existing session at any point, inject synthetic LLM responses, run agent code, and compare outcomes across branches at zero LLM cost.

**Architecture:** Extract shared pipeline mechanics from `Shem.LLM.Replay` into `Shem.LLM.Replay.Utils`. Build `Shem.LLM.Branch` on top — `branch_at/4` splits the recorded queue into prefix (up to fork point) + caller-supplied alt entries; `branch_after_call/4` resolves a call index to an event ID and delegates; `compare/2` aligns multiple branch sessions by call index and reports differences.

**Tech Stack:** Elixir/OTP, ExUnit. No new deps. Builds on Phase 6a (`Shem.LLM.Replay`, `ReplayTransport`, `EventLog`).

**Spec:** `docs/superpowers/specs/2026-06-04-phase-6b-branch-design.md`

---

## File Map

**Create:**
- `lib/shem/llm/replay/utils.ex` — `run_with_pipeline/2`, `extract_llm_pairs/1`, `build_queue_from_pairs/1`
- `lib/shem/llm/branch.ex` — `branch_at/4`, `branch_after_call/4`, `compare/2`
- `test/shem/llm/branch_test.exs`

**Modify:**
- `lib/shem/llm/replay.ex` — delegate private functions to `Replay.Utils`; public API unchanged

---

## Task 1: Extract `Shem.LLM.Replay.Utils`

Promote three private functions from `Shem.LLM.Replay` into a shared module so `Branch` can reuse them without duplication. `Replay`'s public API and all 12 existing tests stay unchanged.

**Files:**
- Create: `lib/shem/llm/replay/utils.ex`
- Modify: `lib/shem/llm/replay.ex`

- [ ] **Step 1: Create `lib/shem/llm/replay/utils.ex`**

```elixir
defmodule Shem.LLM.Replay.Utils do
  alias Shem.LLM.ReplayTransport
  alias Shem.LLM.Middleware.{BudgetCheck, EventLogger}
  alias Shem.LLM.BudgetServer

  @spec run_with_pipeline([map()], (String.t() -> result)) :: {:ok, String.t(), result}
        when result: term()
  def run_with_pipeline(queue, fun) when is_function(fun, 1) do
    server_name = :"replay_transport_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = ReplayTransport.Server.start_link(name: server_name)

    try do
      ReplayTransport.Server.load(server_name, queue)

      replay_pipeline = [
        {BudgetCheck, [budget_server: BudgetServer]},
        {EventLogger, []},
        {ReplayTransport, [server: server_name]}
      ]

      Process.put(:shem_replay_pipeline, replay_pipeline)
      {:ok, session_id} = Shem.EventLog.start_session()
      result = fun.(session_id)
      {:ok, session_id, result}
    after
      Process.delete(:shem_replay_pipeline)
      GenServer.stop(server_name, :normal, 1_000)
    end
  end

  @spec extract_llm_pairs([Shem.EventLog.Event.t()]) ::
          [{Shem.EventLog.Event.t(), Shem.EventLog.Event.t()}]
  def extract_llm_pairs(events) do
    {_pending, pairs} =
      Enum.reduce(events, {nil, []}, fn event, {pending_start, acc} ->
        case {event.type, pending_start} do
          {:llm_call_started, _} ->
            {event, acc}

          {:llm_call_completed, start} when not is_nil(start) ->
            {nil, [{start, event} | acc]}

          {:llm_call_failed, start} when not is_nil(start) ->
            {nil, [{start, event} | acc]}

          _ ->
            {pending_start, acc}
        end
      end)

    Enum.reverse(pairs)
  end

  @spec build_queue_from_pairs([{Shem.EventLog.Event.t(), Shem.EventLog.Event.t()}]) :: [map()]
  def build_queue_from_pairs(pairs) do
    Enum.map(pairs, fn
      {started, %{type: :llm_call_completed} = completed} ->
        %{
          prompt: started.payload[:prompt],
          content: completed.payload[:content],
          tokens_used: completed.payload[:tokens_used]
        }

      {started, %{type: :llm_call_failed} = failed} ->
        %{
          prompt: started.payload[:prompt],
          error: failed.payload[:reason]
        }
    end)
  end
end
```

- [ ] **Step 2: Replace `lib/shem/llm/replay.ex`**

```elixir
defmodule Shem.LLM.Replay do
  alias Shem.LLM.Replay.Utils

  @spec with_replay(String.t(), (String.t() -> result)) ::
          {:ok, String.t(), result} | {:error, term()}
        when result: term()
  def with_replay(original_session_id, fun) when is_function(fun, 1) do
    with {:ok, queue} <- extract_queue(original_session_id) do
      Utils.run_with_pipeline(queue, fun)
    end
  end

  @spec diff(String.t(), String.t()) :: [map()]
  def diff(session_a_id, session_b_id) do
    with {:ok, events_a} <- Shem.EventLog.events(session_a_id),
         {:ok, events_b} <- Shem.EventLog.events(session_b_id) do
      calls_a = extract_call_summaries(events_a)
      calls_b = extract_call_summaries(events_b)
      compare_calls(calls_a, calls_b)
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp extract_queue(session_id) do
    case Shem.EventLog.events(session_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, events} ->
        queue =
          events
          |> Utils.extract_llm_pairs()
          |> Utils.build_queue_from_pairs()

        cond do
          queue == [] ->
            {:error, :no_llm_events}

          Enum.any?(queue, fn e -> Map.has_key?(e, :content) and is_nil(e[:content]) end) ->
            {:error, :no_llm_events}

          true ->
            {:ok, queue}
        end
    end
  end

  defp extract_call_summaries(events) do
    events
    |> Utils.extract_llm_pairs()
    |> Enum.with_index()
    |> Enum.map(fn {{started, outcome}, idx} ->
      %{
        call_index: idx,
        prompt: started.payload[:prompt],
        content: outcome.payload[:content],
        outcome: outcome.type
      }
    end)
  end

  defp compare_calls(calls_a, calls_b) do
    max_len = max(length(calls_a), length(calls_b))

    if max_len == 0 do
      []
    else
      Enum.flat_map(0..(max_len - 1), fn i ->
        a = Enum.at(calls_a, i)
        b = Enum.at(calls_b, i)

        cond do
          is_nil(a) ->
            [%{call_index: i, type: :missing_in_original, original: nil, replay: b}]

          is_nil(b) ->
            [%{call_index: i, type: :missing_in_replay, original: a, replay: nil}]

          a.prompt != b.prompt ->
            [%{call_index: i, type: :prompt_diverged, original: a, replay: b}]

          true ->
            []
        end
      end)
    end
  end
end
```

- [ ] **Step 3: Run Replay tests to verify refactor**

```bash
mix test test/shem/llm/replay_test.exs
```

Expected: 12 passed, 0 failures.

- [ ] **Step 4: Run full suite to confirm no regressions**

```bash
mix test
```

Expected: 247 passed, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/replay/utils.ex lib/shem/llm/replay.ex
git commit -m "refactor: extract Shem.LLM.Replay.Utils for shared pipeline mechanics"
```

---

## Task 2: `Shem.LLM.Branch.branch_at/4`

**Files:**
- Create: `lib/shem/llm/branch.ex`
- Create: `test/shem/llm/branch_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/shem/llm/branch_test.exs`:

```elixir
defmodule Shem.LLM.BranchTest do
  use ExUnit.Case, async: false

  alias Shem.LLM
  alias Shem.LLM.{Request, Response, Branch}
  alias Shem.LLM.StubTransport.Server, as: StubServer

  defp record_session(exchanges) do
    {:ok, sid} = Shem.EventLog.start_session()

    Enum.each(exchanges, fn {prompt, content, tokens} ->
      StubServer.push_response(
        {:ok, %Response{content: content, tokens_used: tokens, model: :default, latency_ms: 1}}
      )
      LLM.complete(%Request{prompt: prompt, model: :default, session_id: sid})
    end)

    sid
  end

  defp nth_completed_event(sid, n) do
    {:ok, events} = Shem.EventLog.events(sid)
    events |> Enum.filter(&(&1.type == :llm_call_completed)) |> Enum.at(n)
  end

  setup do
    Shem.LLM.BudgetServer.reset()
    StubServer.reset()
    :ok
  end

  describe "branch_at/4 — happy path" do
    test "returns {:ok, branch_sid, result}" do
      original_sid = record_session([{"q1", "a1", 5}])
      fork_event = nth_completed_event(original_sid, 0)

      assert {:ok, branch_sid, :done} =
               Branch.branch_at(original_sid, fork_event.id, [], fn _sid -> :done end)

      assert String.starts_with?(branch_sid, "ses_")
      assert branch_sid != original_sid
    end

    test "prefix call is served from recording" do
      original_sid = record_session([{"q1", "a1", 5}, {"q2", "a2", 3}])
      fork_event = nth_completed_event(original_sid, 0)

      {:ok, _branch_sid, response} =
        Branch.branch_at(
          original_sid,
          fork_event.id,
          [%{content: "alt answer", tokens_used: 7}],
          fn branch_sid ->
            LLM.complete(%Request{prompt: "q1", model: :default, session_id: branch_sid})
          end
        )

      assert {:ok, %Response{content: "a1"}} = response
    end

    test "alt queue is served after the fork" do
      original_sid = record_session([{"q1", "a1", 5}])
      fork_event = nth_completed_event(original_sid, 0)

      {:ok, _branch_sid, response} =
        Branch.branch_at(
          original_sid,
          fork_event.id,
          [%{content: "alt answer", tokens_used: 7}],
          fn branch_sid ->
            LLM.complete(%Request{prompt: "q1", model: :default, session_id: branch_sid})
            LLM.complete(%Request{prompt: "q2", model: :default, session_id: branch_sid})
          end
        )

      assert {:ok, %Response{content: "alt answer"}} = response
    end

    test "fork before all LLM calls yields empty prefix — full alt queue used" do
      original_sid = record_session([{"q1", "a1", 5}])
      {:ok, events} = Shem.EventLog.events(original_sid)
      first_event = hd(events)

      {:ok, _branch_sid, response} =
        Branch.branch_at(
          original_sid,
          first_event.id,
          [%{content: "synthetic", tokens_used: 2}],
          fn branch_sid ->
            LLM.complete(%Request{prompt: "q1", model: :default, session_id: branch_sid})
          end
        )

      assert {:ok, %Response{content: "synthetic"}} = response
    end

    test "branch session contains :branch_created event with correct provenance" do
      original_sid = record_session([{"q1", "a1", 5}])
      fork_event = nth_completed_event(original_sid, 0)

      {:ok, branch_sid, _} =
        Branch.branch_at(
          original_sid,
          fork_event.id,
          [%{content: "x", tokens_used: 1}],
          fn _sid -> :ok end
        )

      {:ok, events} = Shem.EventLog.events(branch_sid)
      created = Enum.find(events, &(&1.type == :branch_created))
      assert created.payload.original_session_id == original_sid
      assert created.payload.fork_event_id == fork_event.id
      assert created.payload.alt_count == 1
    end

    test "process dict is cleaned up after branch_at" do
      original_sid = record_session([{"q", "a", 1}])
      fork_event = nth_completed_event(original_sid, 0)
      Branch.branch_at(original_sid, fork_event.id, [], fn _sid -> :ok end)
      assert Process.get(:shem_replay_pipeline) == nil
    end

    test "process dict cleaned up when fun raises" do
      original_sid = record_session([{"q", "a", 1}])
      fork_event = nth_completed_event(original_sid, 0)

      assert_raise RuntimeError, fn ->
        Branch.branch_at(original_sid, fork_event.id, [], fn _sid -> raise "boom" end)
      end

      assert Process.get(:shem_replay_pipeline) == nil
    end
  end

  describe "branch_at/4 — error cases" do
    test "{:error, :session_not_found} for unknown session" do
      assert {:error, :session_not_found} =
               Branch.branch_at("ses_unknown00", "evt_x", [], fn _sid -> :ok end)
    end

    test "{:error, :no_llm_events} for session with no LLM calls" do
      {:ok, sid} = Shem.EventLog.start_session()

      assert {:error, :no_llm_events} =
               Branch.branch_at(sid, "evt_x", [], fn _sid -> :ok end)
    end

    test "{:error, :fork_event_not_found} for unknown event ID" do
      original_sid = record_session([{"q", "a", 1}])

      assert {:error, :fork_event_not_found} =
               Branch.branch_at(original_sid, "evt_nonexistent", [], fn _sid -> :ok end)
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
mix test test/shem/llm/branch_test.exs
```

Expected: compilation error — `Shem.LLM.Branch` not found.

- [ ] **Step 3: Implement `lib/shem/llm/branch.ex`** (branch_at only)

```elixir
defmodule Shem.LLM.Branch do
  alias Shem.LLM.Replay.Utils

  @type alt_entry ::
          %{content: String.t(), tokens_used: non_neg_integer()}
          | %{content: String.t(), tokens_used: non_neg_integer(), label: String.t()}
          | %{error: String.t()}

  @type diff_entry :: %{
          call_index: non_neg_integer(),
          type: :identical | :content_differs,
          branches: [%{label: String.t(), content: String.t() | nil, prompt: String.t() | nil}]
        }

  @spec branch_at(String.t(), String.t(), [alt_entry()], (String.t() -> result)) ::
          {:ok, String.t(), result} | {:error, term()}
        when result: term()
  def branch_at(original_session_id, fork_event_id, alt_queue, fun)
      when is_function(fun, 1) do
    with {:ok, events} <- fetch_events_with_llm_check(original_session_id),
         {:ok, fork_index} <- find_fork_event_index(events, fork_event_id) do
      prefix_queue = build_prefix_queue(events, fork_index)
      full_queue = prefix_queue ++ alt_queue

      Utils.run_with_pipeline(full_queue, fn session_id ->
        Shem.EventLog.append(session_id, :branch_created, %{
          original_session_id: original_session_id,
          fork_event_id: fork_event_id,
          alt_count: length(alt_queue)
        })

        fun.(session_id)
      end)
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp fetch_events_with_llm_check(session_id) do
    case Shem.EventLog.events(session_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, events} ->
        if Utils.extract_llm_pairs(events) == [] do
          {:error, :no_llm_events}
        else
          {:ok, events}
        end
    end
  end

  defp find_fork_event_index(events, fork_event_id) do
    case Enum.find_index(events, &(&1.id == fork_event_id)) do
      nil -> {:error, :fork_event_not_found}
      index -> {:ok, index}
    end
  end

  defp build_prefix_queue(events, fork_index) do
    events
    |> Enum.take(fork_index + 1)
    |> Utils.extract_llm_pairs()
    |> Utils.build_queue_from_pairs()
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/llm/branch_test.exs
```

Expected: 10 passed, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/branch.ex test/shem/llm/branch_test.exs
git commit -m "feat: Shem.LLM.Branch.branch_at/4 — fork session at event with synthetic alt queue"
```

---

## Task 3: `Shem.LLM.Branch.branch_after_call/4`

**Files:**
- Modify: `lib/shem/llm/branch.ex`
- Modify: `test/shem/llm/branch_test.exs`

- [ ] **Step 1: Add failing tests**

Append to `test/shem/llm/branch_test.exs` (inside the module, after the last `describe` block):

```elixir
  describe "branch_after_call/4" do
    test "forks after call index 0 — prefix has 1 call" do
      original_sid = record_session([{"q1", "a1", 5}, {"q2", "a2", 3}])

      {:ok, branch_sid, _} =
        Branch.branch_after_call(
          original_sid,
          0,
          [%{content: "alt", tokens_used: 1}],
          fn sid ->
            LLM.complete(%Request{prompt: "q1", model: :default, session_id: sid})
            LLM.complete(%Request{prompt: "q2", model: :default, session_id: sid})
          end
        )

      {:ok, events} = Shem.EventLog.events(branch_sid)
      contents = events |> Enum.filter(&(&1.type == :llm_call_completed)) |> Enum.map(& &1.payload.content)
      assert contents == ["a1", "alt"]
    end

    test "forks after last call index (N-1) — prefix has all recorded calls" do
      original_sid = record_session([{"q1", "a1", 5}, {"q2", "a2", 3}])

      {:ok, branch_sid, _} =
        Branch.branch_after_call(
          original_sid,
          1,
          [%{content: "alt2", tokens_used: 2}],
          fn sid ->
            LLM.complete(%Request{prompt: "q1", model: :default, session_id: sid})
            LLM.complete(%Request{prompt: "q2", model: :default, session_id: sid})
            LLM.complete(%Request{prompt: "q3", model: :default, session_id: sid})
          end
        )

      {:ok, events} = Shem.EventLog.events(branch_sid)
      contents = events |> Enum.filter(&(&1.type == :llm_call_completed)) |> Enum.map(& &1.payload.content)
      assert contents == ["a1", "a2", "alt2"]
    end

    test "returns {:error, :call_index_out_of_range} when index >= total calls" do
      original_sid = record_session([{"q1", "a1", 5}])

      assert {:error, :call_index_out_of_range} =
               Branch.branch_after_call(original_sid, 1, [], fn _sid -> :ok end)
    end

    test "branch session has :branch_created event (delegates to branch_at)" do
      original_sid = record_session([{"q1", "a1", 5}])

      {:ok, branch_sid, _} =
        Branch.branch_after_call(original_sid, 0, [], fn _sid -> :ok end)

      {:ok, events} = Shem.EventLog.events(branch_sid)
      assert Enum.any?(events, &(&1.type == :branch_created))
    end
  end
```

- [ ] **Step 2: Run to verify failure**

```bash
mix test test/shem/llm/branch_test.exs
```

Expected: 4 failures — `Branch.branch_after_call/4` undefined.

- [ ] **Step 3: Add `branch_after_call/4` to `lib/shem/llm/branch.ex`**

Insert after the `branch_at/4` definition and before the `# ── Private` comment:

```elixir
  @spec branch_after_call(String.t(), non_neg_integer(), [alt_entry()], (String.t() -> result)) ::
          {:ok, String.t(), result} | {:error, term()}
        when result: term()
  def branch_after_call(original_session_id, call_index, alt_queue, fun)
      when is_function(fun, 1) and is_integer(call_index) and call_index >= 0 do
    case Shem.EventLog.events(original_session_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, events} ->
        completed = Enum.filter(events, &(&1.type == :llm_call_completed))

        case Enum.at(completed, call_index) do
          nil -> {:error, :call_index_out_of_range}
          event -> branch_at(original_session_id, event.id, alt_queue, fun)
        end
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/llm/branch_test.exs
```

Expected: 14 passed, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/branch.ex test/shem/llm/branch_test.exs
git commit -m "feat: Shem.LLM.Branch.branch_after_call/4 — fork by LLM call index"
```

---

## Task 4: `Shem.LLM.Branch.compare/2` + full suite

**Files:**
- Modify: `lib/shem/llm/branch.ex`
- Modify: `test/shem/llm/branch_test.exs`

- [ ] **Step 1: Add failing tests**

Append to `test/shem/llm/branch_test.exs` (inside the module, after the `branch_after_call` describe block):

```elixir
  describe "compare/2" do
    test "all :identical when branches have the same content at every call" do
      original_sid = record_session([{"q1", "a1", 5}])
      fork_event = nth_completed_event(original_sid, 0)

      {:ok, sid_a, _} =
        Branch.branch_at(original_sid, fork_event.id, [%{content: "same", tokens_used: 1}], fn sid ->
          LLM.complete(%Request{prompt: "q1", model: :default, session_id: sid})
          LLM.complete(%Request{prompt: "q2", model: :default, session_id: sid})
        end)

      {:ok, sid_b, _} =
        Branch.branch_at(original_sid, fork_event.id, [%{content: "same", tokens_used: 1}], fn sid ->
          LLM.complete(%Request{prompt: "q1", model: :default, session_id: sid})
          LLM.complete(%Request{prompt: "q2", model: :default, session_id: sid})
        end)

      result = Branch.compare([{"A", sid_a}, {"B", sid_b}])
      assert Enum.all?(result, &(&1.type == :identical))
    end

    test "returns :content_differs at the alt call index" do
      original_sid = record_session([{"q1", "a1", 5}])
      fork_event = nth_completed_event(original_sid, 0)

      {:ok, sid_a, _} =
        Branch.branch_at(original_sid, fork_event.id, [%{content: "response A", tokens_used: 1}], fn sid ->
          LLM.complete(%Request{prompt: "q1", model: :default, session_id: sid})
          LLM.complete(%Request{prompt: "q2", model: :default, session_id: sid})
        end)

      {:ok, sid_b, _} =
        Branch.branch_at(original_sid, fork_event.id, [%{content: "response B", tokens_used: 1}], fn sid ->
          LLM.complete(%Request{prompt: "q1", model: :default, session_id: sid})
          LLM.complete(%Request{prompt: "q2", model: :default, session_id: sid})
        end)

      result = Branch.compare([{"A", sid_a}, {"B", sid_b}])
      diverged = Enum.find(result, &(&1.type == :content_differs))
      assert diverged.call_index == 1
      labels = Enum.map(diverged.branches, & &1.label)
      assert "A" in labels and "B" in labels
    end

    test "three branches all differing at alt call — all listed in branches" do
      original_sid = record_session([{"q1", "a1", 5}])
      fork_event = nth_completed_event(original_sid, 0)

      for {content, label} <- [{"X", "A"}, {"Y", "B"}, {"Z", "C"}] do
        Branch.branch_at(original_sid, fork_event.id, [%{content: content, tokens_used: 1}], fn sid ->
          LLM.complete(%Request{prompt: "q1", model: :default, session_id: sid})
          LLM.complete(%Request{prompt: "q2", model: :default, session_id: sid})
        end)
        |> then(fn {:ok, sid, _} -> {label, sid} end)
      end
      |> then(fn labelled ->
        result = Branch.compare(labelled)
        diverged = Enum.find(result, &(&1.type == :content_differs))
        contents = Enum.map(diverged.branches, & &1.content)
        assert "X" in contents and "Y" in contents and "Z" in contents
      end)
    end

    test "shorter branch produces nil content at missing call index" do
      original_sid = record_session([{"q1", "a1", 5}])
      fork_event = nth_completed_event(original_sid, 0)

      {:ok, sid_long, _} =
        Branch.branch_at(original_sid, fork_event.id, [%{content: "alt", tokens_used: 1}], fn sid ->
          LLM.complete(%Request{prompt: "q1", model: :default, session_id: sid})
          LLM.complete(%Request{prompt: "q2", model: :default, session_id: sid})
        end)

      {:ok, sid_short, _} =
        Branch.branch_at(original_sid, fork_event.id, [], fn sid ->
          LLM.complete(%Request{prompt: "q1", model: :default, session_id: sid})
        end)

      result = Branch.compare([{"long", sid_long}, {"short", sid_short}])
      entry = Enum.find(result, &(&1.call_index == 1))
      short_entry = Enum.find(entry.branches, &(&1.label == "short"))
      assert short_entry.content == nil
    end

    test "returns {:error, :session_not_found} for unknown session" do
      assert {:error, :session_not_found} =
               Branch.compare([{"A", "ses_unknown00"}])
    end
  end
```

- [ ] **Step 2: Run to verify failure**

```bash
mix test test/shem/llm/branch_test.exs
```

Expected: 5 failures — `Branch.compare/2` undefined (first 4 tests) and the error test.

- [ ] **Step 3: Add `compare/2` to `lib/shem/llm/branch.ex`**

Insert after `branch_after_call/4` and before `# ── Private`:

```elixir
  @spec compare([{String.t(), String.t()}]) :: [diff_entry()] | {:error, term()}
  def compare(labelled_sessions) when is_list(labelled_sessions) do
    results =
      Enum.map(labelled_sessions, fn {label, session_id} ->
        case Shem.EventLog.events(session_id) do
          {:error, reason} ->
            {:error, reason}

          {:ok, events} ->
            summaries =
              events
              |> Utils.extract_llm_pairs()
              |> Enum.with_index()
              |> Enum.map(fn {{started, outcome}, idx} ->
                %{
                  call_index: idx,
                  label: label,
                  prompt: started.payload[:prompt],
                  content: outcome.payload[:content]
                }
              end)

            {:ok, label, summaries}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        max_len =
          results
          |> Enum.map(fn {:ok, _label, summaries} -> length(summaries) end)
          |> Enum.max(fn -> 0 end)

        if max_len == 0 do
          []
        else
          Enum.map(0..(max_len - 1), fn i ->
            entries =
              Enum.map(results, fn {:ok, label, summaries} ->
                case Enum.at(summaries, i) do
                  nil -> %{label: label, prompt: nil, content: nil}
                  s -> %{label: label, prompt: s.prompt, content: s.content}
                end
              end)

            contents = Enum.map(entries, & &1.content)
            type = if length(Enum.uniq(contents)) == 1, do: :identical, else: :content_differs

            %{call_index: i, type: type, branches: entries}
          end)
        end
    end
  end
```

- [ ] **Step 4: Run Branch tests to verify all pass**

```bash
mix test test/shem/llm/branch_test.exs
```

Expected: 19 passed, 0 failures.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: ~266 passed, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/llm/branch.ex test/shem/llm/branch_test.exs
git commit -m "feat: Shem.LLM.Branch.compare/2 — multi-branch diff aligned by call index"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| `Replay.Utils` extracted with `run_with_pipeline/2`, `extract_llm_pairs/1`, `build_queue_from_pairs/1` | Task 1 |
| `Replay` refactored to delegate to `Utils`; public API unchanged | Task 1 |
| `branch_at/4` — prefix queue from recording, alt queue from caller | Task 2 |
| `branch_at/4` — fork before all LLM calls = empty prefix, valid | Task 2 |
| `branch_at/4` — `:branch_created` event with provenance | Task 2 |
| `branch_at/4` — process dict cleanup via try/after | Task 2 |
| `branch_at/4` — `{:error, :session_not_found}` | Task 2 |
| `branch_at/4` — `{:error, :no_llm_events}` | Task 2 |
| `branch_at/4` — `{:error, :fork_event_not_found}` | Task 2 |
| `branch_after_call/4` — resolves call index 0 and N-1 | Task 3 |
| `branch_after_call/4` — `{:error, :call_index_out_of_range}` | Task 3 |
| `compare/2` — `:identical` / `:content_differs` per call index | Task 4 |
| `compare/2` — three branches, all listed in diff entry | Task 4 |
| `compare/2` — shorter branch produces `nil` content | Task 4 |
| `compare/2` — `{:error, :session_not_found}` | Task 4 |

All spec requirements covered.
