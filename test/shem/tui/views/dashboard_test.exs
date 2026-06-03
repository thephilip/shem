defmodule Shem.TUI.Views.DashboardTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.Views.Dashboard

  defp base_model, do: %{mode: :dashboard, command_buffer: "", paused: false}

  test "render/1 returns a Ratatouille view element (map with tag: :view)" do
    result = Dashboard.render(base_model())
    assert is_map(result)
    assert result.tag == :view
  end

  test "render/1 shows PAUSED when model.paused is true" do
    model = %{base_model() | paused: true}
    rendered = Dashboard.render(model) |> inspect()
    assert rendered =~ "PAUSED"
  end

  test "render/1 shows the command buffer content when it is active" do
    model = %{base_model() | command_buffer: "/style"}
    rendered = Dashboard.render(model) |> inspect()
    assert rendered =~ "/style"
  end

  test "render/1 shows keybinding hints in the default state" do
    rendered = Dashboard.render(base_model()) |> inspect()
    assert rendered =~ "Dashboard"
  end
end
