# Phase 6a: Replay & LLM Call Mocking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build deterministic replay of agent sessions using recorded LLM responses, enabling golden session regression testing.

**Architecture:** `EventLogger` is patched to record `prompt` and `content` in LLM call events. `ReplayTransport` is a terminal middleware that pops recorded responses from `ReplayTransport.Server` instead of hitting the model. `Shem.LLM.Replay.with_replay/2` swaps the pipeline per-process via the process dictionary and runs caller-provided agent code against the replay. `diff/2` compares two sessions' LLM call sequences.

**Tech Stack:** Elixir/OTP, ExUnit. No new deps. Builds on Phase 5 (`Shem.LLM`, `EventLog`, `StubTransport` pattern).

**Spec:** `docs/superpowers/specs/2026-06-04-phase-6a-replay-design.md`

---

## File Map

**Modify:**
- `lib/shem/llm/middleware/event_logger.ex` — add `prompt:` to `:llm_call_started`, `content:` to `:llm_call_completed`
- `lib/shem/llm.ex` — `build_pipeline/0` checks `Process.get(:shem_replay_pipeline)` first
- `test/shem/llm/middleware/event_logger_test.exs` — add assertions for new payload fields

**Create:**
- `lib/shem/llm/replay_transport/server.ex` — GenServer holding ordered response queue + call index
- `lib/shem/llm/replay_transport.ex` — terminal middleware: pop, compare prompts, record divergence/exhaustion
- `lib/shem/llm/replay.ex` — `with_replay/2` coordinator + `diff/2` utility
- `test/shem/llm/replay_transport/server_test.exs`
- `test/shem/llm/replay_transport_test.exs`
- `test/shem/llm/replay_test.exs`

---

## Task 1: EventLogger patch — record prompt and content

**Files:**
- Modify: `lib/shem/llm/middleware/event_logger.ex`
- Modify: `test/shem/llm/middleware/event_logger_test.exs`

- [ ] **Step 1: Add two regression tests for the new payload fields**

Open `test/shem/llm/middleware/event_logger_test.exs` and add inside `describe "call/3 — with valid session_id"`:

```elixir
test ":llm_call_started event carries prompt" do
  {:ok, sid} = Shem.EventLog.start_session()
  next = fn _req -> {:ok, ok_response(5)} end

  EventLogger.call(%Request{prompt: "tell me about BEAM", model: :default, session_id: sid}, [], next)

  {:ok, events} = Shem.EventLog.events(sid)
  started = Enum.find(events, &(&1.type == :llm_call_started))
  assert started.payload.prompt == "tell me about BEAM"
end

test ":llm_call_completed event carries content" do
  {:ok, sid} = Shem.EventLog.start_session()
  next = fn _req ->
    {:ok, %Response{content: "BEAM is great", tokens_used: 10, model: :default, latency_ms: 1}}
  end

  EventLogger.call(%Request{prompt: "hi", model: :default, session_id: sid}, [], next)

  {:ok, events} = Shem.EventLog.events(sid)
  completed = Enum.find(events, &(&1.type == :llm_call_completed))
  assert completed.payload.content == "BEAM is great"
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/llm/middleware/event_logger_test.exs
```

Expected: 2 failures — `payload.prompt` and `payload.content` are `nil` / key not found.

- [ ] **Step 3: Patch EventLogger**

Replace `lib/shem/llm/middleware/event_logger.ex` with:

```elixir
defmodule Shem.LLM.Middleware.EventLogger do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(%{session_id: nil} = request, _opts, next), do: next.(request)

  def call(request, _opts, next) do
    Shem.EventLog.append(request.session_id, :llm_call_started, %{
      model: request.model,
      prompt: request.prompt
    })

    start_ms = System.monotonic_time(:millisecond)
    result = next.(request)
    latency_ms = System.monotonic_time(:millisecond) - start_ms

    case result do
      {:ok, response} ->
        Shem.EventLog.append(request.session_id, :llm_call_completed, %{
          tokens_used: response.tokens_used,
          latency_ms: latency_ms,
          content: response.content
        })

      {:error, reason} ->
        Shem.EventLog.append(request.session_id, :llm_call_failed, %{
          reason: inspect(reason)
        })
    end

    result
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/llm/middleware/event_logger_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Run full suite to confirm no regressions**

```bash
mix test
```

Expected: 218 tests + 2 new = 220 passed, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/llm/middleware/event_logger.ex \
        test/shem/llm/middleware/event_logger_test.exs
git commit -m "feat: EventLogger records prompt and content for Phase 6a replay"
```

