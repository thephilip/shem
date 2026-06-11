defmodule Shem.CLI.Config do
  @moduledoc false

  alias Shem.CLI.ConfigFile

  def list(path \\ nil) do
    case ConfigFile.read(path) do
      {:ok, config} ->
        config
        |> flatten_keys()
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.each(fn {k, v} ->
          IO.puts("  #{k} = #{v}")
        end)

      {:error, reason} ->
        IO.puts("Error reading config: #{inspect(reason)}")
    end
  end

  def get(dotkey, path \\ nil) do
    case ConfigFile.get(dotkey, path) do
      {:ok, value} -> IO.puts("#{dotkey} = #{value}")
      {:error, :not_found} -> IO.puts("#{dotkey}: not found")
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    end
  end

  def set(dotkey, value, path \\ nil) do
    case ConfigFile.set(dotkey, value, path) do
      :ok -> IO.puts("#{dotkey} = #{value}  ✓")
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp flatten_keys(map, prefix \\ "") do
    Enum.flat_map(map, fn {k, v} ->
      full_key = if prefix == "", do: k, else: "#{prefix}.#{k}"

      case v do
        v when is_map(v) -> flatten_keys(v, full_key)
        v -> [{full_key, v}]
      end
    end)
  end
end
