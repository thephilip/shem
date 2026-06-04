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
    unless Process.whereis(Shem.LLM.BudgetServer) do
      start_supervised!(Shem.LLM.BudgetServer)
    end

    unless Process.whereis(Shem.LLM.StubTransport.Server) do
      start_supervised!({Shem.LLM.StubTransport.Server, name: Shem.LLM.StubTransport.Server})
    end

    Shem.LLM.BudgetServer.reset()
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
  end
end
