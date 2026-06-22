defmodule Shem.SeedTools.JsonQuery do
  @moduledoc "Extract a value from a JSON string by dotted path. Integer segments index lists."
  @external_resource __ENV__.file
  @source File.read!(__ENV__.file)

  def run(%{"json" => json, "path" => path}) when is_binary(json) and is_binary(path) do
    case Jason.decode(json) do
      {:ok, data} ->
        case walk(data, String.split(path, ".")) do
          {:ok, value} -> %{"value" => value}
          :error -> %{"error" => "path not found"}
        end

      {:error, _} ->
        %{"error" => "invalid json"}
    end
  end

  defp walk(data, []), do: {:ok, data}

  defp walk(data, [seg | rest]) when is_map(data) do
    case Map.fetch(data, seg) do
      {:ok, v} -> walk(v, rest)
      :error -> :error
    end
  end

  defp walk(data, [seg | rest]) when is_list(data) do
    case Integer.parse(seg) do
      {i, ""} ->
        case Enum.fetch(data, i) do
          {:ok, v} -> walk(v, rest)
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp walk(_, _), do: :error

  def tool do
    %Shem.Tool{
      id: "json_query",
      name: "JsonQuery",
      runtime: {:beam, __MODULE__},
      source: @source,
      test_source: "",
      input_schema: %{"json" => %{"type" => "string"}, "path" => %{"type" => "string"}},
      graduated_at: ~U[2026-06-22 00:00:00Z],
      metadata: %{"description" => "Extract a value from a JSON string by dotted path."}
    }
  end
end
