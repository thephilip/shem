defmodule Shem.Recall.TextTest do
  use ExUnit.Case, async: true

  alias Shem.Recall.Text

  describe "flatten/1" do
    test "flattens nested maps, lists, and scalars into one string" do
      payload = %{task: "fix the parser", meta: %{retries: 3, tags: ["urgent", :parser]}}
      s = Text.flatten(payload)
      assert s =~ "fix the parser"
      assert s =~ "3"
      assert s =~ "urgent"
      assert s =~ "parser"
    end

    test "handles structs, tuples, and nil" do
      assert Text.flatten(%{at: ~U[2026-07-11 00:00:00Z]}) =~ "2026-07-11"
      assert Text.flatten({:ok, "done"}) =~ "done"
      assert Text.flatten(nil) == ""
    end
  end

  describe "tokenize/1" do
    test "downcases, splits on non-alphanumerics, drops short tokens" do
      assert Text.tokenize("Fix the JSON-parser, v2!") == ["fix", "the", "json", "parser", "v2"]
    end

    test "handles unicode words" do
      assert "café" in Text.tokenize("the café test")
    end
  end

  describe "rank/2" do
    test "ranks docs containing rarer query terms higher" do
      docs = %{
        a: Text.tokenize("parser bug in the json parser module"),
        b: Text.tokenize("weather report sunny today"),
        c: Text.tokenize("json encoding speed")
      }

      ranked = Text.rank(["json", "parser"], docs)
      ids = Enum.map(ranked, &elem(&1, 0))
      assert List.first(ids) == :a
      assert :b not in ids
    end

    test "empty query or no matches returns []" do
      assert Text.rank([], %{a: ["x"]}) == []
      assert Text.rank(["zzz"], %{a: ["hello", "world"]}) == []
    end
  end
end
