defmodule Shem.Agent.ReplayConfigTest do
  use ExUnit.Case, async: false

  alias Shem.Agent
  alias Shem.Agent.Config
  alias Shem.LLM.Response

  setup do
    Shem.LLM.BudgetServer.reset()
    Shem.LLM.StubTransport.Server.reset()
    :ok
  end

  test "config.pipeline overrides the app LLM pipeline for the agent's calls" do
    canned = %Response{content: "canned final answer", tokens_used: 0, model: :default, latency_ms: 0}

    {:ok, name, sid} =
      Agent.start(%Config{
        task: "pipeline test",
        system_prompt: "s",
        pipeline: [
          {Shem.LLM.Middleware.EventLogger, []},
          {Shem.LLM.Middleware.OneShot, response: canned}
        ]
      })

    assert {:ok, :done} = Agent.await(name, 10_000)

    {:ok, events} = Shem.EventLog.events(sid)
    completed = Enum.find(events, &(&1.type == :llm_call_completed))
    assert completed.payload[:content] == "canned final answer"
  end

  test "agent_started records preset and project_context" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )

    {:ok, name, sid} = Agent.start_with_preset("general", "record fields test")
    assert {:ok, :done} = Agent.await(name, 10_000)

    {:ok, events} = Shem.EventLog.events(sid)
    started = Enum.find(events, &(&1.type == :agent_started))
    assert started.payload[:preset] == "general"
    assert is_map(started.payload[:project_context])
    assert is_binary(started.payload[:project_context][:path])
  end

  test "raw Config start records nil preset" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )

    {:ok, name, sid} = Agent.start(%Config{task: "raw", system_prompt: "s"})
    assert {:ok, :done} = Agent.await(name, 10_000)

    {:ok, events} = Shem.EventLog.events(sid)
    started = Enum.find(events, &(&1.type == :agent_started))
    assert started.payload[:preset] == nil
  end
end
