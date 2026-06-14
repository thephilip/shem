defmodule Shem.PlacementStrategy do
  @moduledoc """
  Custom Horde distribution strategy that respects a `:placement_node` field
  in the child spec. Members are `%{status: :alive, name: {sup_name, node}}` maps
  per the Horde DynamicSupervisor contract.

  If `:placement_node` is set to a node atom, routes the child to that node
  (falls back to uniform distribution if the node isn't a current member). If
  unset, delegates to `Horde.UniformDistribution`.
  """
  @behaviour Horde.DistributionStrategy

  @impl true
  def choose_node(child_spec, members) when members != [] do
    target = Map.get(child_spec, :placement_node)

    if target do
      case Enum.find(members, fn m -> match?({_, ^target}, m.name) end) do
        nil -> Horde.UniformDistribution.choose_node(child_spec, members)
        member -> {:ok, member}
      end
    else
      Horde.UniformDistribution.choose_node(child_spec, members)
    end
  end

  def choose_node(_child_spec, []), do: {:error, :no_alive_nodes}

  @impl true
  def has_quorum?(members), do: Horde.UniformDistribution.has_quorum?(members)
end
