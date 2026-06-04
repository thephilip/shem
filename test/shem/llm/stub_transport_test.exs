defmodule Shem.LLM.StubTransportTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.{Request, Response, StubTransport}
  alias Shem.LLM.StubTransport.Server

  defp start_stub do
    name = :"stub_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Server, name: name})
    name
  end

  defp request do
    %Request{prompt: "hello", model: :default}
  end

  defp ok_response(content \\ "stub response") do
    {:ok, %Response{content: content, tokens_used: 10, model: :default, latency_ms: 1}}
  end

  describe "response queue" do
    test "returns queued response in order" do
      stub = start_stub()
      Server.push_response(stub, ok_response("first"))
      Server.push_response(stub, ok_response("second"))

      assert {:ok, %{content: "first"}} = StubTransport.call(request(), [server: stub], fn _ -> :unreachable end)
      assert {:ok, %{content: "second"}} = StubTransport.call(request(), [server: stub], fn _ -> :unreachable end)
    end

    test "returns default response when queue is empty" do
      stub = start_stub()
      default = ok_response("default")
      Server.set_default(stub, default)

      assert {:ok, %{content: "default"}} = StubTransport.call(request(), [server: stub], fn _ -> :unreachable end)
    end

    test "returns {:error, :no_stub_response} when queue empty and no default" do
      stub = start_stub()
      assert {:error, :no_stub_response} = StubTransport.call(request(), [server: stub], fn _ -> :unreachable end)
    end

    test "can enqueue error responses" do
      stub = start_stub()
      Server.push_response(stub, {:error, {:transport, :econnrefused}})

      assert {:error, {:transport, :econnrefused}} = StubTransport.call(request(), [server: stub], fn _ -> :unreachable end)
    end
  end

  describe "call recording" do
    test "records all received requests" do
      stub = start_stub()
      Server.push_response(stub, ok_response())
      Server.push_response(stub, ok_response())

      req1 = %Request{prompt: "first", model: :default}
      req2 = %Request{prompt: "second", model: :llama3}

      StubTransport.call(req1, [server: stub], fn _ -> :unreachable end)
      StubTransport.call(req2, [server: stub], fn _ -> :unreachable end)

      calls = Server.calls(stub)
      assert length(calls) == 2
      assert Enum.at(calls, 0).prompt == "first"
      assert Enum.at(calls, 1).prompt == "second"
    end

    test "calls/1 returns empty list initially" do
      stub = start_stub()
      assert [] = Server.calls(stub)
    end
  end
end
