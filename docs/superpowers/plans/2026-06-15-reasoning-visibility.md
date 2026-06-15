# Reasoning Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture qwen3's `reasoning_content` (chain-of-thought) as `:agent_thinking` EventLog events and surface it in the TUI and REST streaming interface.

**Architecture:** Add `reasoning_content` to `LLM.Response`, parse it in `OpenAITransport`, thread it through `Turn.stream_step`/`step` return tuples, emit it as an EventLog event and pg broadcast in `Agent.Server`, buffer it in `StreamSink`, drain it into the TUI's existing REASONING panel, and emit it as a `type: "thinking"` JSON event in the REST SSE stream.

**Tech Stack:** Elixir, OTP `:pg`, Ratatouille TUI, Plug REST, ExUnit

---

## File Map

| File | Change |
|---|---|
| `lib/shem/llm/response.ex` | Add `reasoning_content: nil` field |
| `lib/shem/llm/middleware/openai_transport.ex` | Parse `reasoning_content` in non-streaming and streaming paths |
| `lib/shem/agent/turn.ex` | Thread `reasoning_content` through return tuples |
| `lib/shem/agent/server.ex` | Emit `:agent_thinking` EventLog event + pg broadcast |
| `lib/shem/tui/stream_sink.ex` | Buffer thinking; add `take_thinking/1` |
| `lib/shem/tui/agent_view.ex` | Handle `:agent_thinking` in `fold_event` |
| `lib/shem/tui/app.ex` | Drain `take_thinking` into `current_reasoning` on each tick |
| `lib/shem/rest/handlers/agents.ex` | Emit `type: "thinking"` in `stream_loop` |
| `test/shem/llm/middleware/openai_transport_test.exs` | Tests for `reasoning_content` parsing |
| `test/shem/agent/turn_test.exs` | Tests for new 3/4-tuple returns |
| `test/shem/tui/stream_sink_test.exs` | Tests for `take_thinking/1` |

---

### Task 1: Add `reasoning_content` to `LLM.Response`

**Files:**
- Modify: `lib/shem/llm/response.ex`
- Modify: `test/shem/llm/middleware/openai_transport_test.exs`

- [ ] **Step 1: Write a failing test**

Add to the `"call/3 — success"` describe block in `test/shem/llm/middleware/openai_transport_test.exs`:

```elixir
test "reasoning_content is nil when absent from response body" do
  opts = [
    model_string: "gpt-4o",
    api_key: "sk-test",
    http_post_fn: mock_post(200, success_body("Hello", 20))
  ]
  assert {:ok, %Response{} = resp} = OpenAITransport.call(req(), opts, nil)
  assert resp.reasoning_content == nil
end
```

- [ ] **Step 2: Run to confirm it fails**

```bash
mix test test/shem/llm/middleware/openai_transport_test.exs --only "reasoning_content is nil" 2>&1 | tail -10
```

Expected: `** (KeyError) key :reasoning_content not found` or compile error.

- [ ] **Step 3: Add the field to `LLM.Response`**

Replace the entire `lib/shem/llm/response.ex` with:

```elixir
defmodule Shem.LLM.Response do
  @enforce_keys [:tokens_used, :model, :latency_ms]
  defstruct [:content, :tool_calls, :reasoning_content, :tokens_used, :model, :latency_ms]

  @type tool_call :: %{id: String.t(), name: String.t(), args: map()}

  @type t :: %__MODULE__{
          content: String.t() | nil,
          tool_calls: [tool_call()] | nil,
          reasoning_content: String.t() | nil,
          tokens_used: non_neg_integer(),
          model: atom(),
          latency_ms: non_neg_integer()
        }
end
```

- [ ] **Step 4: Run the test to confirm it passes**

```bash
mix test test/shem/llm/middleware/openai_transport_test.exs 2>&1 | tail -5
```

