defmodule Shem.Agent.PresetStoreTest do
  use ExUnit.Case, async: false

  alias Shem.Agent.PresetStore

  setup do
    PresetStore.flush()
    on_exit(fn -> PresetStore.flush() end)
    :ok
  end

  describe "put/2 and get/1" do
    test "get returns {:error, :not_found} for unknown name" do
      assert {:error, :not_found} = PresetStore.get("no_such_preset")
    end

    test "put then get returns the stored preset" do
      :ok = PresetStore.put("my_preset", %{system_prompt: "You are helpful.", tools: :all})
      assert {:ok, preset} = PresetStore.get("my_preset")
      assert preset.system_prompt == "You are helpful."
      assert preset.tools == :all
    end

    test "put overwrites an existing preset" do
      PresetStore.put("my_preset", %{system_prompt: "v1", tools: :all})
      PresetStore.put("my_preset", %{system_prompt: "v2", tools: :all})
      assert {:ok, %{system_prompt: "v2"}} = PresetStore.get("my_preset")
    end
  end

  describe "delete/1" do
    test "delete returns {:error, :not_found} for unknown name" do
      assert {:error, :not_found} = PresetStore.delete("no_such_preset")
    end

    test "delete removes an existing preset" do
      PresetStore.put("to_delete", %{system_prompt: "bye", tools: :all})
      assert :ok = PresetStore.delete("to_delete")
      assert {:error, :not_found} = PresetStore.get("to_delete")
    end
  end

  describe "all/0" do
    test "returns empty map when no presets stored" do
      assert %{} = PresetStore.all()
    end

    test "returns map of all stored presets keyed by name" do
      PresetStore.put("a", %{system_prompt: "A", tools: :all})
      PresetStore.put("b", %{system_prompt: "B", tools: ["read_file"]})
      result = PresetStore.all()
      assert Map.has_key?(result, "a")
      assert Map.has_key?(result, "b")
      assert result["a"].system_prompt == "A"
      assert result["b"].tools == ["read_file"]
    end
  end
end
