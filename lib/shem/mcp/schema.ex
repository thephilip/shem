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

  @doc """
  Validates invoke args against a tool's declared JSON-Schema-shaped input
  schema (`"properties"` + `"required"` list — the `write_tool` convention).
  Anything else (empty, flat, malformed) passes through unvalidated: a bad
  declared schema must not brick an otherwise-working tool.
  """
  @spec validate_input(map(), term()) :: {:ok, map()} | {:error, :invalid_args, String.t()}
  def validate_input(args, %{"properties" => props} = schema) when is_map(props) do
    required = List.wrap(schema["required"])

    flat =
      Enum.flat_map(props, fn
        {field, spec} when is_binary(field) and is_map(spec) ->
          [{field, %{"type" => spec["type"], "required" => field in required}}]

        _ ->
          []
      end)
      |> Map.new()

    validate(args, flat)
  end

  def validate_input(args, _schema), do: {:ok, args}

  defp valid_type?(v, "string"), do: is_binary(v)
  defp valid_type?(v, "integer"), do: is_integer(v)
  defp valid_type?(v, "boolean"), do: is_boolean(v)
  defp valid_type?(v, "number"), do: is_number(v)
  defp valid_type?(v, "object"), do: is_map(v)
  defp valid_type?(v, "array"), do: is_list(v)
  defp valid_type?(_, nil), do: true
  defp valid_type?(_, _), do: true
end
