defmodule Shem.ProcessRegistry do
  @registry Shem.Registry

  @spec via_tuple(term()) :: {:via, Registry, {atom(), term()}}
  def via_tuple(name), do: {:via, Registry, {@registry, name}}
end
