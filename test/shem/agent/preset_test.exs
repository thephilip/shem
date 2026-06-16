defmodule Shem.Agent.PresetTest do
  use ExUnit.Case, async: false

  alias Shem.Agent.Preset

  describe "resolve/1 — built-ins" do
    test "general preset exists with :all tools" do
      assert {:ok, preset} = Preset.resolve("general")
      assert is_binary(preset.system_prompt)
      assert preset.tools == :all
    end

    test "coder preset exists with :all tools" do
      assert {:ok, preset} = Preset.resolve("coder")
      assert is_binary(preset.system_prompt)
      assert preset.tools == :all
    end

    test "explorer preset exists with restricted tools list" do
      assert {:ok, preset} = Preset.resolve("explorer")
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
    test "user-defined presets in :user_presets are resolvable" do
      custom = [%{name: "custom", system_prompt: "custom prompt", tools: :all}]
      Application.put_env(:shem, :user_presets, custom)
      on_exit(fn -> Application.delete_env(:shem, :user_presets) end)

      assert {:ok, preset} = Preset.resolve("custom")
      assert preset.system_prompt == "custom prompt"
    end

    test "built-ins are still resolvable when :user_presets is set" do
      custom = [%{name: "custom", system_prompt: "custom prompt", tools: :all}]
      Application.put_env(:shem, :user_presets, custom)
      on_exit(fn -> Application.delete_env(:shem, :user_presets) end)

      assert {:ok, _} = Preset.resolve("general")
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
      assert "coder" in names
      assert "explorer" in names
    end
  end

  describe "resolve/1 — dynamic layer" do
    setup do
      Shem.Agent.PresetStore.flush()
      on_exit(fn -> Shem.Agent.PresetStore.flush() end)
      :ok
    end

    test "resolves a preset from PresetStore when not in static layers" do
      Shem.Agent.PresetStore.put("dynamic_one", %{system_prompt: "Dynamic prompt", tools: :all})
      assert {:ok, %{system_prompt: "Dynamic prompt"}} = Preset.resolve("dynamic_one")
    end

    test "static (built-in) preset wins over same-named dynamic preset" do
      Shem.Agent.PresetStore.put("general", %{system_prompt: "Overridden", tools: :all})
      assert {:ok, %{system_prompt: prompt}} = Preset.resolve("general")
      refute prompt == "Overridden"
    end

    test "config preset wins over same-named dynamic preset" do
      Shem.Agent.PresetStore.put("shared_name", %{system_prompt: "Dynamic version", tools: :all})
      Application.put_env(:shem, :user_presets, [%{name: "shared_name", system_prompt: "Config version", tools: :all}])
      on_exit(fn -> Application.delete_env(:shem, :user_presets) end)
      assert {:ok, %{system_prompt: "Config version"}} = Preset.resolve("shared_name")
    end

    test "returns {:error, :not_found} for unknown preset not in any layer" do
      assert {:error, :not_found} = Preset.resolve("__nonexistent__")
    end
  end

  describe "all/0 — source annotation" do
    setup do
      Shem.Agent.PresetStore.flush()
      on_exit(fn -> Shem.Agent.PresetStore.flush() end)
      :ok
    end

    test "built-in presets have source: :builtin" do
      presets = Preset.all()
      builtin = Enum.filter(presets, &(&1.source == :builtin))
      assert length(builtin) >= 3
      assert Enum.any?(builtin, &(&1.name == "general"))
    end

    test "dynamic presets have source: :dynamic" do
      Shem.Agent.PresetStore.put("my_dyn", %{system_prompt: "Dyn", tools: :all})
      presets = Preset.all()
      dynamic = Enum.filter(presets, &(&1.source == :dynamic))
      assert Enum.any?(dynamic, &(&1.name == "my_dyn"))
    end

    test "config presets have source: :config" do
      Application.put_env(:shem, :user_presets, [%{name: "cfg_preset", system_prompt: "Config", tools: :all}])
      on_exit(fn -> Application.delete_env(:shem, :user_presets) end)
      presets = Preset.all()
      config_layer = Enum.filter(presets, &(&1.source == :config))
      assert Enum.any?(config_layer, &(&1.name == "cfg_preset"))
    end

    test "all/0 returns a flat list" do
      result = Preset.all()
      assert is_list(result)
      assert Enum.all?(result, &is_map/1)
    end
  end

  describe "resolve/1 — built-in presets" do
    test "resolves coder preset" do
      assert {:ok, preset} = Preset.resolve("coder")
      assert is_binary(preset.system_prompt)
      assert preset.tools == :all
    end

    test "resolves researcher preset" do
      assert {:ok, _} = Preset.resolve("researcher")
    end

    test "resolves writer preset" do
      assert {:ok, _} = Preset.resolve("writer")
    end

    test "resolves security preset" do
      assert {:ok, preset} = Preset.resolve("security")
      assert preset.tools == ["read_file", "list_dir", "shell"]
    end

    test "resolves explorer preset" do
      assert {:ok, preset} = Preset.resolve("explorer")
      assert is_list(preset.tools)
    end
  end

  describe "all/0 — built-in presets" do
    test "includes all seven built-in presets" do
      names = Preset.all() |> Enum.map(& &1.name)
      for name <- ~w[general coder researcher writer security explorer elixir_toolsmith] do
        assert name in names
      end
    end
  end

  describe "elixir_toolsmith preset" do
    test "resolves successfully" do
      assert {:ok, preset} = Preset.resolve("elixir_toolsmith")
      assert is_binary(preset.system_prompt)
    end

    test "tools restricted to write_tool and run_code" do
      assert {:ok, preset} = Preset.resolve("elixir_toolsmith")
      assert is_list(preset.tools)
      assert "write_tool" in preset.tools
      assert "run_code" in preset.tools
      refute "shell" in preset.tools
      refute "spawn_agent" in preset.tools
      refute "read_file" in preset.tools
    end

    test "max_turns is 8" do
      assert {:ok, preset} = Preset.resolve("elixir_toolsmith")
      assert preset.max_turns == 8
    end

    test "system prompt teaches write_tool calling convention" do
      assert {:ok, preset} = Preset.resolve("elixir_toolsmith")
      assert preset.system_prompt =~ "write_tool"
      assert preset.system_prompt =~ "description"
      assert preset.system_prompt =~ "graduated:"
    end
  end

  describe "resolve/1 — max_turns and cross-preset mentions" do
    test "general preset system prompt mentions elixir_toolsmith" do
      assert {:ok, preset} = Preset.resolve("general")
      assert preset.system_prompt =~ "elixir_toolsmith"
    end

    test "coder preset system prompt mentions elixir_toolsmith" do
      assert {:ok, preset} = Preset.resolve("coder")
      assert preset.system_prompt =~ "elixir_toolsmith"
    end

    test "general preset max_turns defaults to 20" do
      assert {:ok, preset} = Preset.resolve("general")
      assert preset.max_turns == 20
    end
  end
end
