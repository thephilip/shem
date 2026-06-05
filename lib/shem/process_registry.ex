defmodule Shem.ProcessRegistry do
  @registry Shem.Registry

  @spec via_tuple(term()) :: {:via, Horde.Registry, {atom(), term()}}
  def via_tuple(name), do: {:via, Horde.Registry, {@registry, name}}
end