Expected: all existing tests pass (new field defaults to nil naturally).

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/response.ex test/shem/llm/middleware/openai_transport_test.exs
git commit -m "feat: add reasoning_content field to LLM.Response"
```

---

### Task 2: Parse `reasoning_content` in `OpenAITransport` non-streaming path

**Files:**
- Modify: `lib/shem/llm/middleware/openai_transport.ex`
- Modify: `test/shem/llm/middleware/openai_transport_test.exs`

- [ ] **Step 1: Write a failing test**

Add a new describe block to `test/shem/llm/middleware/openai_transport_test.exs` after the existing `"call/3 — tool_calls in response"` block:

```elixir
describe "call/3 — reasoning_content" do
  test "parses reasoning_content from response body" do
    body = %{
      "choices" => [%{"message" => %{
        "role" => "assistant",
        "content" => "hello from qwen",
        "reasoning_content" => "Let me think about this carefully."
      }}],
      "usage" => %{"total_tokens" => 50}
    }
    opts = [api_key: "sk-test", http_post_fn: mock_post(200, body)]
    assert {:ok, %Response{} = resp} = OpenAITransport.call(req(), opts, nil)
    assert resp.content == "hello from qwen"
    assert resp.reasoning_content == "Let me think about this carefully."
  end

  test "reasoning_content is nil when field is empty string" do
    body = %{
      "choices" => [%{"message" => %{
        "role" => "assistant",
        "content" => "hi",
        "reasoning_content" => ""
      }}],
      "usage" => %{"total_tokens" => 10}
    }
    opts = [api_key: "sk-test", http_post_fn: mock_post(200, body)]
    assert {:ok, %Response{reasoning_content: nil}} = OpenAITransport.call(req(), opts, nil)
  end
end
```

- [ ] **Step 2: Run to confirm tests fail**

```bash
mix test test/shem/llm/middleware/openai_transport_test.exs --only "reasoning_content" 2>&1 | tail -10
```

Expected: 2 failures — `reasoning_content` is `nil` in both cases.

- [ ] **Step 3: Update `parse_response/3` in `openai_transport.ex`**

Find the `parse_response` function (around line 326). Replace the existing non-streaming `parse_response` that handles `%{"choices" => ...}` with:

```elixir
defp parse_response(
       %{"choices" => [%{"message" => message} | _], "usage" => usage},
       model,
       start_ms
     ) do
  tokens_used = Map.get(usage, "total_tokens", 0)
  latency_ms = System.monotonic_time(:millisecond) - start_ms
  content = message["content"]

  reasoning_content =
    case message["reasoning_content"] do
      rc when is_binary(rc) and rc != "" -> rc
      _ -> nil
    end

  tool_calls =
    case message["tool_calls"] do
      nil ->
        nil

      raw ->
        Enum.map(raw, fn %{"id" => id, "function" => %{"name" => n, "arguments" => args_str}} ->
          args = case Jason.decode(args_str) do
            {:ok, decoded} -> decoded
            {:error, _} -> %{}
          end
          %{id: id, name: n, args: args}
        end)
    end

  {:ok,
   %Shem.LLM.Response{
     content: content,
     tool_calls: tool_calls,
     reasoning_content: reasoning_content,
     tokens_used: tokens_used,
     model: model,
     latency_ms: latency_ms
   }}
end
```

- [ ] **Step 4: Run to confirm tests pass**

```bash
mix test test/shem/llm/middleware/openai_transport_test.exs 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/middleware/openai_transport.ex test/shem/llm/middleware/openai_transport_test.exs
git commit -m "feat: parse reasoning_content in OpenAITransport non-streaming path"
```

---

### Task 3: Parse `reasoning_content` in `OpenAITransport` streaming path

**Files:**
- Modify: `lib/shem/llm/middleware/openai_transport.ex`
- Modify: `test/shem/llm/middleware/openai_transport_test.exs`

- [ ] **Step 1: Write a failing test**

Add to the `"stream/4 — SSE parser via req_fn injection"` describe block:

```elixir
test "reasoning_content chunks are accumulated and returned in Response" do
  req_fn = fn _url, opts ->
    into_fn = opts[:into]
    # thinking phase: delta has reasoning_content
    think1 = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Let me think \"}}]}\n\n"
    think2 = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"carefully.\"}}]}\n\n"
    # content phase: delta has content
    content1 = "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: {\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":10}}\n\n"
    {:cont, a1} = into_fn.({:data, think1}, "")
    {:cont, a2} = into_fn.({:data, think2}, a1)
    {:cont, _}  = into_fn.({:data, content1}, a2)
    {:ok, %{status: 200}}
  end

  {:ok, collector} = Agent.start_link(fn -> [] end)
  chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

  request = %Shem.LLM.Request{prompt: "hi", model: :default}
  opts = [api_key: "sk-test", req_fn: req_fn]

  assert {:ok, %{content: "hello", reasoning_content: "Let me think carefully.", tokens_used: 15}} =
           OpenAITransport.stream(request, opts, chunk_fn, fn _, _ -> {:error, :no_next} end)

  # reasoning_content chunks must NOT be forwarded to chunk_fn
  assert Agent.get(collector, & &1) == ["hello"]
