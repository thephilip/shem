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

  defp format(config) do
    llm = Map.get(config, "llm", %{})
    default = Map.get(llm, "default", %{})
    server = Map.get(config, "server", %{})
    executor = Map.get(config, "executor", %{})

    llm_section =
      if Enum.empty?(default) do
        ""
      else
        """
        llm:
          default:
            backend: #{format_value(Map.get(default, "backend", "anthropic"))}
            model: #{format_value(Map.get(default, "model", ""))}
            api_key: #{format_value(Map.get(default, "api_key", ""))}
            url: #{format_value(Map.get(default, "url", ""))}
        """
      end

    server_section =
      if Enum.empty?(server) do
        ""
      else
        """
        server:
          port: #{format_value(Map.get(server, "port", 4000))}
          host: #{format_value(Map.get(server, "host", "127.0.0.1"))}
        """
      end

    executor_section =
      if Enum.empty?(executor) do
        ""
      else
        """
        executor:
          backend: #{format_value(Map.get(executor, "backend", "auto"))}
          image: #{format_value(Map.get(executor, "image", "debian:12-slim"))}
        """
      end

    tui_section =
      case Map.get(config, "tui") do
        nil -> ""
        value -> "tui: #{format_value(value)}\n"
      end

    data_dir_section =
      case Map.get(config, "data_dir") do
        nil -> ""
        value -> "data_dir: #{format_value(value)}\n"
      end

    [llm_section, server_section, executor_section, tui_section, data_dir_section]
    |> Enum.filter(&(String.trim(&1) != ""))
    |> Enum.join("\n")
  end

  defp format_value(value) when is_binary(value) do
    "\"#{value}\""
  end

  defp format_value(value) do
    to_string(value)
  end
end
