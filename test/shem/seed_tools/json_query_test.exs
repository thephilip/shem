defmodule Shem.SeedTools.JsonQueryTest do
  use ExUnit.Case, async: true
  alias Shem.SeedTools.JsonQuery

  test "extracts a nested value with list index" do
    json = ~s({"a": {"b": [10, {"c": 42}]}})
    assert JsonQuery.run(%{"json" => json, "path" => "a.b.1.c"}) == %{"value" => 42}
  end

  test "missing path returns an error map" do
    assert JsonQuery.run(%{"json" => ~s({"a": 1}), "path" => "a.z"}) == %{"error" => "path not found"}
  end

  test "invalid json returns an error map" do
    assert JsonQuery.run(%{"json" => "{not json", "path" => "a"}) == %{"error" => "invalid json"}
  end
end
