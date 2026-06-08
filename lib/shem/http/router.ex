defmodule Shem.HTTP.Router do
  use Plug.Router

  plug Plug.Static,
    at: "/",
    from: :shem,
    gzip: false,
    only: ~w(alpine.min.js app.js)

  plug :match
  plug :dispatch

  forward "/api", to: Shem.REST.Router
  forward "/mcp", to: Shem.MCP.Router

  get "/" do
    path = Application.app_dir(:shem, "priv/static/index.html")
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, path)
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end
end