---

## Task 2: `Shem.LLM.build_pipeline/0` — process dictionary override

**Files:**
- Modify: `lib/shem/llm.ex`

- [ ] **Step 1: Update `build_pipeline/0`**

Replace the `build_pipeline/0` private function in `lib/shem/llm.ex`:

```elixir
defp build_pipeline do
  pipeline =
    Process.get(:shem_replay_pipeline) ||
      Application.get_env(:shem, :llm_pipeline, [])

  terminal = fn _req -> {:error, :no_terminal} end

  pipeline
  |> normalize_pipeline()
  |> Enum.reverse()
  |> Enum.reduce(terminal, fn {mod, opts}, next ->
    fn req -> mod.call(req, opts, next) end
  end)
end
```

- [ ] **Step 2: Run existing tests to confirm nothing broke**

```bash
mix test test/shem/llm_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add lib/shem/llm.ex
git commit -m "feat: Shem.LLM.build_pipeline checks process dict for replay pipeline override"
```

---

## Task 3: `ReplayTransport.Server`

**Files:**
- Create: `lib/shem/llm/replay_transport/server.ex`
- Create: `test/shem/llm/replay_transport/server_test.exs`

- [ ] **Step 1: Write failing tests**

`test/shem/llm/replay_transport/server_test.exs`:

```elixir
defmodule Shem.LLM.ReplayTransport.ServerTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.ReplayTransport.Server

  defp start_server do
    name = :"replay_srv_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Server, name: name})
    name
  end

  defp success_entry(prompt, content, tokens) do
    %{prompt: prompt, content: content, tokens_used: tokens}
  end

  defp failure_entry(prompt, reason) do
    %{prompt: prompt, error: reason}
  end

  describe "load/2 and pop/1" do
    test "pops entries in queue order" do
      srv = start_server()
      queue = [success_entry("p1", "c1", 10), success_entry("p2", "c2", 20)]
      Server.load(srv, queue)

      assert {:ok, %{prompt: "p1", content: "c1"}, 0} = Server.pop(srv)
      assert {:ok, %{prompt: "p2", content: "c2"}, 1} = Server.pop(srv)
    end

    test "returns {:exhausted, call_index} when queue is empty" do
      srv = start_server()
      Server.load(srv, [success_entry("p1", "c1", 5)])

      Server.pop(srv)
      assert {:exhausted, 1} = Server.pop(srv)
    end

    test "call_index increments per pop" do
      srv = start_server()
      Server.load(srv, [
        success_entry("p1", "c1", 1),
        success_entry("p2", "c2", 2),
        success_entry("p3", "c3", 3)
      ])

      assert {:ok, _, 0} = Server.pop(srv)
      assert {:ok, _, 1} = Server.pop(srv)
      assert {:ok, _, 2} = Server.pop(srv)
      assert {:exhausted, 3} = Server.pop(srv)
    end

    test "failure entries are returned as-is" do
      srv = start_server()
      Server.load(srv, [failure_entry("p1", ":transport_down")])

      assert {:ok, %{error: ":transport_down"}, 0} = Server.pop(srv)
    end

    test "load/2 resets call_index to 0" do
      srv = start_server()
      Server.load(srv, [success_entry("p1", "c1", 1)])
      Server.pop(srv)

      # reload resets
      Server.load(srv, [success_entry("p2", "c2", 2)])
      assert {:ok, %{prompt: "p2"}, 0} = Server.pop(srv)
    end
  end

  describe "pop/1 before load" do
    test "returns {:exhausted, 0} when never loaded" do
      srv = start_server()
      assert {:exhausted, 0} = Server.pop(srv)
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
mix test test/shem/llm/replay_transport/server_test.exs
```

