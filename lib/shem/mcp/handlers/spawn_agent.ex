defmodule Shem.MCP.Handlers.SpawnAgent do
  alias Shem.MCP.Schema

  @schema %{
    "goal" => %{"type" => "string"},
    "preset" => %{"type" => "string", "required" => false},
    "placement" => %{"type" => "string", "required" => false}
  }

  @spec call(map()) :: {:ok, map()} | {:error, atom(), any()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema),
         {:ok, placement} <- parse_placement(Map.get(valid, "placement")) do
      preset = Map.get(valid, "preset", "general")

      case Shem.Agent.start_with_preset(preset, valid["goal"], placement: placement) do
        {:ok, _name, session_id} ->
          {:ok, %{"agent_id" => session_id, "status" => "running"}}

        {:error, :not_found} ->
          {:error, :invalid_args, "unknown preset: #{preset}"}

        {:error, reason} ->
          {:error, :spawn_failed, inspect(reason)}
      end
    end
  end

  defp parse_placement(nil), do: {:ok, :any}
  defp parse_placement("any"), do: {:ok, :any}

  defp parse_placement("node:" <> node_str) do
    case node_str do
      "" -> {:error, :invalid_args, "placement node name cannot be empty"}
      n ->
        try do
          {:ok, {:node, String.to_existing_atom(n)}}
        rescue
          ArgumentError -> {:error, :invalid_args, "unknown node: #{n}"}
        end
    end
  end

  defp parse_placement("labels:" <> pairs_str) do
    pairs =
      pairs_str
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Enum.filter(&(length(&1) == 2))
      |> Map.new(fn [k, v] -> {k, v} end)

    if map_size(pairs) == 0 do
      {:error, :invalid_args, "placement labels cannot be empty — use labels:key=value"}
    else
      {:ok, {:labels, pairs}}
    end
  end

  defp parse_placement(other) do
    {:error, :invalid_args,
     "unknown placement format '#{other}' — use any, node:name@host, or labels:key=value"}
  end
end
