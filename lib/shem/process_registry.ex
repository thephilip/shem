defmodule Shem.ProcessRegistry do
  @registry Shem.Registry

  @spec via_tuple(term()) :: {:via, Horde.Registry, {atom(), term()}}
  def via_tuple(name), do: {:via, Horde.Registry, {@registry, name}}

  @spec via_tuple(term(), term()) :: {:via, Horde.Registry, {atom(), term(), term()}}
  def via_tuple(name, value), do: {:via, Horde.Registry, {@registry, name, value}}

  @spec via_tuple_with_meta(term(), String.t(), map()) ::
          {:via, Horde.Registry, {atom(), term(), map()}}
  def via_tuple_with_meta(name, session_id, meta) do
    {:via, Horde.Registry, {@registry, name, Map.put(meta, :session_id, session_id)}}
  end

  @spec lookup(term()) :: {pid(), String.t()} | nil
  def lookup(name) do
    case Horde.Registry.lookup(@registry, name) do
      [{pid, %{session_id: sid}}] -> {pid, sid}
      [{pid, value}] when is_binary(value) -> {pid, value}
      [] -> nil
    end
  end

  @spec lookup_meta(term()) :: {pid(), map()} | nil
  def lookup_meta(name) do
    case Horde.Registry.lookup(@registry, name) do
      [{pid, value}] when is_map(value) -> {pid, value}
      [{pid, value}] when is_binary(value) -> {pid, %{session_id: value}}
      [] -> nil
    end
  end
end
