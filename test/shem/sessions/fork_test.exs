defmodule Shem.Sessions.ForkTest do
  use ExUnit.Case, async: false

  alias Shem.EventLog
  alias Shem.Sessions.Fork

  defp seed do
    {:ok, sid} = EventLog.start_session()
    {:ok, _} = EventLog.append(sid, :agent_started, %{task: "fork extraction test"})
    {:ok, llm1} = EventLog.append(sid, :llm_call_completed, %{content: "turn one"})
    {:ok, tool} = EventLog.append(sid, :agent_tool_called, %{tool: "diff_text", args: %{}})
    {:ok, llm2} = EventLog.append(sid, :llm_call_completed, %{content: "turn two"})
    {:ok, done} = EventLog.append(sid, :agent_done, %{content: "done"})
    {:ok, events} = EventLog.read_session_events(sid)
    %{sid: sid, events: events, llm1: llm1, tool: tool, llm2: llm2, done: done}
  end

  describe "nearest_at_or_before/2" do
    test "an llm_call_completed target is returned as-is" do
      %{events: events, llm2: llm2} = seed()
      assert {:ok, %{id: id}} = Fork.nearest_at_or_before(events, llm2.id)
      assert id == llm2.id
    end

    test "a non-llm target resolves to the nearest earlier llm_call_completed" do
      %{events: events, llm1: llm1, tool: tool, llm2: llm2, done: done} = seed()
      assert {:ok, %{id: id}} = Fork.nearest_at_or_before(events, tool.id)
      assert id == llm1.id
      assert {:ok, %{id: id2}} = Fork.nearest_at_or_before(events, done.id)
      assert id2 == llm2.id
    end

    test "no llm event at-or-before → error" do
      %{sid: _} = seed()
      {:ok, sid} = EventLog.start_session()
      {:ok, started} = EventLog.append(sid, :agent_started, %{task: "no llm yet"})
      {:ok, events} = EventLog.read_session_events(sid)
      assert {:error, :fork_event_not_found} = Fork.nearest_at_or_before(events, started.id)
      assert {:error, :fork_event_not_found} = Fork.nearest_at_or_before(events, "evt_nope")
    end
  end

  describe "resume_opts/1" do
    test "reads brain/preset/max_turns/model from the agent_started payload" do
      {:ok, sid} = EventLog.start_session()

      {:ok, _} =
        EventLog.append(sid, :agent_started, %{
          task: "t",
          model: :default,
          max_turns: 7,
          preset: "general",
          brain: :model
        })

      {:ok, events} = EventLog.read_session_events(sid)
      opts = Fork.resume_opts(events)
      assert opts[:brain] == :model
      assert opts[:preset] == "general"
      assert opts[:max_turns] == 7
      assert opts[:model] == :default
    end

    test "legacy payload without brain falls back to the copied checkpoint's config" do
      {:ok, sid} = EventLog.start_session()
      {:ok, _} = EventLog.append(sid, :agent_started, %{task: "t", max_turns: 20, preset: "general"})

      config = %Shem.Agent.Config{task: "t", system_prompt: "sys", brain: :model}

      {:ok, _} =
        EventLog.append(sid, :agent_checkpoint, %{
          history: [],
          turn_count: 0,
          config: config,
          node: node()
        })

      {:ok, events} = EventLog.read_session_events(sid)
      assert Fork.resume_opts(events)[:brain] == :model
    end

    test "legacy payload without brain and no checkpoint defaults to :client" do
      {:ok, sid} = EventLog.start_session()
      {:ok, _} = EventLog.append(sid, :agent_started, %{task: "t", max_turns: 20, preset: "general"})
      {:ok, events} = EventLog.read_session_events(sid)
      assert Fork.resume_opts(events)[:brain] == :client
    end
  end

  describe "build_fork/5 (moved verbatim)" do
    test "copies prefix, injects alt_response, records provenance, finalizes static forks" do
      %{sid: sid, events: events, llm2: llm2} = seed()
      assert {:ok, new_sid} = Fork.build_fork(sid, events, llm2, "ALTERNATE turn two", false)
      {:ok, forked} = EventLog.read_session_events(new_sid)

      assert [%{type: :branch_created, payload: prov} | rest] = forked
      assert prov.original_session_id == sid
      assert prov.fork_event_id == llm2.id

      fork_ev = List.last(rest)
      assert fork_ev.type == :llm_call_completed
      assert fork_ev.payload.content == "ALTERNATE turn two"
      assert Enum.map(rest, & &1.type) ==
               [:agent_started, :llm_call_completed, :agent_tool_called, :llm_call_completed]

      # static fork is finalized
      assert {:error, :session_ended} = EventLog.append(new_sid, :agent_done, %{})
    end
  end
end
