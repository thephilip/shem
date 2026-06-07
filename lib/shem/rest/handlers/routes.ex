defmodule Shem.REST.Handlers.Routes do
  # Stub — replaced by Task 5
  use Plug.Router
  plug :match
  plug :dispatch
  match _ do
    send_resp(conn, 501, "not implemented")
  end
end
