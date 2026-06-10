defmodule Shem.TUI.AppHireTest do
  use ExUnit.Case, async: false

  alias Shem.TUI.App
  alias Shem.Agent.PresetStore

  setup_all do
    Shem.TUI.Welcome.mark_welcomed()
    :ok
  end

  setup do
    PresetStore.flush()
    :ok
  end

  defp base_model, do: App.init(%{})

  describe "update/2 — {{:hire_complete, name}, result}" do
    test "on success: stores preset and sets command_output to 'hired: <name>'" do
      model = base_model()
      new_model = App.update(model, {{:hire_complete, "researcher"}, {:ok, "You summarise papers."}})

      assert new_model.command_output == "hired: researcher"
      assert {:ok, %{system_prompt: "You summarise papers.", tools: :all}} =
               PresetStore.get("researcher")
    end

    test "on error: sets command_output to failure message, no preset stored" do
      model = base_model()
      new_model = App.update(model, {{:hire_complete, "researcher"}, {:error, :timeout}})

      assert new_model.command_output =~ "hire failed"
      assert new_model.command_output =~ "timeout"
      assert {:error, :not_found} = PresetStore.get("researcher")
    end

    test "on success: silently overwrites existing preset" do
      PresetStore.put("researcher", %{system_prompt: "old", tools: :all})
      model = base_model()
      App.update(model, {{:hire_complete, "researcher"}, {:ok, "new prompt"}})

      assert {:ok, %{system_prompt: "new prompt"}} = PresetStore.get("researcher")
    end
  end

  describe "update/2 — {:event, @enter} with /hire buffer (integration)" do
    alias Shem.LLM.{Response, StubTransport}

    @enter 13

    setup do
      StubTransport.Server.reset()
      :ok
    end

    test "fires LLM call and returns command with correct message and function" do
      StubTransport.Server.push_response(
        {:ok, %Response{content: "You are a researcher.", tokens_used: 10, model: :default, latency_ms: 1}}
      )

      model = %{base_model() | command_buffer: "/hire analyst examines data"}
      {new_model, command} = App.update(model, {:event, %{key: @enter}})

      assert new_model.command_buffer == ""
      assert new_model.command_output == "hiring analyst..."
      assert new_model.command_error == nil
      assert command.message == {:hire_complete, "analyst"}
      assert command.function.() == {:ok, "You are a researcher."}
    end

    test "on LLM failure: command function returns {:error, reason}" do
      StubTransport.Server.push_response({:error, :transport_down})

      model = %{base_model() | command_buffer: "/hire analyst examines data"}
      {_new_model, command} = App.update(model, {:event, %{key: @enter}})

      assert {:error, _reason} = command.function.()
    end

    test "full round-trip: hire fires, completes, stores preset" do
      StubTransport.Server.push_response(
        {:ok, %Response{content: "Generated prompt.", tokens_used: 5, model: :default, latency_ms: 1}}
      )

      model = %{base_model() | command_buffer: "/hire devops reads logs"}
      {after_hire, command} = App.update(model, {:event, %{key: @enter}})

      result = command.function.()
      final = App.update(after_hire, {command.message, result})
      assert final.command_output == "hired: devops"
      assert {:ok, %{system_prompt: "Generated prompt.", tools: :all}} = PresetStore.get("devops")
    end
  end
end