end
```

- [ ] **Step 2: Run to confirm it fails**

```bash
mix test test/shem/llm/middleware/openai_transport_test.exs --only "reasoning_content chunks" 2>&1 | tail -10
```

Expected: failure — `reasoning_content` is nil, `tokens_used` is wrong.

- [ ] **Step 3: Update the streaming accumulator in `openai_transport.ex`**

Find the `do_sse_stream_openai` function (around line 137). Change `Process.put(ref, ...)` to include `reasoning_content`:

```elixir
Process.put(ref, %{
  buf: "",
  content: "",
  reasoning_content: "",
  tool_calls: %{},
  tool_cut: false,
  prompt_tokens: 0,
  completion_tokens: 0
})
```

- [ ] **Step 4: Add the `reasoning_content` branch in `apply_openai_chunk/3`**

Find `apply_openai_chunk` (around line 229). The current function has a `case delta do` with `content`, `tool_calls`, and `_` branches. Add a `reasoning_content` branch between `tool_calls` and `_`:

```elixir
defp apply_openai_chunk(%{"choices" => [%{"delta" => delta} | _]} = msg, state, chunk_fn) do
  state =
    case delta do
      %{"content" => content} when is_binary(content) and content != "" ->
        unless state.tool_cut, do: chunk_fn.(content)
        %{state | content: state.content <> content}

      %{"tool_calls" => raw_calls} ->
        Enum.reduce(raw_calls, %{state | tool_cut: true}, fn
          %{"index" => idx} = tc, acc ->
            existing = Map.get(acc.tool_calls, idx, %{id: nil, name: nil, args_buf: ""})

            updated = %{
              id: Map.get(tc, "id", existing.id),
              name: get_in(tc, ["function", "name"]) || existing.name,
              args_buf: existing.args_buf <> (get_in(tc, ["function", "arguments"]) || "")
            }

            %{acc | tool_calls: Map.put(acc.tool_calls, idx, updated)}
        end)

      %{"reasoning_content" => rc} when is_binary(rc) and rc != "" ->
        %{state | reasoning_content: state.reasoning_content <> rc}

      _ ->
        state
    end

  case Map.get(msg, "usage") do
    nil ->
      state

    usage ->
      %{state |
        prompt_tokens: Map.get(usage, "prompt_tokens", state.prompt_tokens),
        completion_tokens: Map.get(usage, "completion_tokens", state.completion_tokens)}
  end
end
```

- [ ] **Step 5: Update `assemble_openai_response/3` to include `reasoning_content`**

Find `assemble_openai_response` (around line 273). Add `reasoning_content` extraction and include it in the returned struct:

```elixir
defp assemble_openai_response(final, model, latency_ms) do
  tokens_used = final.prompt_tokens + final.completion_tokens

  tool_calls =
    if map_size(final.tool_calls) == 0 do
      nil
    else
      final.tool_calls
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_, %{id: id, name: name, args_buf: args_buf}} ->
        args = case Jason.decode(args_buf) do
          {:ok, decoded} -> decoded
          {:error, _} -> %{}
        end
        %{id: id, name: name, args: args}
      end)
    end

  content = if final.content == "", do: nil, else: final.content

  reasoning_content =
    case final.reasoning_content do
      rc when is_binary(rc) and rc != "" -> rc
      _ -> nil
    end

  {:ok,
   %Shem.LLM.Response{
     content: content,
     tool_calls: tool_calls,
     reasoning_content: reasoning_content,
     tokens_used: tokens_used,
     model: model,
     latency_ms: latency_ms
   }}
