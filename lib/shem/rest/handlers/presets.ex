defmodule Shem.REST.Handlers.Presets do
  use Plug.Router
  plug :match
  plug :dispatch
  match _ do
    send_resp(conn, 501, "not implemented")
  end
end
