defmodule Shem.Trust.StoreTest do
  use ExUnit.Case, async: false

  alias Shem.Trust.Store

  setup do
    Store.flush()
    on_exit(fn -> Store.flush() end)
    :ok
  end

  describe "score/1" do
    test "returns {:error, :unrated} for unknown tool_id" do
      assert {:error, :unrated} = Store.score("no_such_tool")
    end
  end

  describe "record/2 and score/1" do
    test "clean first pass sets score to 1.0" do
      Store.record("tool_1", %{outcome: :clean, rounds: 1})
      assert {:ok, score} = Store.score("tool_1")
      assert_in_delta score, 1.0, 0.001
    end

    test "clean pass after 3 rounds decays score" do
      Store.record("tool_2", %{outcome: :clean, rounds: 3})
      assert {:ok, score} = Store.score("tool_2")
      # 1.0 - (3-1)*0.15 = 0.7
      assert_in_delta score, 0.7, 0.001
    end

    test "max_rounds_reached sets score to 0.2" do
      Store.record("tool_3", %{outcome: :max_rounds_reached, rounds: 3})
      assert {:ok, score} = Store.score("tool_3")
      assert_in_delta score, 0.2, 0.001
    end

    test "error sets score to 0.1" do
      Store.record("tool_4", %{outcome: :error, rounds: 0})
      assert {:ok, score} = Store.score("tool_4")
      assert_in_delta score, 0.1, 0.001
    end

    test "second record blends with recency weight 0.7" do
      Store.record("tool_5", %{outcome: :clean, rounds: 1})   # score = 1.0
      Store.record("tool_5", %{outcome: :max_rounds_reached, rounds: 3})  # new = 0.7 * 0.2 + 0.3 * 1.0 = 0.44
      assert {:ok, score} = Store.score("tool_5")
      assert_in_delta score, 0.44, 0.001
    end

    test "score clamped to [0.0, 1.0]" do
      Store.record("tool_6", %{outcome: :clean, rounds: 1})
      Store.record("tool_6", %{outcome: :clean, rounds: 1})
      assert {:ok, score} = Store.score("tool_6")
      assert score <= 1.0
      assert score >= 0.0
    end
  end

  describe "all/0" do
    test "returns map of all recorded tool_ids to scores" do
      Store.record("tool_a", %{outcome: :clean, rounds: 1})
      Store.record("tool_b", %{outcome: :error, rounds: 1})
      result = Store.all()
      assert Map.has_key?(result, "tool_a")
      assert Map.has_key?(result, "tool_b")
      assert result["tool_a"] >= 0.9
    end
  end

  describe "DETS persistence across restarts" do
    test "score survives GenServer restart at same path" do
      tmp_path = "tmp/trust_persist_#{System.unique_integer([:positive])}.dets"
      on_exit(fn -> File.rm(tmp_path) end)

      {:ok, pid1} = GenServer.start_link(Store, [path: tmp_path])
      GenServer.call(pid1, {:record, "persist_tool", :clean, 1})
      GenServer.stop(pid1)

      {:ok, pid2} = GenServer.start_link(Store, [path: tmp_path])
      assert {:ok, score} = GenServer.call(pid2, {:score, "persist_tool"})
      assert score >= 0.9
      GenServer.stop(pid2)
    end
  end
end
