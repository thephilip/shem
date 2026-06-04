defmodule Shem.MCP.Server do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    port = Application.get_env(:shem, :mcp_port, 4000)

    children = [
      Shem.MCP.SessionRegistry,
      {Bandit, plug: Shem.MCP.Router, port: port, ip: {127, 0, 0, 1}, scheme: :http}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
