defmodule Shem.PlacementStrategy do
  @behaviour Horde.DistributionStrategy

  @impl true
  def choose_node(child_spec, members) when members != [] do
    target = Map.get(child_spec, :placement_node)

    if target do
      case Enum.find(members, fn {_, n} -> n == target end) do
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
