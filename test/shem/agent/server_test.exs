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
    {:ok, name, _} = Agent.start(config)
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

  describe "project context injection" do
    test "project_context is prepended to system_prompt when set" do
      project = %Shem.Context.Project{
        path: "/tmp/test_project",
        name: "test_project",
        type: :elixir,
        contents: [{"mix.exs", :file}],
        git_repo?: false
      }
      config = %Agent.Config{
        task: "hello",
        system_prompt: "You are a coder.",
        project_context: project
      }
      stub("ok")
      {:ok, name, _} = Agent.start(config)
      assert {:ok, :done} = Agent.await(name, 2_000)
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
      # drain: the agent must consume its own stub before this test ends,
      # or it can eat the NEXT test's stubbed response after the queue reset
      assert {:ok, :done} = Agent.await(name, 2_000)
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
      :ok = :pg.join(:shem_streams, session_id, self())
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
      :ok = :pg.join(:shem_streams, session_id, self())
      name = start_agent_with_session("stream done test", session_id)

      assert {:ok, :done} = Agent.await(name, 2_000)

      assert_receive {:stream_done, ^session_id}, 500
    end
  end

  describe "await_result/2" do
    test "returns {:ok, answer} when agent completes with a final answer" do
      stub("The computed answer.")
      name = start_agent("compute something")
      assert {:ok, "The computed answer."} = Agent.await_result(name, 2_000)
    end

    test "returns {:error, :sub_agent_failed} when agent finishes with error status" do
      StubTransport.Server.push_response({:error, :transport_failure})
      name = start_agent("anything")
      assert {:error, :sub_agent_failed} = Agent.await_result(name, 2_000)
    end
  end

  describe "spawn_agent depth propagation" do
    test "agent seeded at max depth cannot spawn sub-agent" do
      # Push a native tool-calls response that attempts spawn_agent
      tool_resp = {:ok, %Response{
        content: nil,
        tool_calls: [%{id: "call_depth_1", name: "spawn_agent", args: %{"task" => "nested sub-task"}}],
        tokens_used: 5,
        model: :default,
        latency_ms: 1
      }}
      StubTransport.Server.push_response(tool_resp)
      # Push final text response after the tool result is returned
      stub("Cannot delegate further — depth limit reached.")

      # Start agent with spawn_depth at max (2 in test config)
      config = %Shem.Agent.Config{
        task: "delegate a sub-task",
        system_prompt: "You are a coordinator.",
        spawn_depth: 2
      }
      {:ok, name, sid} = Shem.Agent.start(config)
      assert {:ok, :done} = Shem.Agent.await(name, 3_000)

      # Verify the tool result in EventLog contains the depth limit error
      {:ok, events} = Shem.EventLog.events(sid)
      tool_result_event = Enum.find(events, &(&1.type == :agent_tool_result))
      assert tool_result_event != nil
      assert String.contains?(tool_result_event.payload.result, "depth limit reached")
    end
  end

  describe "start_with_preset/2" do
    test "starts an agent using a named preset" do
      stub("done")
      assert {:ok, name, _sid} = Agent.start_with_preset("general", "say hello")
      assert is_binary(name)
      assert {:ok, _status} = Agent.await(name, 2_000)
    end

    test "returns error for unknown preset" do
      assert {:error, :not_found} = Agent.start_with_preset("no_such_preset", "task")
    end
  end

  describe ":info call" do
    test "returns status, turn_count and session_id in one call" do
      stub("done")
      name = start_agent("info test")
      assert {:ok, :done} = Agent.await(name, 2_000)

      pid = GenServer.whereis(Shem.ProcessRegistry.via_tuple(name))
      info = GenServer.call(pid, :info)
      assert %{status: :done, turn_count: 1, session_id: "ses_" <> _} = info
    end
  end

  describe "set_fence/2" do
    test "sets fence on running agent config" do
      {:ok, name, _} = Agent.start(%Agent.Config{task: "t", system_prompt: "s"})
      on_exit(fn -> Agent.stop(name) end)

      assert :ok = Agent.set_fence(name, "/home/user/proj")
      # fence is internal to config — verify via round-trip: set then clear
      assert :ok = Agent.set_fence(name, nil)
    end

    test "returns {:error, :not_found} for unknown agent" do
      assert {:error, :not_found} = Agent.set_fence("no_such_agent_xyz", "/tmp")
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

  describe "flush_checkpoint" do
    setup do
      Shem.LLM.StubTransport.Server.set_default(
        {:ok, %Shem.LLM.Response{content: "hello", tokens_used: 1, model: :default, latency_ms: 1}}
      )
      config = %Shem.Agent.Config{task: "say hello", system_prompt: "s", conversational: true}
      name = "flush_test_#{System.unique_integer([:positive])}"
      {:ok, pid, session_id} = Shem.AgentSupervisor.start_agent(name, config)
      # Wait for agent to complete first turn and reach :waiting
      Process.sleep(300)
      %{pid: pid, session_id: session_id, name: name}
    end

    test "flush_checkpoint writes a checkpoint and sets status to :evacuating", %{pid: pid, session_id: session_id} do
      assert :ok = GenServer.call(pid, :flush_checkpoint, 2_000)
      state = :sys.get_state(pid)
      assert state.status == :evacuating
      {:ok, events} = Shem.EventLog.events(session_id)
      # At least 2 checkpoints: one from run_turn, one from flush
      assert Enum.count(events, &(&1.type == :agent_checkpoint)) >= 2
    end

    test "evac_spec returns name, config, and session_id", %{pid: pid, session_id: session_id, name: name} do
      {returned_name, config, sid} = GenServer.call(pid, :evac_spec)
      assert returned_name == name
      assert %Shem.Agent.Config{} = config
      assert sid == session_id
    end
  end

  describe "pause / steer / unpause" do
    test "pause on a waiting conversational agent is rejected" do
      stub("hello!")
      config = %Agent.Config{task: "chat", system_prompt: "s", conversational: true}
      {:ok, name, _sid} = Agent.start(config)
      assert {:ok, :waiting} = Agent.await(name, 2_000)

      assert {:error, :not_running} = Agent.pause(name)
      assert {:error, :not_paused} = Agent.steer(name, "nope")
      assert {:error, :not_paused} = Agent.unpause(name)
      Agent.stop(name)
    end

    test "pause/steer/unpause on an unknown agent returns not_found" do
      assert {:error, :not_found} = Agent.pause("agent_NOPE")
      assert {:error, :not_found} = Agent.steer("agent_NOPE", "x")
      assert {:error, :not_found} = Agent.unpause("agent_NOPE")
    end

    test "full cycle: pause mid-task, steer, unpause, finish with steering applied" do
      # The shell builtin's own timeout defaults to 10s, far above the 0.5s
      # sleep — no env override needed. The sleep holds the server inside
      # handle_info(:run_turn) so our pause call queues ahead of the
      # end-of-turn self-sent :run_turn (FIFO mailbox ordering).

      # turn 1: tool call (shell sleep). turn 2: final answer.
      # shell builtin uses args["cmd"]
      stub(~s({"tool": "shell", "args": {"cmd": "sleep 0.5"}}))
      stub("done after steering")

      config = %Agent.Config{task: "long task", system_prompt: "s", max_turns: 10}
      {:ok, name, sid} = Agent.start(config)

      # the server is inside turn 1 (shell sleep); this call queues and is
      # processed at the turn boundary, before the end-of-turn :run_turn
      Process.sleep(100)
      assert :ok = Agent.pause(name)
      assert {:ok, :paused} = Agent.status(name)

      assert :ok = Agent.steer(name, "actually, summarize instead")
      assert :ok = Agent.unpause(name)
      assert {:ok, :done} = Agent.await(name, 5_000)

      {:ok, events} = Shem.EventLog.events(sid)
      types = Enum.map(events, & &1.type)
      assert :agent_paused in types
      assert :agent_steered in types
      assert :agent_unpaused in types

      steered = Enum.find(events, &(&1.type == :agent_steered))
      assert steered.payload.content == "actually, summarize instead"

      done = Enum.find(events, &(&1.type == :agent_done))
      assert done.payload.content == "done after steering"
      Agent.stop(name)
    end

    test "a queued :run_turn is dropped while paused (no extra turn executes)" do
      # pure state-machine check against the server callbacks
      sid = "ses_PAUSE_#{System.unique_integer([:positive])}"
      {:ok, ^sid} = Shem.EventLog.start_session(sid)

      state = %{
        name: "agent_pausetest",
        config: %Agent.Config{task: "t", system_prompt: "s"},
        history: [],
        session_id: sid,
        turn_count: 1,
        status: :running,
        done_reason: nil,
        awaiting: []
      }

      {:reply, :ok, paused} = Shem.Agent.Server.handle_call(:pause, {self(), make_ref()}, state)
      assert paused.status == :paused

      # the drop-guard must swallow :run_turn without touching state
      {:noreply, same} = Shem.Agent.Server.handle_info(:run_turn, paused)
      assert same.status == :paused
      assert same.turn_count == 1

      # unpause flips status and re-arms the loop (self() receives :run_turn)
      {:reply, :ok, running} =
        Shem.Agent.Server.handle_call(:unpause, {self(), make_ref()}, paused)

      assert running.status == :running
      assert_received :run_turn
    end
  end
end
