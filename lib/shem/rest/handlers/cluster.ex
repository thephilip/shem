defmodule Shem.REST.Handlers.Cluster do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    nodes =
      Shem.Cluster.members()
      |> Enum.map(fn n ->
        %{node: Atom.to_string(n), agents: Shem.Cluster.agent_count(n), status: "up"}
      end)

    send_json(conn, 200, %{self: Atom.to_string(Node.self()), nodes: nodes})
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
