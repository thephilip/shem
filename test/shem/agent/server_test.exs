defmodule Shem.Agent.ServerTest do
  use ExUnit.Case, async: false

  alias Shem.Agent
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

  defp start_agent(task, opts \\ []) do
    system_prompt = Keyword.get(opts, :system_prompt, "be helpful")
    max_turns = Keyword.get(opts, :max_turns, 10)
    config = %Agent.Config{task: task, system_prompt: system_prompt, max_turns: max_turns}
    {:ok, name} = Agent.start(config)
    name
  end

  describe "Config" do
    test "struct has required fields with defaults" do
      config = %Agent.Config{task: "do something", system_prompt: "you are helpful"}
      assert config.task == "do something"
      assert config.model == :default
      assert config.tools == []
      assert config.max_turns == 20
    end
  end

  describe "single-turn run (no tool calls)" do
    test "agent reaches :done status after plain-text response" do
      stub("The answer is 42.")
      name = start_agent("what is 6 * 7?")
      assert {:ok, :done} = Agent.await(name, 2_000)
      assert {:ok, :done} = Agent.status(name)
    end

    test "EventLog session contains :agent_started, :agent_turn_started, :agent_turn_completed, :agent_done" do
      {:ok, sessions_before} = Shem.EventLog.list_sessions()
      before_ids = MapSet.new(Enum.map(sessions_before, & &1.id))

      stub("done")
      name = start_agent("task")
      Agent.await(name, 2_000)

      {:ok, sessions_after} = Shem.EventLog.list_sessions()
      session = Enum.find(sessions_after, fn s -> s.id not in before_ids end)
      assert session != nil

      {:ok, events} = Shem.EventLog.events(session.id)
      types = Enum.map(events, & &1.type)
      assert :agent_started in types
      assert :agent_turn_started in types
      assert :agent_turn_completed in types
      assert :agent_done in types
    end

    test ":agent_done event contains content when agent finishes with plain text" do
      stub("The final answer.")
      name = start_agent("what is the answer?")
      Agent.await(name, 2_000)

      {:ok, session_id} = Agent.session_id(name)
      {:ok, events} = Shem.EventLog.events(session_id)
      done_event = Enum.find(events, &(&1.type == :agent_done))
      assert done_event != nil
      assert Map.get(done_event.payload, :content) == "The final answer."
    end

    test "Agent.session_id/1 returns {:ok, binary} for a running agent" do
      stub("done")
      name = start_agent("task")
      assert {:ok, sid} = Agent.session_id(name)
      assert is_binary(sid)
    end

    test "Agent.session_id/1 returns {:error, :not_found} for unknown agent" do
      assert {:error, :not_found} = Agent.session_id("no_such_agent_xyz")
    end
  end

  describe "two-turn run: tool call then done" do
    test "agent calls write_tool, then completes" do
      source = """
      defmodule AgentWritten1 do
        def run(_args), do: :written
      end
      """
      test_src = """
      defmodule AgentWritten1Test do
        def run, do: :ok
      end
      """
      tool_call_response =
        ~s(I'll write a tool.\n{"tool": "write_tool", "args": {"source": #{Jason.encode!(source)}, "test_source": #{Jason.encode!(test_src)}}})

      stub(tool_call_response)
      stub("Task complete.")

      name = start_agent("write and graduate a tool")
      assert {:ok, :done} = Agent.await(name, 3_000)
      assert {:ok, _} = Shem.Lab.Registry.lookup("agent_written1")
    end
  end

  describe "self-correction loop" do
    test "agent retries write_tool after compile error, eventually graduates" do
      bad_source = "this is not valid elixir !!!"
      good_source = """
      defmodule AgentSelfCorrect1 do
        def run(_args), do: :corrected
      end
      """
      test_src = """
      defmodule AgentSelfCorrect1Test do
        def run, do: :ok
      end
      """

      stub(~s({"tool": "write_tool", "args": {"source": #{Jason.encode!(bad_source)}, "test_source": ""}}))
      stub(~s({"tool": "write_tool", "args": {"source": #{Jason.encode!(good_source)}, "test_source": #{Jason.encode!(test_src)}}}))
      stub("Done, tool graduated.")

      name = start_agent("write a tool, handle errors")
      assert {:ok, :done} = Agent.await(name, 3_000)
      assert {:ok, _} = Shem.Lab.Registry.lookup("agent_self_correct1")
    end
  end

  describe "circuit breakers" do
    test "agent stops with :done after max_turns" do
      for _ <- 1..5, do: stub(~s({"tool": "list_tools", "args": {}}))

      name = start_agent("loop forever", max_turns: 2)
      assert {:ok, :done} = Agent.await(name, 2_000)
      assert {:ok, :done} = Agent.status(name)
    end

    test "agent stops with :done when budget is exhausted" do
      Shem.LLM.BudgetServer.deduct(100_001)
      name = start_agent("some task")
      assert {:ok, :done} = Agent.await(name, 2_000)
    end

    test "agent reaches :error status when LLM transport returns error" do
      StubTransport.Server.push_response({:error, :transport_down})
      name = start_agent("failing task")
      assert {:ok, :error} = Agent.await(name, 2_000)
    end
  end

  describe "Shem.Agent public API" do
    test "stop/1 terminates the agent process" do
      stub("done")
      name = start_agent("task")
      Agent.await(name, 2_000)
      assert :ok = Agent.stop(name)
      assert {:error, :not_found} = Agent.status(name)
    end

    test "status/1 returns {:error, :not_found} for unknown name" do
      assert {:error, :not_found} = Agent.status("nonexistent_agent")
    end

    test "await/2 returns immediately if agent is already done" do
      stub("done")
      name = start_agent("task")
      Agent.await(name, 2_000)
      assert {:ok, :done} = Agent.await(name, 100)
    end
  end

  describe "checkpoint and resume" do
    test "a checkpoint is written before each turn" do
      {:ok, sessions_before} = Shem.EventLog.list_sessions()
      before_ids = MapSet.new(Enum.map(sessions_before, & &1.id))

      stub("done")
      name = start_agent("task")
      Agent.await(name, 2_000)

      {:ok, sessions_after} = Shem.EventLog.list_sessions()
      session = Enum.find(sessions_after, fn s -> s.id not in before_ids end)
      assert session != nil

      session_id = GenServer.call(Shem.ProcessRegistry.via_tuple(name), :session_id)
      {:ok, events} = Shem.EventLog.events(session_id)
      checkpoint_events = Enum.filter(events, &(&1.type == :agent_checkpoint))
      assert length(checkpoint_events) >= 1
    end

    test "agent resumes from checkpoint when session already has a checkpoint" do
      # Open a session manually, save a checkpoint, then start an agent with that session_id
      session_id = "ses_RESUME_TEST_" <> Base.encode16(:crypto.strong_rand_bytes(4))
      {:ok, ^session_id} = Shem.EventLog.start_session(session_id)

      prior_history = [
        %{role: :user, content: "resume task"},
        %{role: :assistant, content: "I'll help"},
        %{role: :tool, content: "Tool result (list_tools): []"}
      ]
      config = %Agent.Config{task: "resume task", system_prompt: "helpful", max_turns: 10}

      Shem.Agent.Checkpoint.save(session_id, %{
        history: prior_history,
        turn_count: 3,
        config: config
      })

      # Start Agent.Server directly with the pre-seeded session_id
      name = "resume_agent_#{System.unique_integer([:positive])}"
      stub("Final answer after resume.")
      via = Shem.ProcessRegistry.via_tuple(name)
      child_spec = %{
        id: name,
        start: {Shem.Agent.Server, :start_link, [{name, config, session_id, [name: via]}]},
        restart: :temporary
      }
      {:ok, _pid} = Horde.DynamicSupervisor.start_child(Shem.AgentSupervisor, child_spec)
      assert {:ok, :done} = Agent.await(name, 2_000)

      # Verify :agent_resumed was appended
      {:ok, events} = Shem.EventLog.events(session_id)
      assert Enum.any?(events, &(&1.type == :agent_resumed))
    end
  end

  describe "native tool_calls path" do
    test "history has structured assistant entry and tool_call_id after native tool call" do
      # Push a native tool-calls response (no text content)
      tool_resp = {:ok, %Shem.LLM.Response{
        content: nil,
        tool_calls: [%{id: "call_1", name: "list_tools", args: %{}}],
        tokens_used: 5,
        model: :default,
        latency_ms: 1
      }}
      StubTransport.Server.push_response(tool_resp)
      stub("All tools listed.")

      name = start_agent("list the tools")
      assert {:ok, :done} = Agent.await(name, 2_000)

      {:ok, session_id} = Agent.session_id(name)

      # The checkpoint saved at the start of turn 2 contains the post-turn-1 history
      {:ok, checkpoint} = Shem.Agent.Checkpoint.reconstruct(session_id)
      history = checkpoint.history

      # Find the assistant entry that has tool_calls
      asst_entry = Enum.find(history, fn e -> e.role == :assistant and Map.get(e, :tool_calls) end)
      assert asst_entry != nil
      assert asst_entry.content == nil
      assert [%{id: "call_1", name: "list_tools"}] = asst_entry.tool_calls

      # Find the tool result entry
      tool_entry = Enum.find(history, fn e -> e.role == :tool end)
      assert tool_entry != nil
      assert tool_entry.tool_call_id == "call_1"
      assert String.contains?(tool_entry.content, "list_tools")
    end
  end

  describe "streaming" do
    test "broadcasts {:stream_chunk, session_id, token} during a turn" do
      stub("Streaming answer here.")
      session_id = "ses_stream_chunk_" <> Base.encode16(:crypto.strong_rand_bytes(4))
      Registry.register(Shem.StreamRegistry, session_id, nil)
      name = start_agent_with_session("streaming test", session_id)

      assert {:ok, :done} = Agent.await(name, 2_000)

      # Drain all stream_chunk messages
      chunks = collect_stream_chunks(session_id)
      assert chunks != []
      assert Enum.join(chunks) =~ "Streaming"
    end

    test "broadcasts {:stream_done, session_id} when agent finishes" do
      stub("done")
      session_id = "ses_stream_done_" <> Base.encode16(:crypto.strong_rand_bytes(4))
      Registry.register(Shem.StreamRegistry, session_id, nil)
      name = start_agent_with_session("stream done test", session_id)

      assert {:ok, :done} = Agent.await(name, 2_000)

      assert_receive {:stream_done, ^session_id}, 500
    end
  end

  describe "start_with_preset/2" do
    test "starts an agent using a named preset" do
      stub("done")
      assert {:ok, name} = Agent.start_with_preset("general", "say hello")
      assert is_binary(name)
      assert {:ok, _status} = Agent.await(name, 2_000)
    end

    test "returns error for unknown preset" do
      assert {:error, :not_found} = Agent.start_with_preset("no_such_preset", "task")
    end
  end

  defp start_agent_with_session(task, session_id, opts \\ []) do
    system_prompt = Keyword.get(opts, :system_prompt, "be helpful")
    max_turns = Keyword.get(opts, :max_turns, 10)
    config = %Agent.Config{task: task, system_prompt: system_prompt, max_turns: max_turns}
    name = "agent_#{System.unique_integer([:positive])}"
    via = Shem.ProcessRegistry.via_tuple(name)
    child_spec = %{
      id: name,
      start: {Shem.Agent.Server, :start_link, [{name, config, session_id, [name: via]}]},
      restart: :temporary
    }
    {:ok, _pid} = Horde.DynamicSupervisor.start_child(Shem.AgentSupervisor, child_spec)
    name
  end

  defp collect_stream_chunks(session_id) do
    collect_stream_chunks(session_id, [])
  end

  defp collect_stream_chunks(session_id, acc) do
    receive do
      {:stream_chunk, ^session_id, token} -> collect_stream_chunks(session_id, [token | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end
end
