defmodule Shem.TUI.AppTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.App

  describe "init/1" do
    test "default model starts in dashboard mode, unpaused, with empty buffer" do
      model = App.init(%{})
      assert model.mode == :dashboard
      assert model.command_buffer == ""
      assert model.paused == false
      assert model.event_log_stats == %{sessions: 0, total_events: 0}
    end
  end

  describe "update/2 — mode switching" do
    test "'d' key switches to dashboard mode" do
      model = %{App.init(%{}) | mode: :interactive}
      result = App.update(model, {:event, %{ch: ?d, key: 0}})
      assert result.mode == :dashboard
    end

    test "'i' key switches to interactive mode" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: ?i, key: 0}})
      assert result.mode == :interactive
    end

    test "mode keys are ignored while command buffer is open" do
      model = %{App.init(%{}) | command_buffer: "/st"}
      result = App.update(model, {:event, %{ch: ?i, key: 0}})
      assert result.mode == :dashboard
    end
  end

  describe "update/2 — pause and resume" do
    test "space key toggles paused on" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: 0, key: ?\s}})
      assert result.paused == true
    end

    test "space key toggles paused off when already paused" do
      model = %{App.init(%{}) | paused: true}
      result = App.update(model, {:event, %{ch: 0, key: ?\s}})
      assert result.paused == false
    end

    test "esc key (27) always pauses" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: 0, key: 27}})
      assert result.paused == true
    end

    test "pause keys are ignored while command buffer is open" do
      model = %{App.init(%{}) | command_buffer: "/"}
      result = App.update(model, {:event, %{ch: 0, key: ?\s}})
      assert result.paused == false
    end
  end

  describe "update/2 — command buffer" do
    test "'/' opens the command buffer" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: ?/, key: 0}})
      assert result.command_buffer == "/"
    end

    test "characters append to the buffer when it is active" do
      model = %{App.init(%{}) | command_buffer: "/"}
      result = App.update(model, {:event, %{ch: ?s, key: 0}})
      assert result.command_buffer == "/s"
    end

    test "backspace (127) removes the last character" do
      model = %{App.init(%{}) | command_buffer: "/st"}
      result = App.update(model, {:event, %{ch: 0, key: 127}})
      assert result.command_buffer == "/s"
    end

    test "backspace on empty buffer is a no-op" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: 0, key: 127}})
      assert result.command_buffer == ""
    end

    test "backspace on single-char buffer clears it" do
      model = %{App.init(%{}) | command_buffer: "/"}
      result = App.update(model, {:event, %{ch: 0, key: 127}})
      assert result.command_buffer == ""
    end
  end

  describe "update/2 — tick subscription" do
    test ":tick message updates event_log_stats from EventLog.stats()" do
      model = App.init(%{})
      updated = App.update(model, :tick)
      assert is_integer(updated.event_log_stats.sessions)
      assert is_integer(updated.event_log_stats.total_events)
    end
  end

  describe "init/1 — new Phase 9 fields" do
    test "model has agents list defaulting to empty" do
      model = App.init(%{})
      assert model.agents == []
    end

    test "model has focused_agent defaulting to nil" do
      model = App.init(%{})
      assert model.focused_agent == nil
    end

    test "model has agent_view defaulting to nil" do
      model = App.init(%{})
      assert model.agent_view == nil
    end

    test "model has command_error defaulting to nil" do
      model = App.init(%{})
      assert model.command_error == nil
    end
  end

  describe "update/2 — Tab key cycles focused_agent" do
    test "Tab with no agents is a no-op" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: 0, key: 9}})
      assert result.focused_agent == nil
    end

    test "Tab with agents and no focused agent focuses first" do
      model = %{App.init(%{}) | agents: [%{name: "a1", status: :running, session_id: "s1", turn_count: 0}]}
      result = App.update(model, {:event, %{ch: 0, key: 9}})
      assert result.focused_agent == "a1"
    end

    test "Tab cycles to next agent" do
      agents = [
        %{name: "a1", status: :running, session_id: "s1", turn_count: 0},
        %{name: "a2", status: :done, session_id: "s2", turn_count: 3}
      ]
      model = %{App.init(%{}) | agents: agents, focused_agent: "a1"}
      result = App.update(model, {:event, %{ch: 0, key: 9}})
      assert result.focused_agent == "a2"
    end

    test "Tab wraps around from last agent to first" do
      agents = [
        %{name: "a1", status: :running, session_id: "s1", turn_count: 0},
        %{name: "a2", status: :done, session_id: "s2", turn_count: 3}
      ]
      model = %{App.init(%{}) | agents: agents, focused_agent: "a2"}
      result = App.update(model, {:event, %{ch: 0, key: 9}})
      assert result.focused_agent == "a1"
    end

    test "Tab is ignored when command buffer is active" do
      agents = [%{name: "a1", status: :running, session_id: "s1", turn_count: 0}]
      model = %{App.init(%{}) | agents: agents, command_buffer: "/some"}
      result = App.update(model, {:event, %{ch: 0, key: 9}})
      assert result.focused_agent == nil
    end
  end
end
