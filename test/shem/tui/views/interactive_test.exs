defmodule Shem.TUI.Views.InteractiveTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.Views.Interactive

  defp base_model do
    %{
      mode: :interactive,
      command_buffer: "",
      paused: false,
      event_log_stats: %{sessions: 0, total_events: 0},
      tool_count: 0,
      mcp_client_count: 0,
      mcp_outbound_count: 0,
      agents: [],
      focused_agent: nil,
      agent_view: nil,
      command_error: nil,
      command_output: nil,
      trust_counts: %{high: 0, medium: 0, low: 0, unrated: 0},
      multiline_buffer: [],
      multiline_target: nil
    }
  end

  test "render/1 returns a Ratatouille view element" do
    result = Interactive.render(base_model())
    assert is_map(result)
    assert result.tag == :view
  end

  test "render/1 shows 'No active session' when agent_view is nil and command_output is nil" do
    rendered = Interactive.render(base_model()) |> inspect(limit: :infinity)
    assert rendered =~ "No active session"
  end

  test "render/1 shows command_output content when agent_view is nil and command_output is set" do
    model = %{base_model() | command_output: "Lab Tools (2)\n  my_tool   high   3 hardenings"}
    rendered = Interactive.render(model) |> inspect(limit: :infinity)
    assert rendered =~ "my_tool"
    assert rendered =~ "high"
    refute rendered =~ "No active session"
  end

  test "render/1 shows agent view (not command_output) when agent_view is set" do
    agent_view = %{
      status: :running,
      turn_count: 1,
      max_turns: 10,
      current_reasoning: "thinking...",
      streaming_buffer: nil,
      last_tool_call: nil,
      history: [],
      recent_events: [],
      agent_name: "agent_1"
    }
    model = %{base_model() | agent_view: agent_view, focused_agent: "agent_1", command_output: "some output"}
    rendered = Interactive.render(model) |> inspect(limit: :infinity)
    assert rendered =~ "thinking..."
    refute rendered =~ "some output"
  end

  describe "render_agent_list — node badge" do
    test "shows node badge for remote agent" do
      remote_node = :"shem_b@somehost"
      model = %{
        base_model()
        | agents: [
            %{name: "agent_foo", pid: self(), status: :running, turn_count: 2, session_id: "ses_x", node: remote_node}
          ],
          focused_agent: nil
      }

      rendered = Interactive.render(model) |> inspect(limit: :infinity)
      assert rendered =~ "shem_b"
    end

    test "no node badge for local agent" do
      model = %{
        base_model()
        | agents: [
            %{name: "agent_bar", pid: self(), status: :running, turn_count: 1, session_id: "ses_y", node: Node.self()}
          ],
          focused_agent: nil
      }

      rendered = Interactive.render(model) |> inspect(limit: :infinity)
      refute rendered =~ "nonode@nohost"
    end
  end

  describe "render/1 — :multiline_input mode" do
    test "render/1 shows multiline editor panel when mode is :multiline_input" do
      model = %{base_model() |
        mode: :multiline_input,
        multiline_target: {:preset_add, "my_preset"},
        multiline_buffer: ["You are a reviewer.", "Be thorough."],
        command_buffer: "partial line"
      }
      rendered = Interactive.render(model) |> inspect(limit: :infinity)
      assert rendered =~ "my_preset"
      assert rendered =~ "You are a reviewer."
      assert rendered =~ "/done"
    end

    test "render/1 in :multiline_input does not show 'No active session'" do
      model = %{base_model() |
        mode: :multiline_input,
        multiline_target: {:preset_add, "p"},
        multiline_buffer: [],
        command_buffer: ""
      }
      rendered = Interactive.render(model) |> inspect(limit: :infinity)
      refute rendered =~ "No active session"
    end
  end
end
