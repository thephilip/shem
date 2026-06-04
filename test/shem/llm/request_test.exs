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
end
