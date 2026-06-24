defmodule Shem.REST.Router do
  use Plug.Router

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["*/*"]

  plug :match
  plug :dispatch

  forward "/agents", to: Shem.REST.Handlers.Agents
  forward "/presets", to: Shem.REST.Handlers.Presets
  forward "/routes", to: Shem.REST.Handlers.Routes
  forward "/sessions", to: Shem.REST.Handlers.Sessions
  forward "/health", to: Shem.REST.Handlers.Health
  forward "/cluster", to: Shem.REST.Handlers.Cluster
  forward "/packs", to: Shem.REST.Handlers.Packs

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end
end
