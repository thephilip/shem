defmodule Shem.MCP.Client do
  alias Shem.MCP.Client.ServerConn

  @spec call(server :: String.t(), tool :: String.t(), args :: map(), opts :: keyword()) ::
          {:ok, any()} | {:error, any()}
  def call(server_name, tool_name, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Application.get_env(:shem, :mcp_client_timeout_ms, 5_000))

    case lookup_conn(server_name) do
      {:ok, pid} ->
        # Add buffer so ServerConn's internal timeout fires before GenServer call times out
        GenServer.call(pid, {:call, tool_name, args}, timeout + 500)

      {:error, :not_found} ->
        {:error, :unknown_server}
    end
  end

  @spec list_tools(server :: String.t()) :: {:ok, [map()]} | {:error, any()}
  def list_tools(server_name) do
    case lookup_conn(server_name) do
      {:ok, pid} -> GenServer.call(pid, :list_tools)
      {:error, :not_found} -> {:error, :unknown_server}
    end
  end

  @spec connected_servers() :: [%{name: String.t(), status: :ready | :connecting | :down}]
  def connected_servers do
    Registry.select(Shem.Registry, [
      {{{ServerConn, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.map(fn {name, pid} ->
      status =
        try do
          GenServer.call(pid, :status, 500)
        catch
          :exit, _ -> :down
        end

      %{name: name, status: status}
    end)
  end

  defp lookup_conn(name) do
    case Registry.lookup(Shem.Registry, {ServerConn, name}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
