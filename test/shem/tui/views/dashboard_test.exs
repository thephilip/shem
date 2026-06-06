defmodule Shem.TUI.Views.DashboardTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.Views.Dashboard

  defp base_model do
    %{
      mode: :dashboard,
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

  test "render/1 returns a Ratatouille view element (map with tag: :view)" do
    result = Dashboard.render(base_model())
    assert is_map(result)
    assert result.tag == :view
  end

  test "render/1 shows PAUSED when model.paused is true" do
    model = %{base_model() | paused: true}
    rendered = Dashboard.render(model) |> inspect(limit: :infinity)
    assert rendered =~ "PAUSED"
  end

  test "render/1 shows the command buffer content when it is active" do
    model = %{base_model() | command_buffer: "/style"}
    rendered = Dashboard.render(model) |> inspect(limit: :infinity)
    assert rendered =~ "/style"
  end

  test "render/1 shows keybinding hints in the default state" do
    rendered = Dashboard.render(base_model()) |> inspect(limit: :infinity)
    assert rendered =~ "Dashboard"
  end

  test "render/1 shows live session and event counts from event_log_stats" do
    model = %{base_model() | event_log_stats: %{sessions: 3, total_events: 17}}
    rendered = Dashboard.render(model) |> inspect(limit: :infinity)
    assert rendered =~ "3"
    assert rendered =~ "17"
  end

  test "render/1 shows mcp_outbound_count in client stat line" do
    model = %{base_model() | mcp_outbound_count: 2}
    rendered = Dashboard.render(model) |> inspect(limit: :infinity)
    assert rendered =~ "MCP clients"
    assert rendered =~ "2"
  end

  test "render/1 shows trust band counts from model.trust_counts" do
    model = %{base_model() | trust_counts: %{high: 2, medium: 1, low: 0, unrated: 3}}
    rendered = Dashboard.render(model) |> inspect(limit: :infinity)
    assert rendered =~ "Trust: 2 high  1 med  0 low  3 unrated"
  end

  test "render/1 no longer shows 'Lab: idle' static string" do
    rendered = Dashboard.render(base_model()) |> inspect(limit: :infinity)
    refute rendered =~ "Lab: idle"
  end
end
