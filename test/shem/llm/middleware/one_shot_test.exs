defmodule Shem.LLM.Middleware.OneShotTest do
  use ExUnit.Case, async: true
  alias Shem.LLM.{Request, Response}
  alias Shem.LLM.Middleware.OneShot

  test "returns the seeded response and records via EventLogger above it" do
    {:ok, sid} = Shem.EventLog.start_session()
    resp = %Response{content: ~s({"tool":"echo","args":{"x":1}}), model: :test, tokens_used: 0, latency_ms: 0}

    pipeline = [{Shem.LLM.Middleware.EventLogger, []}, {OneShot, response: resp}]
    Process.put(:shem_replay_pipeline, pipeline)
    on_exit(fn -> Process.delete(:shem_replay_pipeline) end)

    req = %Request{prompt: "p", model: :test, session_id: sid}
    assert {:ok, %Response{content: content}} = Shem.LLM.complete(req)
    assert content =~ ~s("tool":"echo")

    {:ok, events} = Shem.EventLog.events(sid)
    assert Enum.any?(events, &(&1.type == :llm_call_completed and &1.payload.content =~ "echo"))
  end
end
