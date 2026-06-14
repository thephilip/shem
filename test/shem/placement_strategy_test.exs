defmodule Shem.PlacementStrategyTest do
  use ExUnit.Case, async: true

  alias Shem.PlacementStrategy

  @members [
    %{status: :alive, name: {:sup_a, :node_a@host}},
    %{status: :alive, name: {:sup_b, :node_b@host}}
  ]

  test "no placement_node — delegates to uniform distribution" do
    child_spec = %{id: :test}
    result = PlacementStrategy.choose_node(child_spec, @members)
    assert {:ok, _member} = result
  end

  test "placement_node matches a member — returns that member" do
    child_spec = %{id: :test, placement_node: :node_a@host}
    assert {:ok, %{status: :alive, name: {:sup_a, :node_a@host}}} =
             PlacementStrategy.choose_node(child_spec, @members)
  end

  test "placement_node not in members — falls back to uniform distribution" do
    child_spec = %{id: :test, placement_node: :node_c@host}
    result = PlacementStrategy.choose_node(child_spec, @members)
    assert {:ok, _member} = result
  end

  test "empty members list — returns no_alive_nodes error" do
    child_spec = %{id: :test, placement_node: :node_a@host}
    assert {:error, :no_alive_nodes} = PlacementStrategy.choose_node(child_spec, [])
  end

  test "empty members, no placement_node — returns no_alive_nodes error" do
    child_spec = %{id: :test}
    assert {:error, :no_alive_nodes} = PlacementStrategy.choose_node(child_spec, [])
  end
end
