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
      cluster_node_count: 1,
      agents: [],
      focused_agent: nil,
      agent_view: nil,
      command_error: nil,
      command_output: nil,
      trust_counts: %{high: 0, medium: 0, low: 0, unrated: 0}
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
end