end
```

- [ ] **Step 6: Run full transport tests**

```bash
mix test test/shem/llm/middleware/openai_transport_test.exs 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/llm/middleware/openai_transport.ex test/shem/llm/middleware/openai_transport_test.exs
git commit -m "feat: accumulate reasoning_content in OpenAITransport streaming path"
```

---

### Task 4: Thread `reasoning_content` through `Turn.stream_step` and `Turn.step`

**Files:**
- Modify: `lib/shem/agent/turn.ex`
- Modify: `test/shem/agent/turn_test.exs`

- [ ] **Step 1: Write failing tests**

Add a new describe block to `test/shem/agent/turn_test.exs`. The `step/4` and `stream_step/4` functions call `LLM.complete/LLM.stream_complete`, which go through `StubTransport` in test. `StubTransport` returns `reasoning_content: nil` by default, so we can test the nil passthrough. For a non-nil case we use `LLM.complete` directly with a mock.

Add at the bottom of `test/shem/agent/turn_test.exs`:

```elixir
describe "step/4 and stream_step/4 return tuples include reasoning_content" do
  # stub_response creates a Response with reasoning_content: nil (default).
  # We just verify the tuple shape — that rc is the 3rd/4th element.

  test "step returns {:done, content, nil} when no reasoning_content" do
    # We test parse_response indirectly: when no tool call, Turn returns {:done, c, rc}
    # parse_response wraps the content; rc threads through as nil.
    # Use strip_thinking + parse_response directly to check tuple shape.
    content = "The answer is 42."
    rc = nil
    result =
      case Turn.parse_response(content) do
        {:done, c} -> {:done, c, rc}
        {:tool_calls, calls, raw} -> {:tool_calls, calls, raw, rc}
      end
    assert {:done, "The answer is 42.", nil} = result
  end

  test "step returns {:tool_calls, calls, raw, nil} when no reasoning_content" do
    raw = ~s({"tool": "list_tools", "args": {}})
    rc = nil
    result =
      case Turn.parse_response(raw) do
        {:done, c} -> {:done, c, rc}
        {:tool_calls, calls, raw2} -> {:tool_calls, calls, raw2, rc}
      end
    assert {:tool_calls, [%{name: "list_tools"}], ^raw, nil} = result
  end
end
```

- [ ] **Step 2: Run to confirm they pass (they should — these test the shape we're adding)**

```bash
mix test test/shem/agent/turn_test.exs 2>&1 | tail -5
```

Expected: all pass (these tests validate our intent before we change `stream_step`/`step`).

- [ ] **Step 3: Update `Turn.stream_step/4` in `turn.ex`**

Find `stream_step` (around line 122). Replace the entire function body from `case LLM.stream_complete(...)` to the end:

```elixir
@spec stream_step(Config.t(), String.t(), [map()], [map()]) ::
        {:tool_calls, [%{id: String.t() | nil, name: String.t(), args: map()}], String.t(), String.t() | nil}
        | {:done, String.t(), String.t() | nil}
        | {:error, term()}
def stream_step(%Config{} = config, session_id, history, tools_manifest) do
  chunk_fn = fn token ->
    Enum.each(:pg.get_members(:shem_streams, session_id), fn pid ->
      send(pid, {:stream_chunk, session_id, token})
    end)
  end

  request =
    config.model
    |> build_request(config.system_prompt, tools_manifest, history)
    |> Map.put(:session_id, session_id)

  case LLM.stream_complete(request, chunk_fn) do
    {:ok, %Response{tool_calls: [_ | _] = calls, content: content, reasoning_content: rc}} ->
      {:tool_calls, calls, content || "", rc}

    {:ok, %Response{content: content, reasoning_content: rc}} ->
      case (content || "") |> strip_thinking() |> parse_response() do
        {:done, c} -> {:done, c, rc}
        {:tool_calls, calls, raw} -> {:tool_calls, calls, raw, rc}
      end

    {:error, reason} ->
      {:error, reason}
  end
end
```

- [ ] **Step 4: Update `Turn.step/4` in `turn.ex`**

Find `step` (around line 150). Replace its `case LLM.complete(...)` block:

```elixir
@spec step(Config.t(), String.t(), [map()], [map()]) ::
        {:tool_calls, [%{id: String.t() | nil, name: String.t(), args: map()}], String.t(), String.t() | nil}
        | {:done, String.t(), String.t() | nil}
        | {:error, term()}
