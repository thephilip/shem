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
  end
end
