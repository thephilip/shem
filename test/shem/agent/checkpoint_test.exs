defmodule Shem.Agent.CheckpointTest do
  use ExUnit.Case, async: false

  alias Shem.Agent.{Checkpoint, Config}
  alias Shem.EventLog

  defp open_session(id) do
    {:ok, ^id} = EventLog.start_session(id)
    id
  end

  defp make_state(turn_count \\ 2) do
    %{
      history: [
        %{role: :user, content: "do something"},
        %{role: :assistant, content: "I'll help"}
      ],
      turn_count: turn_count,
      config: %Config{task: "do something", system_prompt: "helpful"}
    }
  end

  describe "save/2" do
    test "appends :agent_checkpoint event to the session" do
      id = open_session("ses_CKPT_SAVE_#{System.unique_integer([:positive])}")
      state = make_state()
      assert :ok = Checkpoint.save(id, state)
      {:ok, events} = EventLog.events(id)
      assert Enum.any?(events, &(&1.type == :agent_checkpoint))
    end

    test "checkpoint payload contains history, turn_count, and config" do
      id = open_session("ses_CKPT_PAYLOAD_#{System.unique_integer([:positive])}")
      state = make_state(5)
      Checkpoint.save(id, state)
      {:ok, events} = EventLog.events(id)
      event = Enum.find(events, &(&1.type == :agent_checkpoint))
      assert event.payload.turn_count == 5
      assert event.payload.history == state.history
      assert event.payload.config == state.config
    end

    test "checkpoint payload contains node field" do
      id = open_session("ses_CKPT_NODE_#{System.unique_integer([:positive])}")
      state = make_state()
      Checkpoint.save(id, state)
      {:ok, events} = EventLog.events(id)
      event = Enum.find(events, &(&1.type == :agent_checkpoint))
      assert Map.has_key?(event.payload, :node)
      assert event.payload.node == Node.self()
    end
  end

  describe "reconstruct/1" do
    test "returns :not_found when session has no checkpoints" do
      id = open_session("ses_CKPT_NOTFOUND_#{System.unique_integer([:positive])}")
      assert :not_found = Checkpoint.reconstruct(id)
    end

    test "returns :not_found when session does not exist" do
      assert :not_found = Checkpoint.reconstruct("ses_NONEXISTENT_XYZ")
    end

    test "returns {:ok, checkpoint} after a save" do
      id = open_session("ses_CKPT_ROUNDTRIP_#{System.unique_integer([:positive])}")
      state = make_state(3)
      Checkpoint.save(id, state)
      assert {:ok, checkpoint} = Checkpoint.reconstruct(id)
      assert checkpoint.turn_count == 3
      assert checkpoint.history == state.history
    end

    test "returns the LATEST checkpoint when multiple exist" do
      id = open_session("ses_CKPT_LATEST_#{System.unique_integer([:positive])}")
      Checkpoint.save(id, make_state(1))
      Checkpoint.save(id, make_state(2))
      Checkpoint.save(id, make_state(7))
      assert {:ok, checkpoint} = Checkpoint.reconstruct(id)
      assert checkpoint.turn_count == 7
    end

    test "round-trip: save then reconstruct returns identical state fields" do
      id = open_session("ses_CKPT_IDENTICAL_#{System.unique_integer([:positive])}")
      state = make_state(4)
      Checkpoint.save(id, state)
      {:ok, checkpoint} = Checkpoint.reconstruct(id)
      assert checkpoint.turn_count == state.turn_count
      assert checkpoint.history == state.history
      assert checkpoint.config == state.config
    end

    test "reconstruct/1 returns :not_found for a session with no checkpoint events" do
      {:ok, sid} = EventLog.start_session()
      EventLog.append(sid, :agent_started, %{task: "t", model: :default, max_turns: 20})
      # No checkpoint appended
      assert :not_found = Checkpoint.reconstruct(sid)
    end

    test "reconstruct/1 returns checkpoint from an active session" do
      {:ok, sid} = EventLog.start_session()
      EventLog.append(sid, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(sid, :agent_checkpoint, %{
        history: [%{role: :user, content: "task"}, %{role: :assistant, content: "ok"}],
        turn_count: 1,
        config: %{}
      })
      assert {:ok, checkpoint} = Checkpoint.reconstruct(sid)
      assert checkpoint.turn_count == 1
    end

    test "reconstructed checkpoint includes node field" do
      id = open_session("ses_CKPT_NODE_RT_#{System.unique_integer([:positive])}")
      Checkpoint.save(id, make_state())
      {:ok, checkpoint} = Checkpoint.reconstruct(id)
      assert checkpoint.node == Node.self()
    end

    test "reconstructed checkpoint without node field returns nil for node (backward compat)" do
      id = open_session("ses_CKPT_COMPAT_#{System.unique_integer([:positive])}")
      # Manually write a checkpoint event without the node field (simulates pre-Phase-40 data)
      EventLog.append(id, :agent_checkpoint, %{
        history: [%{role: :user, content: "task"}],
        turn_count: 1,
        config: %{}
      })
      {:ok, checkpoint} = Checkpoint.reconstruct(id)
      assert checkpoint.turn_count == 1
      assert Map.get(checkpoint, :node) == nil
    end

    test "folds the post-checkpoint llm answer into history and advances turn_count" do
      {:ok, sid} = EventLog.start_session()
      EventLog.append(sid, :agent_checkpoint, %{
        history: [%{role: :user, content: "task"}], turn_count: 0, config: %{}, node: node()
      })
      EventLog.append(sid, :llm_call_completed, %{content: "EDITED", tokens_used: 0, latency_ms: 1})

      assert {:ok, %{history: history, turn_count: 1}} = Checkpoint.reconstruct(sid)
      assert List.last(history) == %{role: :assistant, content: "EDITED"}
      EventLog.end_session(sid)
    end

    test "folds a post-checkpoint tool result as a tool message" do
      {:ok, sid} = EventLog.start_session()
      EventLog.append(sid, :agent_checkpoint, %{history: [], turn_count: 2, config: %{}, node: node()})
      EventLog.append(sid, :agent_tool_result, %{tool: "ReverseWords", result: "olleh"})

      assert {:ok, %{history: history, turn_count: 2}} = Checkpoint.reconstruct(sid)
      assert List.last(history) == %{role: :tool, content: "Tool result (ReverseWords): olleh"}
      EventLog.end_session(sid)
    end

    test "returns :not_found when there is no checkpoint (fold_tail variant)" do
      {:ok, sid} = EventLog.start_session()
      EventLog.append(sid, :agent_started, %{task: "x"})
      assert Checkpoint.reconstruct(sid) == :not_found
      EventLog.end_session(sid)
    end
  end
end
