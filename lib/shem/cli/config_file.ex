defmodule Shem.CLI.ConfigFile do
  @moduledoc false

  def default_path do
    Path.join([System.user_home!(), ".config", "shem", "config.yaml"])
  end

  @spec read(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def read(path \\ nil) do
    path = path || default_path()

    case File.read(path) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}

      {:ok, content} ->
        Application.ensure_all_started(:yamerl)
        YamlElixir.read_from_string(content)
    end
  end

  @spec write(map(), String.t() | nil) :: :ok | {:error, term()}
  def write(config, path \\ nil) do
    path = path || default_path()
    File.mkdir_p!(Path.dirname(path))
    File.write(path, format(config))
  end

  @spec get(String.t(), String.t() | nil) :: {:ok, term()} | {:error, :not_found | term()}
  def get(dotkey, path \\ nil) do
    with {:ok, config} <- read(path) do
      keys = String.split(dotkey, ".")

      case get_in(config, keys) do
        nil -> {:error, :not_found}
        value -> {:ok, value}
      end
    end
  end

  @spec set(String.t(), term(), String.t() | nil) :: :ok | {:error, term()}
  def set(dotkey, value, path \\ nil) do
    path = path || default_path()

    config =
      case read(path) do
        {:ok, existing} -> existing
        _ -> %{}
      end

    keys = String.split(dotkey, ".")
    updated = put_in_nested(config, keys, value)
    write(updated, path)
  end

  defp put_in_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_in_nested(map, [key | rest], value) do
    nested = Map.get(map, key, %{})
    Map.put(map, key, put_in_nested(nested, rest, value))
  end

  # ponytail: generic recursive serializer — replaces 60-line hardcoded template that silently
  # dropped unknown top-level keys. Keys are sorted for deterministic output.
  defp format(config), do: to_yaml(config, "") <> "\n"

  defp to_yaml(map, indent) when is_map(map) do
    map
    |> Enum.reject(fn {_, v} -> is_map(v) and map_size(v) == 0 end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join("\n", fn {k, v} ->
      case v do
        %{} -> "#{indent}#{k}:\n#{to_yaml(v, indent <> "  ")}"
        s when is_binary(s) -> "#{indent}#{k}: \"#{String.replace(s, "\"", "\\\"")}\""
        scalar -> "#{indent}#{k}: #{scalar}"
      end
    end)
  end
end
