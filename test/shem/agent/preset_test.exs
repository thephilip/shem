defmodule Shem.Agent.PresetTest do
  use ExUnit.Case, async: false

  alias Shem.Agent.Preset

  describe "resolve/1 — built-ins" do
    test "general preset exists with :all tools" do
      assert {:ok, preset} = Preset.resolve("general")
      assert is_binary(preset.system_prompt)
      assert preset.tools == :all
    end

    test "coding preset exists with :all tools" do
      assert {:ok, preset} = Preset.resolve("coding")
      assert is_binary(preset.system_prompt)
      assert preset.tools == :all
    end

    test "explore preset exists with restricted tools list" do
      assert {:ok, preset} = Preset.resolve("explore")
      assert is_binary(preset.system_prompt)
      assert is_list(preset.tools)
      assert "read_file" in preset.tools
      assert "list_dir" in preset.tools
      assert "shell" in preset.tools
      refute "write_file" in preset.tools
    end

    test "returns :not_found for unknown preset" do
      assert {:error, :not_found} = Preset.resolve("nonexistent_xyz")
    end
  end

  describe "resolve/1 — user overrides" do
    test "user-defined presets override built-ins entirely" do
      custom = [%{name: "custom", system_prompt: "custom prompt", tools: :all}]
      Application.put_env(:shem, :agent_presets, custom)
      on_exit(fn -> Application.delete_env(:shem, :agent_presets) end)

      assert {:ok, preset} = Preset.resolve("custom")
      assert preset.system_prompt == "custom prompt"
      assert {:error, :not_found} = Preset.resolve("general")
    end
  end

  describe "all/0" do
    test "returns list of preset maps" do
      presets = Preset.all()
      assert is_list(presets)
      assert length(presets) >= 3
    end

    test "each preset has name, system_prompt, and tools keys" do
      Preset.all()
      |> Enum.each(fn p ->
        assert Map.has_key?(p, :name)
        assert Map.has_key?(p, :system_prompt)
        assert Map.has_key?(p, :tools)
      end)
    end

    test "built-in names are present by default" do
      names = Preset.all() |> Enum.map(& &1.name)
      assert "general" in names
      assert "coding" in names
      assert "explore" in names
    end
  end
end
