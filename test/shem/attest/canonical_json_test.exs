defmodule Shem.Attest.CanonicalJSONTest do
  use ExUnit.Case, async: true
  alias Shem.Attest.CanonicalJSON

  test "sorts object keys and uses compact separators" do
    assert CanonicalJSON.encode(%{"b" => 1, "a" => 2}) == ~s({"a":2,"b":1})
  end

  test "atom keys and values become strings; nil/bool stay JSON literals" do
    assert CanonicalJSON.encode(%{type: :agent_started, ok: true, x: nil}) ==
             ~s({"ok":true,"type":"agent_started","x":null})
  end

  test "tuples become arrays; nested maps recurse and sort" do
    assert CanonicalJSON.encode(%{k: {1, :a}, m: %{"z" => 1, "y" => 2}}) ==
             ~s({"k":[1,"a"],"m":{"y":2,"z":1}})
  end

  test "matches Python json.dumps for a Unicode + escape fixture" do
    # Reference produced by:
    #   json.dumps({"s":"héllo \"q\"\n","n":3}, sort_keys=True,
    #              separators=(",",":"), ensure_ascii=False)
    assert CanonicalJSON.encode(%{"s" => "héllo \"q\"\n", "n" => 3}) ==
             ~s({"n":3,"s":"héllo \\"q\\"\\n"})
  end
end
