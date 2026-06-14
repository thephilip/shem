defmodule Shem.LLMTest do
  use ExUnit.Case, async: false

  alias Shem.LLM
  alias Shem.LLM.{Request, Response}
  alias Shem.LLM.StubTransport.Server, as: StubServer

  # Tests use the globally-started StubTransport.Server and BudgetServer.
  # async: false to avoid cross-test state contamination.

  defp stub_response(content \\ "stub", tokens \\ 5) do
    {:ok, %Response{content: content, tokens_used: tokens, model: :default, latency_ms: 1}}
  end

  setup do
    Shem.LLM.BudgetServer.reset()
    Shem.LLM.StubTransport.Server.reset()
    :ok
  end

  describe "complete/1" do
    test "returns {:ok, %Response{}} on success" do
      StubServer.push_response(stub_response("hello", 10))

      request = %Request{prompt: "hi", model: :default}
      assert {:ok, %Response{content: "hello"}} = LLM.complete(request)
    end

    test "event log receives entries when session_id is set" do
      {:ok, sid} = Shem.EventLog.start_session()
      StubServer.push_response(stub_response())

      request = %Request{prompt: "hi", model: :default, session_id: sid}
      assert {:ok, _} = LLM.complete(request)

      {:ok, events} = Shem.EventLog.events(sid)
      types = Enum.map(events, & &1.type)
      assert :llm_call_started in types
      assert :llm_call_completed in types
    end

    test "propagates {:error, reason} from pipeline" do
      StubServer.push_response({:error, :transport_down})

      request = %Request{prompt: "hi", model: :default}
      assert {:error, :transport_down} = LLM.complete(request)
    end

    test "deducts tokens from BudgetServer after successful call" do
      before = Shem.LLM.BudgetServer.status().tokens_used
      StubServer.push_response(stub_response("ok", 25))

      LLM.complete(%Request{prompt: "x", model: :default})
      after_ = Shem.LLM.BudgetServer.status().tokens_used

      assert after_ - before == 25
    end
  end

  describe "stream/2" do
    test "calls callback with response content and returns {:ok, response}" do
      StubServer.push_response(stub_response("streamed", 3))

      chunks = Agent.start_link(fn -> [] end) |> elem(1)
      request = %Request{prompt: "hi", model: :default}

      assert {:ok, %Response{}} =
               LLM.stream(request, fn chunk -> Agent.update(chunks, &[chunk | &1]) end)

      assert Agent.get(chunks, &Enum.reverse/1) == ["streamed"]
    end

    test "propagates {:error, reason} when pipeline fails" do
      StubServer.push_response({:error, :transport_down})

      request = %Request{prompt: "hi", model: :default}
      assert {:error, :transport_down} = LLM.stream(request, fn _chunk -> :ok end)
    end
  end

  describe "stream_complete/2" do
    setup do
      Shem.LLM.BudgetServer.reset()
      Shem.LLM.StubTransport.Server.reset()
      :ok
    end

    test "calls chunk_fn with response content and returns {:ok, response}" do
      Shem.LLM.StubTransport.Server.push_response(
        {:ok, %Shem.LLM.Response{content: "hello world", tool_calls: nil, tokens_used: 5, model: :default, latency_ms: 1}}
      )

      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn token -> Agent.update(collector, &[token | &1]) end

      request = %Shem.LLM.Request{prompt: "test", model: :default}
      assert {:ok, %Shem.LLM.Response{content: "hello world"}} = Shem.LLM.stream_complete(request, chunk_fn)

      chunks = Agent.get(collector, & &1) |> Enum.reverse()
      assert chunks != []
      assert Enum.join(chunks) =~ "hello"
    end

    test "returns {:error, :budget_exhausted} without calling chunk_fn when budget is depleted" do
      Shem.LLM.BudgetServer.deduct(100_001)

      called = :atomics.new(1, signed: false)
      chunk_fn = fn _token -> :atomics.add(called, 1, 1) end

      request = %Shem.LLM.Request{prompt: "test", model: :default}
      assert {:error, :budget_exhausted} = Shem.LLM.stream_complete(request, chunk_fn)
      assert :atomics.get(called, 1) == 0
    end
  end

  describe ":pg :shem_streams" do
    test "allows multiple subscribers on the same session_id" do
      session_id = "test_stream_#{System.unique_integer()}"

      # Join from the test process
      :ok = :pg.join(:shem_streams, session_id, self())

      # Join from a second process
      test_pid = self()
      task = Task.async(fn ->
        :ok = :pg.join(:shem_streams, session_id, self())
        send(test_pid, {:joined, self()})
        Process.sleep(200)
      end)

      assert_receive {:joined, task_pid}, 500

      members = :pg.get_members(:shem_streams, session_id)
      assert self() in members
      assert task_pid in members

      Task.shutdown(task, :brutal_kill)
    end
  end
end
