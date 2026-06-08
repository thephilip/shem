defmodule Shem.TUI.AppHireTest do
  use ExUnit.Case, async: false

  alias Shem.TUI.App
  alias Shem.Agent.PresetStore

  setup do
    PresetStore.flush()
    :ok
  end

  defp base_model, do: App.init(%{})

  describe "update/2 — {:hire_complete, name, result}" do
    test "on success: stores preset and sets command_output to 'hired: <name>'" do
      model = base_model()
      new_model = App.update(model, {:hire_complete, "researcher", {:ok, "You summarise papers."}})

      assert new_model.command_output == "hired: researcher"
      assert {:ok, %{system_prompt: "You summarise papers.", tools: :all}} =
               PresetStore.get("researcher")
    end

    test "on error: sets command_output to failure message, no preset stored" do
      model = base_model()
      new_model = App.update(model, {:hire_complete, "researcher", {:error, :timeout}})

      assert new_model.command_output =~ "hire failed"
      assert new_model.command_output =~ "timeout"
      assert {:error, :not_found} = PresetStore.get("researcher")
    end

    test "on success: silently overwrites existing preset" do
      PresetStore.put("researcher", %{system_prompt: "old", tools: :all})
      model = base_model()
      App.update(model, {:hire_complete, "researcher", {:ok, "new prompt"}})

      assert {:ok, %{system_prompt: "new prompt"}} = PresetStore.get("researcher")
    end
  end
end
