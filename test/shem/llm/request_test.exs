defmodule Shem.LLM.RequestTest do
  use ExUnit.Case, async: true
  alias Shem.LLM.Request

  test "has expected fields with defaults" do
    r = %Request{prompt: "hello", model: :default}
    assert r.prompt == "hello"
    assert r.model == :default
    assert r.options == %{}
    assert r.session_id == nil
  end

  test "accepts all fields" do
    r = %Request{prompt: "hi", model: :llama3, options: %{temperature: 0.7}, session_id: "ses_abc"}
    assert r.session_id == "ses_abc"
    assert r.options == %{temperature: 0.7}
  end

  test "tools defaults to nil" do
    r = %Request{prompt: "hello", model: :default}
    assert is_nil(r.tools)
  end

  test "accepts tool schemas in tools field" do
    tools = [
      %{name: "run_code", description: "Run code.",
        schema: %{type: "object", properties: %{"source" => %{"type" => "string"}}, required: ["source"]}}
    ]
    r = %Request{prompt: "hello", model: :default, tools: tools}
    assert r.tools == tools
  end
end
