defmodule Shem.MCP.Client.Supervisor do
  use DynamicSupervisor

  alias Shem.MCP.Client.Config

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case Config.load() do
      {:ok, entries} ->
        case DynamicSupervisor.start_link(__MODULE__, opts, name: name) do
          {:ok, pid} ->
            Enum.each(entries, fn entry ->
              DynamicSupervisor.start_child(pid, {Shem.MCP.Client.ServerConn, config: entry})
            end)
            {:ok, pid}

          other ->
            other
        end

      {:error, reason} ->
        {:error, {:config_error, reason}}
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 3, max_seconds: 30)
  end
end