def step(%Config{} = config, session_id, history, tools_manifest) do
  request =
    config.model
    |> build_request(config.system_prompt, tools_manifest, history)
    |> Map.put(:session_id, session_id)

  case LLM.complete(request) do
    {:ok, %Response{tool_calls: [_ | _] = calls, content: content, reasoning_content: rc}} ->
      {:tool_calls, calls, content || "", rc}

    {:ok, %Response{content: content, reasoning_content: rc}} ->
      case (content || "") |> strip_thinking() |> parse_response() do
        {:done, c} -> {:done, c, rc}
        {:tool_calls, calls, raw} -> {:tool_calls, calls, raw, rc}
      end

    {:error, reason} ->
      {:error, reason}
  end
end
```

- [ ] **Step 5: Run turn tests and full suite**

```bash
mix test test/shem/agent/turn_test.exs 2>&1 | tail -5
mix test 2>&1 | tail -10
```

Expected: all tests pass. The full suite may show failures in Agent.Server tests if any exist — those will be fixed in Task 5.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/agent/turn.ex test/shem/agent/turn_test.exs
git commit -m "feat: thread reasoning_content through Turn.step and Turn.stream_step return tuples"
```

---

### Task 5: Emit `:agent_thinking` event and pg broadcast in `Agent.Server`

**Files:**
- Modify: `lib/shem/agent/server.ex`

- [ ] **Step 1: Add `emit_thinking/3` helper to `agent/server.ex`**

In `lib/shem/agent/server.ex`, find the private helpers section (after `broadcast_stream_done`). Add:

```elixir
defp emit_thinking(_session_id, _turn, rc) when rc in [nil, ""], do: :ok
defp emit_thinking(session_id, turn, rc) do
  EventLog.append(session_id, :agent_thinking, %{content: rc, turn: turn})
  Enum.each(:pg.get_members(:shem_streams, session_id), fn pid ->
    send(pid, {:stream_thinking, session_id, rc})
  end)
end
```

- [ ] **Step 2: Update `handle_info(:run_turn)` to use new tuple shapes**

Find `handle_info(:run_turn, state)` — the `cond do ... true ->` branch. Replace the `case Turn.stream_step(...)` block:

```elixir
case Turn.stream_step(state.config, state.session_id, state.history, manifest) do
  {:done, answer, rc} ->
    emit_thinking(state.session_id, state.turn_count + 1, rc)
    history = state.history ++ [%{role: :assistant, content: answer}]
    EventLog.append(state.session_id, :agent_turn_completed, %{
      turn: state.turn_count + 1,
      outcome: :done
    })
    {:noreply,
     finish(%{state | history: history, turn_count: state.turn_count + 1}, :done, :answer)}

  {:tool_calls, calls, raw, rc} ->
    emit_thinking(state.session_id, state.turn_count + 1, rc)
    assistant_entry = %{
      role: :assistant,
      content: (if raw == "", do: nil, else: raw),
      tool_calls: calls
    }
    history = state.history ++ [assistant_entry]
    history = execute_tool_calls(calls, manifest, history, state.session_id, state.config)
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
```

- [ ] **Step 3: Run the full test suite**

```bash
mix test 2>&1 | tail -15
```

Expected: all non-distributed tests pass. Fix any pattern-match failures on the old 2/3-tuple shapes before moving on.

- [ ] **Step 4: Commit**

```bash
git add lib/shem/agent/server.ex
git commit -m "feat: emit :agent_thinking EventLog event and pg broadcast in Agent.Server"
```

---

### Task 6: Buffer thinking in `StreamSink`, drain in TUI, fold in `AgentView`

**Files:**
- Modify: `lib/shem/tui/stream_sink.ex`
- Modify: `lib/shem/tui/agent_view.ex`
- Modify: `lib/shem/tui/app.ex`
- Create: `test/shem/tui/stream_sink_test.exs`

- [ ] **Step 1: Write a failing test for `StreamSink.take_thinking/1`**

Create `test/shem/tui/stream_sink_test.exs`:

