defmodule Shem.MCP.Server do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    port = Application.get_env(:shem, :mcp_port, 4000)
    host = Application.get_env(:shem, :mcp_host, "127.0.0.1") |> parse_ip()

    unless loopback?(host) or Application.get_env(:shem, :auth_token) do
      raise "Shem refuses to bind #{inspect(host)} without auth.token — " <>
              "run `shem setup`, or: shem config set auth.token $(openssl rand -base64 32)"
    end

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

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
