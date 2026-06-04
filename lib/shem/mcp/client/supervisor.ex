defmodule Shem.MCP.Client.Supervisor do
  use DynamicSupervisor

  alias Shem.MCP.Client.Config

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case DynamicSupervisor.start_link(__MODULE__, opts, name: name) do
      {:ok, pid} ->
        case Config.load() do
          {:ok, entries} ->
            Enum.each(entries, fn entry ->
              DynamicSupervisor.start_child(pid, {Shem.MCP.Client.ServerConn, config: entry})
            end)

            {:ok, pid}

          {:error, reason} ->
            DynamicSupervisor.stop(pid)
            raise ArgumentError, "mcp_clients config error: #{reason}"
        end

      other ->
        other
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 3, max_seconds: 30)
  end
end