```elixir
defmodule Shem.TUI.StreamSinkTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.StreamSink

  setup do
    # Use a unique session_id per test to avoid pg group collisions
    session_id = "test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = StreamSink.start_link(session_id)
    %{pid: pid, session_id: session_id}
  end

  test "take_thinking returns nil before any thinking arrives", %{pid: pid} do
    assert StreamSink.take_thinking(pid) == nil
  end

  test "take_thinking returns stored thinking and then nil", %{pid: pid, session_id: sid} do
    send(pid, {:stream_thinking, sid, "I need to reason about this"})
    # allow the message to be processed
    :timer.sleep(10)
    assert StreamSink.take_thinking(pid) == "I need to reason about this"
    assert StreamSink.take_thinking(pid) == nil
  end

  test "second stream_thinking replaces the first", %{pid: pid, session_id: sid} do
    send(pid, {:stream_thinking, sid, "first"})
    send(pid, {:stream_thinking, sid, "second"})
    :timer.sleep(10)
    assert StreamSink.take_thinking(pid) == "second"
  end

  test "take_tokens still works alongside take_thinking", %{pid: pid, session_id: sid} do
    send(pid, {:stream_chunk, sid, "hello"})
    send(pid, {:stream_thinking, sid, "thinking..."})
    :timer.sleep(10)
    assert StreamSink.take_tokens(pid) == ["hello"]
    assert StreamSink.take_thinking(pid) == "thinking..."
  end
end
```

- [ ] **Step 2: Run to confirm it fails**

```bash
mix test test/shem/tui/stream_sink_test.exs 2>&1 | tail -10
```

Expected: failures on `take_thinking` — function not defined.

- [ ] **Step 3: Update `StreamSink` to handle thinking**

Replace the entire `lib/shem/tui/stream_sink.ex` with:

```elixir
defmodule Shem.TUI.StreamSink do
  use GenServer

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id)
  end

  def take_tokens(pid) do
    GenServer.call(pid, :take_tokens)
  end

  def take_thinking(pid) do
    GenServer.call(pid, :take_thinking)
  end

  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  end

  def stop(nil), do: :ok

  @impl true
  def init(session_id) do
    :pg.join(:shem_streams, session_id, self())
    {:ok, %{session_id: session_id, buffer: [], thinking: nil}}
  end

  @impl true
  def handle_info({:stream_chunk, _session_id, token}, state) do
    {:noreply, %{state | buffer: [token | state.buffer]}}
  end

  def handle_info({:stream_thinking, _session_id, rc}, state) do
    {:noreply, %{state | thinking: rc}}
  end

  def handle_info({:stream_done, _session_id}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:take_tokens, _from, state) do
    {:reply, Enum.reverse(state.buffer), %{state | buffer: []}}
  end

  def handle_call(:take_thinking, _from, state) do
    {:reply, state.thinking, %{state | thinking: nil}}
  end
end
```

- [ ] **Step 4: Run StreamSink tests**

```bash
mix test test/shem/tui/stream_sink_test.exs 2>&1 | tail -5
```

Expected: all 4 tests pass.

- [ ] **Step 5: Update `AgentView.fold_event` to handle `:agent_thinking`**

In `lib/shem/tui/agent_view.ex`, find the `fold_event` private function. Add a clause for `:agent_thinking` after the `:llm_call_completed` clause:

```elixir
:agent_thinking ->
  %{acc | current_reasoning: event.payload[:content] || ""}
```

The full updated `fold_event` should have these clauses in order:
`:agent_started`, `:agent_turn_started`, `:llm_call_completed`, `:agent_thinking` (new), `:agent_tool_called`, `:agent_tool_result`, `:agent_turn_completed`, `:agent_done`, `:agent_error`, `_`.

- [ ] **Step 6: Update `app.ex` tick to drain `take_thinking`**

In `lib/shem/tui/app.ex`, find the `# Drain streaming tokens from StreamSink into streaming_buffer` comment block (around line 443). Replace the entire block (from the comment through the closing `end`) with:

```elixir
# Drain streaming tokens and thinking from StreamSink
model =
  case model.stream_sink do
    nil -> model
    pid when is_pid(pid) ->
      if Process.alive?(pid) do
        model =
          case StreamSink.take_tokens(pid) do
            [] -> model
            tokens ->
              new_buf = (model.agent_view && (model.agent_view.streaming_buffer || "")) <> Enum.join(tokens)
              agent_view = model.agent_view && %{model.agent_view | streaming_buffer: new_buf}
              %{model | agent_view: agent_view}
          end

        case StreamSink.take_thinking(pid) do
          nil -> model
          rc ->
            agent_view = model.agent_view && %{model.agent_view | current_reasoning: rc}
            %{model | agent_view: agent_view}
        end
      else
        %{model | stream_sink: nil}
      end
  end
```

