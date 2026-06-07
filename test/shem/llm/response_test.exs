defmodule Shem.LLM.ResponseTest do
  use ExUnit.Case, async: true
  alias Shem.LLM.Response

  test "has expected fields" do
    r = %Response{content: "hello", tokens_used: 42, model: :llama3, latency_ms: 100}
    assert r.content == "hello"
    assert r.tokens_used == 42
    assert r.model == :llama3
    assert r.latency_ms == 100
  end

  test "tool_calls defaults to nil" do
    r = %Response{tokens_used: 10, model: :default, latency_ms: 100}
    assert is_nil(r.tool_calls)
  end

  test "content can be nil" do
    r = %Response{tokens_used: 10, model: :default, latency_ms: 100}
    assert is_nil(r.content)
  end

  test "accepts tool_calls list" do
    calls = [%{id: "call_1", name: "run_code", args: %{"source" => "42"}}]
    r = %Response{tokens_used: 10, model: :default, latency_ms: 100, tool_calls: calls}
    assert r.tool_calls == calls
  end
end
