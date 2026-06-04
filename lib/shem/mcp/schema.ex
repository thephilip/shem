defmodule Shem.MCP.Schema do
  @moduledoc """
  Validates MCP handler input arguments against a lightweight schema.

  Schema format: `%{"field" => %{"type" => "string"|"integer"|"boolean"}}`.
  Fields default to required unless `"required" => false` is set explicitly.
  """

  @type schema :: %{String.t() => %{String.t() => term()}}

  @spec validate(map(), schema()) :: {:ok, map()} | {:error, :invalid_args, String.t()}
  def validate(args, schema) when map_size(schema) == 0, do: {:ok, args}

  def validate(args, schema) do
    errors =
      Enum.flat_map(schema, fn {field, spec} ->
        required = Map.get(spec, "required", true)
        type = Map.get(spec, "type")

        cond do
          required and not Map.has_key?(args, field) ->
            ["#{field}: required field missing"]

          Map.has_key?(args, field) and not valid_type?(args[field], type) ->
            ["#{field}: expected #{type}, got #{inspect(args[field])}"]

          true ->
            []
        end
      end)

    if errors == [] do
      {:ok, args}
    else
      {:error, :invalid_args, Enum.join(errors, "; ")}
    end
  end

  defp valid_type?(v, "string"), do: is_binary(v)
  defp valid_type?(v, "integer"), do: is_integer(v)
  defp valid_type?(v, "boolean"), do: is_boolean(v)
  defp valid_type?(_, nil), do: true
  defp valid_type?(_, _), do: true
end