Expected: compilation error — `Shem.LLM.ReplayTransport.Server` not found.

- [ ] **Step 3: Implement ReplayTransport.Server**

`lib/shem/llm/replay_transport/server.ex`:

```elixir
defmodule Shem.LLM.ReplayTransport.Server do
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @spec load(GenServer.server(), [map()]) :: :ok
  def load(server \\ __MODULE__, queue),
    do: GenServer.call(server, {:load, queue})

  @spec pop(GenServer.server()) ::
          {:ok, map(), non_neg_integer()} | {:exhausted, non_neg_integer()}
  def pop(server \\ __MODULE__),
    do: GenServer.call(server, :pop)

  @impl true
  def init(:ok), do: {:ok, %{queue: [], call_index: 0}}

  @impl true
  def handle_call({:load, queue}, _from, state),
    do: {:reply, :ok, %{state | queue: queue, call_index: 0}}

  @impl true
  def handle_call(:pop, _from, %{queue: [entry | rest]} = state) do
    idx = state.call_index
    {:reply, {:ok, entry, idx}, %{state | queue: rest, call_index: idx + 1}}
  end

  def handle_call(:pop, _from, %{queue: []} = state),
    do: {:reply, {:exhausted, state.call_index}, state}
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/llm/replay_transport/server_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/replay_transport/server.ex \
        test/shem/llm/replay_transport/server_test.exs
git commit -m "feat: Shem.LLM.ReplayTransport.Server — ordered response queue with call index"
```

---

## Task 4: `ReplayTransport` middleware

**Files:**
- Create: `lib/shem/llm/replay_transport.ex`
- Create: `test/shem/llm/replay_transport_test.exs`

- [ ] **Step 1: Write failing tests**

`test/shem/llm/replay_transport_test.exs`:

