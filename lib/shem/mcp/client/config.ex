defmodule Shem.MCP.Client.Config do
  @spec load() :: {:ok, [map()]} | {:error, String.t()}
  def load do
    Application.get_env(:shem, :mcp_clients, [])
    |> validate_all()
  end

  defp validate_all(entries) do
    case Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case validate(entry) do
        :ok -> {:cont, {:ok, [entry | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end) do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  defp validate(%{name: n, cmd: c, args: a})
       when is_binary(n) and is_binary(c) and is_list(a),
       do: :ok

  defp validate(entry),
    do: {:error, "invalid mcp_clients entry: #{inspect(entry)}"}
end
