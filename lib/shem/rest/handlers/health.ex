defmodule Shem.REST.Handlers.Health do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    version = Application.spec(:shem, :vsn) |> to_string()
    port = Application.get_env(:shem, :mcp_port, 4000)
    tui = Application.get_env(:shem, :start_tui, true)

    active_agents =
      try do
        Horde.DynamicSupervisor.which_children(Shem.AgentSupervisor) |> length()
      catch
        _, _ -> 0
      end

    send_json(conn, 200, %{
      version: version,
      port: port,
      tui: tui,
      active_agents: active_agents,
      host: Application.get_env(:shem, :mcp_host, "127.0.0.1"),
      cluster_size: length(Shem.Cluster.members())
    })
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