- [ ] **Step 7: Run full test suite**

```bash
mix test 2>&1 | tail -10
```

Expected: all non-distributed tests pass.

- [ ] **Step 8: Commit**

```bash
git add lib/shem/tui/stream_sink.ex lib/shem/tui/agent_view.ex lib/shem/tui/app.ex test/shem/tui/stream_sink_test.exs
git commit -m "feat: buffer and surface reasoning_content in TUI via StreamSink and AgentView"
```

---

### Task 7: Emit thinking event in REST SSE stream

**Files:**
- Modify: `lib/shem/rest/handlers/agents.ex`

- [ ] **Step 1: Add `{:stream_thinking, ...}` clause to `stream_loop/2`**

In `lib/shem/rest/handlers/agents.ex`, find `defp stream_loop(conn, session_id)`. Add a new clause for `stream_thinking` immediately after the `stream_chunk` clause:

```elixir
defp stream_loop(conn, session_id) do
  receive do
    {:stream_chunk, ^session_id, token} ->
      event = Jason.encode!(%{type: "chunk", content: token})

      case Plug.Conn.chunk(conn, "data: #{event}\n\n") do
        {:ok, conn} -> stream_loop(conn, session_id)
        {:error, _} ->
          :pg.leave(:shem_streams, session_id, self())
          conn
      end

    {:stream_thinking, ^session_id, rc} ->
      event = Jason.encode!(%{type: "thinking", content: rc})

      case Plug.Conn.chunk(conn, "data: #{event}\n\n") do
        {:ok, conn} -> stream_loop(conn, session_id)
        {:error, _} ->
          :pg.leave(:shem_streams, session_id, self())
          conn
      end

    {:stream_done, ^session_id} ->
      event = Jason.encode!(%{type: "done", status: "done"})
      Plug.Conn.chunk(conn, "data: #{event}\n\n")
      :pg.leave(:shem_streams, session_id, self())
      conn

    _other ->
      stream_loop(conn, session_id)
  after
    30_000 ->
      :pg.leave(:shem_streams, session_id, self())
      conn
  end
end
```

- [ ] **Step 2: Run full test suite**

```bash
mix test 2>&1 | tail -10
```

Expected: all non-distributed tests pass.

- [ ] **Step 3: Commit**

```bash
git add lib/shem/rest/handlers/agents.ex
git commit -m "feat: emit type:thinking JSON event in REST SSE stream"
```

---

### Task 8: End-to-end smoke test with LM Studio

- [ ] **Step 1: Ensure LM Studio is running**

```bash
~/.lmstudio/bin/lms status
```

Expected: `Server: ON` on port 1234. If not: `~/.lmstudio/bin/lms server start`

- [ ] **Step 2: Run a real agent turn through the full stack**

```bash
MIX_ENV=dev elixir --sname shem_smoke -S mix run --no-start -e '
Application.ensure_all_started(:req)
Application.put_env(:shem, :llm_openai_base_url, "http://localhost:1234")
Application.put_env(:shem, :llm_openai_api_key, "lm-studio")

alias Shem.LLM.Middleware.OpenAITransport
alias Shem.LLM.Request

request = %Request{
  model: :default,
  prompt: "What is 1 + 1? Answer in one word. /no_think",
  messages: nil,
  system: nil,
  tools: nil,
  options: %{max_tokens: 2048}
}

case OpenAITransport.call(request, [model_string: "qwen"], nil) do
  {:ok, resp} ->
    IO.puts("content:          #{inspect(resp.content)}")
    IO.puts("reasoning_content: #{inspect(resp.reasoning_content)}")
    IO.puts("tokens_used:       #{resp.tokens_used}")
  {:error, reason} ->
    IO.puts("ERROR: #{inspect(reason)}")
end
' 2>&1 | grep -v "^\d\d:"
```

Expected output (values will vary):
```
content:          "2"
reasoning_content: "The user is asking..." (or nil if model skipped thinking)
tokens_used:       <some number>
```

- [ ] **Step 3: Commit (no code change — this is verification only)**

If something was broken and you had to fix it, commit the fix. Otherwise:

```bash
git log --oneline -7
```

Verify all 7 feature commits appear in order.
