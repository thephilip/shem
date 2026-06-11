defmodule Shem.AgentTest do
  use ExUnit.Case, async: false

  alias Shem.LLM.{Response, StubTransport}

  setup do
    Shem.LLM.BudgetServer.reset()
    StubTransport.Server.reset()
    lab_dir = Application.get_env(:shem, :lab_dir)

    on_exit(fn ->
      File.rm_rf!(lab_dir)
      Shem.Lab.Registry.flush()
    end)

    :ok
  end

  defp stub(content) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: 5, model: :default, latency_ms: 1}}
    )
  end

  describe "Config — project_context and conversational fields" do
    test "Config has project_context field defaulting to nil" do
      config = %Shem.Agent.Config{task: "test", system_prompt: "sp"}
      assert config.project_context == nil
    end

    test "Config has conversational field defaulting to false" do
      config = %Shem.Agent.Config{task: "test", system_prompt: "sp"}
      assert config.conversational == false
    end
  end

  describe "Config" do
    test "fence defaults to nil" do
      config = %Shem.Agent.Config{task: "t", system_prompt: "s"}
      assert config.fence == nil
    end

    test "fence can be set to an absolute path" do
      config = %Shem.Agent.Config{task: "t", system_prompt: "s", fence: "/home/user/proj"}
      assert config.fence == "/home/user/proj"
    end
  end

  describe "resume/2" do
    setup do
      StubTransport.Server.reset()
      :ok
    end

    test "returns {:ok, name} for a valid session_id and task" do
      sid = "ses_RESUME_#{System.unique_integer([:positive])}"
      {:ok, ^sid} = Shem.EventLog.start_session(sid)

      Shem.EventLog.append(sid, :agent_started, %{
        task: "original task",
        model: :default,
        max_turns: 20
      })

      Shem.EventLog.end_session(sid)

      stub("resumed answer")

      assert {:ok, name, _} = Shem.Agent.resume(sid, "original task")
      assert is_binary(name)
      assert String.starts_with?(name, "agent_")

      Shem.Agent.stop(name)
    end

    test "started agent is queryable via status/1" do
      sid = "ses_RESUME_STATUS_#{System.unique_integer([:positive])}"
      {:ok, ^sid} = Shem.EventLog.start_session(sid)

      Shem.EventLog.append(sid, :agent_started, %{
        task: "status task",
        model: :default,
        max_turns: 20
      })

      Shem.EventLog.end_session(sid)

      stub("done")

      {:ok, name, _} = Shem.Agent.resume(sid, "status task")
      assert {:ok, _status} = Shem.Agent.status(name)

      Shem.Agent.stop(name)
    end
  end
end
