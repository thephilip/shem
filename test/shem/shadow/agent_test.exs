defmodule Shem.Shadow.AgentTest do
  use ExUnit.Case, async: false

  alias Shem.Shadow.Agent, as: ShadowAgent
  alias Shem.{EventLog, LLM}

  setup do
    Shem.LLM.StubTransport.Server.reset()
    Application.put_env(:shem, :shadow_agent_poll_ms, 50)

    on_exit(fn ->
      Application.put_env(:shem, :shadow_agent_poll_ms, 2_000)
    end)

    :ok
  end

  defp unique_name, do: "shadow_test_agent_#{System.unique_integer([:positive])}"
  defp unique_session, do: "shadow_test_ses_#{System.unique_integer([:positive])}"

  defp start_shadow(agent_name, session_id) do
    fake_agent = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, pid} = ShadowAgent.start_link({agent_name, session_id, fake_agent})
    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if Process.alive?(fake_agent), do: Process.exit(fake_agent, :kill)
    end)
    {pid, fake_agent}
  end

  test "current_score/1 returns :high with optimistic defaults before first analysis" do
    agent_name = unique_name()
    session_id = unique_session()
    EventLog.start_session(session_id)
    EventLog.append(session_id, :agent_started, %{task: "test", model: :default, max_turns: 5})
    {_pid, _fake} = start_shadow(agent_name, session_id)

    Process.sleep(20)

    assert {:ok, %{band: :high, score: 1.0, reasoning: "No analysis yet."}} =
             ShadowAgent.current_score(agent_name)
  end

  test "current_score/1 returns :not_found for unknown agent" do
    assert {:error, :not_found} = ShadowAgent.current_score("no_such_agent_ever")
  end

  test "score updates after LLM returns valid JSON" do
    agent_name = unique_name()
    session_id = unique_session()

    EventLog.start_session(session_id)
    EventLog.append(session_id, :agent_started, %{task: "test task", model: :default, max_turns: 5})
    EventLog.append(session_id, :agent_checkpoint, %{
      history: [%{role: :user, content: "test task"}],
      turn_count: 0,
      config: %{}
    })
    EventLog.append(session_id, :agent_turn_completed, %{turn: 1, outcome: :done})

    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %LLM.Response{
        content: ~s({"score": 0.9, "reasoning": "Session looks safe."}),
        tokens_used: 10,
        model: :shadow,
        latency_ms: 1
      }}
    )

    {_pid, _fake} = start_shadow(agent_name, session_id)
    Process.sleep(300)

    assert {:ok, %{band: :high, score: 0.9, reasoning: "Session looks safe."}} =
             ShadowAgent.current_score(agent_name)
  end

  test "score bands: 0.5 maps to :medium" do
    agent_name = unique_name()
    session_id = unique_session()
    EventLog.start_session(session_id)
    EventLog.append(session_id, :agent_checkpoint, %{
      history: [%{role: :user, content: "task"}], turn_count: 0, config: %{}
    })
    EventLog.append(session_id, :agent_turn_completed, %{turn: 1, outcome: :done})

    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %LLM.Response{
        content: ~s({"score": 0.5, "reasoning": "Minor concern."}),
        tokens_used: 10,
        model: :shadow,
        latency_ms: 1
      }}
    )

    {_pid, _fake} = start_shadow(agent_name, session_id)
    Process.sleep(300)

    assert {:ok, %{band: :medium}} = ShadowAgent.current_score(agent_name)
  end

  test "score bands: 0.3 maps to :low" do
    agent_name = unique_name()
    session_id = unique_session()
    EventLog.start_session(session_id)
    EventLog.append(session_id, :agent_checkpoint, %{
      history: [%{role: :user, content: "task"}], turn_count: 0, config: %{}
    })
    EventLog.append(session_id, :agent_turn_completed, %{turn: 1, outcome: :done})

    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %LLM.Response{
        content: ~s({"score": 0.3, "reasoning": "Concerning behaviour."}),
        tokens_used: 10,
        model: :shadow,
        latency_ms: 1
      }}
    )

    {_pid, _fake} = start_shadow(agent_name, session_id)
    Process.sleep(300)

    assert {:ok, %{band: :low}} = ShadowAgent.current_score(agent_name)
  end

  test "score is unchanged when LLM returns unparseable content" do
    agent_name = unique_name()
    session_id = unique_session()
    EventLog.start_session(session_id)
    EventLog.append(session_id, :agent_checkpoint, %{
      history: [%{role: :user, content: "task"}], turn_count: 0, config: %{}
    })
    EventLog.append(session_id, :agent_turn_completed, %{turn: 1, outcome: :done})

    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %LLM.Response{
        content: "not json at all",
        tokens_used: 5,
        model: :shadow,
        latency_ms: 1
      }}
    )

    {_pid, _fake} = start_shadow(agent_name, session_id)
    Process.sleep(300)

    assert {:ok, %{band: :high, score: 1.0}} = ShadowAgent.current_score(agent_name)
  end

  test "Shadow.Agent stops cleanly when monitored agent exits" do
    agent_name = unique_name()
    session_id = unique_session()
    EventLog.start_session(session_id)
    EventLog.append(session_id, :agent_started, %{task: "test", model: :default, max_turns: 5})
    {pid, fake_agent} = start_shadow(agent_name, session_id)

    Process.exit(fake_agent, :kill)
    Process.sleep(100)

    refute Process.alive?(pid)
  end
end
