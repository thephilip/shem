defmodule Shem.HTTP.Router do
  use Plug.Router

  plug Shem.HTTP.HostGuard

  plug Plug.Static,
    at: "/",
    from: :shem,
    gzip: false,
    # Revalidate via ETag on every load (304 when unchanged) so edited assets
    # are never served stale — no hard-refresh dance during development.
    cache_control_for_etags: "no-cache",
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

  get "/metrics" do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, Shem.Telemetry.prometheus_text())
  end

  get "/timeline" do
    path = Application.app_dir(:shem, "priv/static/timeline.html")
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
