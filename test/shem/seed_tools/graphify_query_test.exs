defmodule Shem.SeedTools.GraphifyQueryTest do
  use ExUnit.Case, async: false
  alias Shem.SeedTools.GraphifyQuery

  setup do
    prev = Application.get_env(:shem, :graphify_dir)
    Application.put_env(:shem, :graphify_dir, "test/support/fixtures")
    on_exit(fn -> Application.put_env(:shem, :graphify_dir, prev) end)
    :ok
  end

  test "find matches labels case-insensitively" do
    assert GraphifyQuery.run(%{"op" => "find", "q" => "alph"}) == %{"ids" => ["a"]}
  end

  test "neighbors are undirected with relation and label" do
    %{"neighbors" => n} = GraphifyQuery.run(%{"op" => "neighbors", "id" => "a"})
    assert Enum.sort_by(n, & &1["id"]) ==
             [%{"id" => "b", "label" => "Beta", "relation" => "calls"},
              %{"id" => "c", "label" => "Gamma", "relation" => "uses"}]
  end

  test "path returns the shortest id chain" do
    assert GraphifyQuery.run(%{"op" => "path", "from" => "a", "to" => "c"})["path"] in [["a", "c"]]
  end

  test "god_nodes ranks by degree" do
    %{"god_nodes" => [top | _]} = GraphifyQuery.run(%{"op" => "god_nodes", "n" => 3})
    assert top["degree"] == 2
  end

  test "missing graph returns an error" do
    Application.put_env(:shem, :graphify_dir, "test/support/fixtures/nope")
    assert GraphifyQuery.run(%{"op" => "find", "q" => "x"}) == %{"error" => "no graph; run /graphify ."}
  end

  test "god_nodes with non-integer n defaults to 5 and does not crash" do
    assert GraphifyQuery.run(%{"op" => "god_nodes", "n" => "five"})["god_nodes"] |> is_list()
  end

  test "find without q returns an error" do
    assert GraphifyQuery.run(%{"op" => "find"}) == %{"error" => "find requires 'q'"}
  end

  test "neighbors without id returns an error" do
    assert GraphifyQuery.run(%{"op" => "neighbors"}) == %{"error" => "neighbors requires 'id'"}
  end

  test "path without both from and to returns an error" do
    assert GraphifyQuery.run(%{"op" => "path", "from" => "a"}) == %{"error" => "path requires 'from' and 'to'"}
  end
end
