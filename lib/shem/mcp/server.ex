defmodule Shem.MCP.Server do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    port = Application.get_env(:shem, :mcp_port, 4000)
    host = Application.get_env(:shem, :mcp_host, "127.0.0.1") |> parse_ip()

    children = [
      Shem.MCP.SessionRegistry,
      {Bandit, plug: Shem.HTTP.Router, port: port, ip: host, scheme: :http}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp parse_ip(str) when is_binary(str) do
    str
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  defp parse_ip(tuple) when is_tuple(tuple), do: tuple
end
