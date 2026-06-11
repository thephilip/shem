defmodule Shem.ProcessRegistry do
  @registry Shem.Registry

  @spec via_tuple(term()) :: {:via, Horde.Registry, {atom(), term()}}
  def via_tuple(name), do: {:via, Horde.Registry, {@registry, name}}

  @spec via_tuple(term(), term()) :: {:via, Horde.Registry, {atom(), term(), term()}}
  def via_tuple(name, value), do: {:via, Horde.Registry, {@registry, name, value}}

  @spec lookup(term()) :: {pid(), term()} | nil
  def lookup(name) do
    case Horde.Registry.lookup(@registry, name) do
      [{pid, value}] -> {pid, value}
      [] -> nil
    end
  end
end
