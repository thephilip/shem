defmodule Shem.SeedToolsTest do
  use ExUnit.Case, async: true
  alias Shem.Lab.Registry

  test "all/0 returns the three seed tools" do
    ids = Enum.map(Shem.SeedTools.all(), & &1.id) |> Enum.sort()
    assert ids == ["diff_text", "graphify_query", "json_query"]
  end

  test "seed tools are present in the live registry" do
    ids = Enum.map(Registry.all(), & &1.id)
    assert "diff_text" in ids
    assert "json_query" in ids
    assert "graphify_query" in ids
  end
end