```elixir
defmodule Shem.LLM.ReplayTransportTest do
  use ExUnit.Case, async: false

  alias Shem.LLM.{Request, Response, ReplayTransport}
  alias Shem.LLM.ReplayTransport.Server

  defp start_server(queue \\ []) do
    name = :"rt_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Server, name: name})
    Server.load(name, queue)
    name
  end

  defp request(prompt, session_id \\ nil) do
    %Request{prompt: prompt, model: :default, session_id: session_id}
  end

  defp success_entry(prompt, content, tokens \\ 10) do
    %{prompt: prompt, content: content, tokens_used: tokens}
  end

  describe "prompt match" do
    test "returns {:ok, %Response{}} with recorded content" do
      srv = start_server([success_entry("hello", "world", 5)])

      assert {:ok, %Response{content: "world", tokens_used: 5, latency_ms: 0}} =
               ReplayTransport.call(request("hello"), [server: srv], fn _ -> :unreachable end)
    end

    test "response carries model atom from request" do
      srv = start_server([success_entry("hi", "there", 3)])

      assert {:ok, %Response{model: :default}} =
               ReplayTransport.call(request("hi"), [server: srv], fn _ -> :unreachable end)
    end

    test "does not append divergence event when prompts match" do
      {:ok, sid} = Shem.EventLog.start_session()
      srv = start_server([success_entry("exact", "reply", 1)])

      ReplayTransport.call(request("exact", sid), [server: srv], fn _ -> :unreachable end)

      {:ok, events} = Shem.EventLog.events(sid)
      assert Enum.all?(events, &(&1.type != :llm_call_diverged))
    end
  end

  describe "prompt divergence" do
    test "still returns recorded content (permissive)" do
      srv = start_server([success_entry("original", "recorded reply", 7)])

      assert {:ok, %Response{content: "recorded reply"}} =
               ReplayTransport.call(request("different"), [server: srv], fn _ -> :unreachable end)
    end

    test "appends :llm_call_diverged event when session_id is set" do
      {:ok, sid} = Shem.EventLog.start_session()
      srv = start_server([success_entry("original prompt", "reply", 5)])

      ReplayTransport.call(request("changed prompt", sid), [server: srv], fn _ -> :unreachable end)

      {:ok, events} = Shem.EventLog.events(sid)
      diverged = Enum.find(events, &(&1.type == :llm_call_diverged))
      assert diverged.payload.original_prompt == "original prompt"
      assert diverged.payload.replay_prompt == "changed prompt"
      assert diverged.payload.recorded_content == "reply"
      assert diverged.payload.call_index == 0
    end

    test "does not append divergence event when session_id is nil" do
      srv = start_server([success_entry("original", "reply", 1)])

      # Should not raise even with nil session
      assert {:ok, _} =
               ReplayTransport.call(request("different", nil), [server: srv], fn _ -> :unreachable end)
    end
  end

  describe "queue exhaustion" do
    test "returns {:error, :replay_exhausted}" do
      srv = start_server([])

      assert {:error, :replay_exhausted} =
               ReplayTransport.call(request("any"), [server: srv], fn _ -> :unreachable end)
    end

    test "appends :replay_exhausted event when session_id is set" do
      {:ok, sid} = Shem.EventLog.start_session()
      srv = start_server([])

      ReplayTransport.call(request("unanswered", sid), [server: srv], fn _ -> :unreachable end)

      {:ok, events} = Shem.EventLog.events(sid)
      exhausted = Enum.find(events, &(&1.type == :replay_exhausted))
      assert exhausted.payload.call_index == 0
      assert exhausted.payload.replay_prompt == "unanswered"
    end
  end

  describe "replayed failures" do
    test "returns {:error, {:replayed_failure, reason_string}}" do
      srv = start_server([%{prompt: "p", error: ":transport_down"}])

      assert {:error, {:replayed_failure, ":transport_down"}} =
               ReplayTransport.call(request("p"), [server: srv], fn _ -> :unreachable end)
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
mix test test/shem/llm/replay_transport_test.exs
```

Expected: compilation error — `Shem.LLM.ReplayTransport` not found.

- [ ] **Step 3: Implement ReplayTransport**

`lib/shem/llm/replay_transport.ex`:

```elixir
defmodule Shem.LLM.ReplayTransport do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(request, opts, _next) do
    server = Keyword.get(opts, :server, __MODULE__.Server)

    case Shem.LLM.ReplayTransport.Server.pop(server) do
      {:ok, %{error: reason_string}, _call_index} ->
        {:error, {:replayed_failure, reason_string}}

      {:ok, %{prompt: original_prompt, content: content, tokens_used: tokens_used}, call_index} ->
        if request.prompt != original_prompt and not is_nil(request.session_id) do
          Shem.EventLog.append(request.session_id, :llm_call_diverged, %{
            call_index: call_index,
            original_prompt: original_prompt,
            replay_prompt: request.prompt,
            recorded_content: content
          })
        end

        {:ok,
         %Shem.LLM.Response{
           content: content,
           tokens_used: tokens_used,
           model: request.model,
           latency_ms: 0
         }}

      {:exhausted, call_index} ->
        if not is_nil(request.session_id) do
          Shem.EventLog.append(request.session_id, :replay_exhausted, %{
            call_index: call_index,
            replay_prompt: request.prompt
          })
        end

        {:error, :replay_exhausted}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/llm/replay_transport_test.exs
```

Expected: 9 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/replay_transport.ex \
        test/shem/llm/replay_transport_test.exs
