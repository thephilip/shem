defmodule Shem.Agent.ConversationalTest do
  use ExUnit.Case, async: false

  alias Shem.Agent
  alias Shem.Agent.Config
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

  defp stub(content, tokens \\ 5) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: tokens, model: :default, latency_ms: 1}}
    )
  end

  defp start_conversational_agent(task, opts \\ []) do
    system_prompt = Keyword.get(opts, :system_prompt, "be helpful")
    max_turns = Keyword.get(opts, :max_turns, 10)

    config = %Config{
      task: task,
      system_prompt: system_prompt,
      max_turns: max_turns,
      conversational: true
    }

    {:ok, name} = Agent.start(config)
    name
  end

  defp start_task_agent(task, opts \\ []) do
    system_prompt = Keyword.get(opts, :system_prompt, "be helpful")
    max_turns = Keyword.get(opts, :max_turns, 10)

    config = %Config{
      task: task,
      system_prompt: system_prompt,
      max_turns: max_turns,
      conversational: false
    }

    {:ok, name} = Agent.start(config)
    name
  end

  describe "conversational mode" do
    test "agent in conversational mode reaches :waiting after first turn" do
      stub("Hello! How can I help?")

      name = start_conversational_agent("hello")
      assert {:ok, :waiting} = Agent.await(name, 2_000)
      assert {:ok, :waiting} = Agent.status(name)
    end

    test "send_message/2 resumes a waiting agent" do
      stub("Hello! How can I help?")
      stub("Sure, anything else?")

      name = start_conversational_agent("hello")
      assert {:ok, :waiting} = Agent.await(name, 2_000)

      assert :ok = Agent.send_message(name, "Tell me more")
      assert {:ok, :waiting} = Agent.await(name, 2_000)
    end

    test "send_message/2 returns error when agent is not waiting" do
      stub("The answer is done.")

      name = start_task_agent("do something")
      assert {:ok, :done} = Agent.await(name, 2_000)

      assert {:error, :not_waiting} = Agent.send_message(name, "More please")
    end

    test "non-conversational agent still reaches :done" do
      stub("The final answer.")

      name = start_task_agent("compute something")
      assert {:ok, :done} = Agent.await(name, 2_000)
      assert {:ok, :done} = Agent.status(name)
    end

    test "send_message/2 returns {:error, :not_found} for unknown agent" do
      assert {:error, :not_found} = Agent.send_message("no_such_agent_xyz", "hello")
    end

    test "history accumulates across multiple turns" do
      stub("Hello! How can I help?")
      stub("Sure, anything else?")

      name = start_conversational_agent("hello")
      assert {:ok, :waiting} = Agent.await(name, 2_000)

      assert :ok = Agent.send_message(name, "Tell me more")
      assert {:ok, :waiting} = Agent.await(name, 2_000)

      # Verify the session log has the user_message event
      {:ok, sid} = Agent.session_id(name)
      {:ok, events} = Shem.EventLog.events(sid)
      types = Enum.map(events, & &1.type)
      assert :agent_waiting in types
      assert :user_message in types
    end
  end
end
