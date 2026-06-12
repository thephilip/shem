defmodule Shem.TUI.SystemStatsTest do
  use ExUnit.Case, async: false

  alias Shem.TUI.SystemStats

  test "empty/0 returns all-nil stats" do
    assert SystemStats.empty() == %{cpu: nil, mem_used_mb: nil, mem_total_mb: nil}
  end

  test "collect/0 returns a map with the three keys and never raises" do
    stats = SystemStats.collect()
    assert Map.keys(stats) |> Enum.sort() == [:cpu, :mem_total_mb, :mem_used_mb]
  end

  test "format/1 renders dashes when nothing is available" do
    assert SystemStats.format(SystemStats.empty()) == "CPU: --   MEM: --"
  end

  test "format/1 renders cpu and memory when present" do
    assert SystemStats.format(%{cpu: 12.5, mem_used_mb: 3200, mem_total_mb: 16000}) ==
             "CPU: 12.5%   MEM: 3200/16000 MB"
  end

  test "format/1 renders partial data" do
    assert SystemStats.format(%{cpu: nil, mem_used_mb: 3200, mem_total_mb: 16000}) ==
             "CPU: --   MEM: 3200/16000 MB"

    assert SystemStats.format(%{cpu: 7.0, mem_used_mb: nil, mem_total_mb: nil}) ==
             "CPU: 7.0%   MEM: --"
  end
end
