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
end