git commit -m "feat: Shem.LLM.ReplayTransport — terminal middleware serving recorded LLM responses"
```

---

## Task 5: `Shem.LLM.Replay`

**Files:**
- Create: `lib/shem/llm/replay.ex`
- Create: `test/shem/llm/replay_test.exs`

- [ ] **Step 1: Write failing tests**

`test/shem/llm/replay_test.exs`:

```elixir
defmodule Shem.LLM.ReplayTest do
  use ExUnit.Case, async: false

  alias Shem.LLM
  alias Shem.LLM.{Request, Response, Replay}
  alias Shem.LLM.StubTransport.Server, as: StubServer

  # Records a real session using the globally-started StubTransport.
  # Returns the session_id with LLM events recorded.
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

  setup do
    Shem.LLM.BudgetServer.reset()
    Shem.LLM.StubTransport.Server.reset()
    :ok
  end

  describe "with_replay/2 — happy path" do
    test "returns {:ok, replay_session_id, result}" do
      original_sid = record_session([{"what is BEAM?", "a runtime", 5}])

      assert {:ok, replay_sid, :agent_done} =
               Replay.with_replay(original_sid, fn _sid -> :agent_done end)

      assert String.starts_with?(replay_sid, "ses_")
      assert replay_sid != original_sid
    end

    test "LLM calls inside fun receive recorded responses" do
      original_sid = record_session([{"ask", "the answer", 10}])

      {:ok, _replay_sid, response} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "ask", model: :default, session_id: replay_sid})
        end)

      assert {:ok, %Response{content: "the answer"}} = response
    end

    test "replay session event log contains :llm_call_started and :llm_call_completed" do
      original_sid = record_session([{"prompt", "content", 3}])

      {:ok, replay_sid, _} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "prompt", model: :default, session_id: replay_sid})
        end)

      {:ok, events} = Shem.EventLog.events(replay_sid)
      types = Enum.map(events, & &1.type)
      assert :llm_call_started in types
      assert :llm_call_completed in types
    end

    test "process dict is cleaned up after with_replay" do
      original_sid = record_session([{"q", "a", 1}])
      Replay.with_replay(original_sid, fn _sid -> :ok end)
      assert Process.get(:shem_replay_pipeline) == nil
    end
  end

  describe "with_replay/2 — divergence" do
    test "returns result despite prompt divergence" do
      original_sid = record_session([{"original prompt", "recorded answer", 5}])

      {:ok, replay_sid, response} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "different prompt", model: :default, session_id: replay_sid})
        end)

      # Still gets recorded answer
      assert {:ok, %Response{content: "recorded answer"}} = response

      # Divergence event in replay log
      {:ok, events} = Shem.EventLog.events(replay_sid)
      assert Enum.any?(events, &(&1.type == :llm_call_diverged))
    end
  end

  describe "with_replay/2 — exhaustion" do
    test "returns fun result containing {:error, :replay_exhausted}" do
      original_sid = record_session([{"q1", "a1", 5}])

      {:ok, replay_sid, result} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "q1", model: :default, session_id: replay_sid})
          # This second call exceeds the recorded queue
          LLM.complete(%Request{prompt: "q2", model: :default, session_id: replay_sid})
        end)

      assert {:error, :replay_exhausted} = result

      {:ok, events} = Shem.EventLog.events(replay_sid)
      assert Enum.any?(events, &(&1.type == :replay_exhausted))
    end
  end

  describe "with_replay/2 — error cases" do
    test "returns {:error, :session_not_found} for unknown session" do
      assert {:error, :session_not_found} =
               Replay.with_replay("ses_doesnotexist00", fn _sid -> :ok end)
    end

    test "returns {:error, :no_llm_events} for session with no LLM calls" do
      {:ok, sid} = Shem.EventLog.start_session()
      # session exists but has no LLM events
      assert {:error, :no_llm_events} =
               Replay.with_replay(sid, fn _sid -> :ok end)
    end

    test "process dict cleaned up even when fun raises" do
      original_sid = record_session([{"q", "a", 1}])

      assert_raise RuntimeError, fn ->
        Replay.with_replay(original_sid, fn _sid -> raise "boom" end)
      end

      assert Process.get(:shem_replay_pipeline) == nil
    end
  end

  describe "diff/2" do
    test "returns [] for identical replay" do
      original_sid = record_session([{"q1", "a1", 5}, {"q2", "a2", 3}])

      {:ok, replay_sid, _} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "q1", model: :default, session_id: replay_sid})
          LLM.complete(%Request{prompt: "q2", model: :default, session_id: replay_sid})
        end)

      assert [] = Replay.diff(original_sid, replay_sid)
    end

    test "returns diff entry for prompt divergence" do
      original_sid = record_session([{"original", "answer", 5}])

      {:ok, replay_sid, _} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "changed", model: :default, session_id: replay_sid})
        end)

      diffs = Replay.diff(original_sid, replay_sid)
      assert length(diffs) == 1
      assert hd(diffs).type == :prompt_diverged
      assert hd(diffs).call_index == 0
    end

    test "returns :missing_in_replay when replay made fewer calls" do
      original_sid = record_session([{"q1", "a1", 5}, {"q2", "a2", 3}])

      {:ok, replay_sid, _} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "q1", model: :default, session_id: replay_sid})
          # only one call instead of two
        end)

      diffs = Replay.diff(original_sid, replay_sid)
      assert Enum.any?(diffs, &(&1.type == :missing_in_replay))
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
mix test test/shem/llm/replay_test.exs
```

Expected: compilation error — `Shem.LLM.Replay` not found.

- [ ] **Step 3: Implement Shem.LLM.Replay**

`lib/shem/llm/replay.ex`:

```elixir
defmodule Shem.LLM.Replay do
  alias Shem.LLM.ReplayTransport
  alias Shem.LLM.Middleware.{BudgetCheck, EventLogger}
  alias Shem.LLM.BudgetServer

  @spec with_replay(String.t(), (String.t() -> result)) ::
          {:ok, String.t(), result} | {:error, term()}
        when result: term()
  def with_replay(original_session_id, fun) when is_function(fun, 1) do
    with {:ok, queue} <- extract_queue(original_session_id) do
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
        {:ok, replay_session_id} = Shem.EventLog.start_session()
        result = fun.(replay_session_id)
        {:ok, replay_session_id, result}
      after
        Process.delete(:shem_replay_pipeline)
        GenServer.stop(server_name, :normal, 1_000)
      end
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

  # ── Private ─────────────────────────────────────────────────────────────────

  defp extract_queue(session_id) do
    case Shem.EventLog.events(session_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, events} ->
        queue =
          events
          |> pair_llm_events()
          |> Enum.map(fn
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

  defp pair_llm_events(events) do
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

  defp extract_call_summaries(events) do
    events
    |> pair_llm_events()
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

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/llm/replay_test.exs
```

Expected: 12 tests, 0 failures.

- [ ] **Step 5: Run full test suite**

```bash
mix test
```

Expected: all tests passing (220 + ~26 new ≈ 246).

- [ ] **Step 6: Commit**

```bash
git add lib/shem/llm/replay.ex test/shem/llm/replay_test.exs
git commit -m "feat: Shem.LLM.Replay — with_replay/2 coordinator and diff/2 utility"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| `prompt:` in `:llm_call_started` | Task 1 |
| `content:` in `:llm_call_completed` | Task 1 |
| `build_pipeline/0` checks process dict | Task 2 |
| `ReplayTransport.Server` — load/2, pop/1, call_index | Task 3 |
| `ReplayTransport` — match path, diverge path, exhausted path, failure path | Task 4 |
| `:llm_call_diverged` event appended on prompt mismatch | Task 4 |
| `:replay_exhausted` event appended on queue exhaustion | Task 4 |
| `with_replay/2` — happy path, divergence, exhaustion, error cases | Task 5 |
| Process dict cleanup via try/after | Task 5 |
| `{:error, :no_llm_events}` for sessions without recordings | Task 5 |
| `{:error, :no_llm_events}` for pre-Phase-6a sessions (nil content) | Task 5 |
| `diff/2` — identical, diverged, missing_in_replay | Task 5 |
| `{:error, {:replayed_failure, reason}}` for recorded failures | Task 4 |

All spec requirements covered.
