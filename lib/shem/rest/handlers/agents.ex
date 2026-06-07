defmodule Shem.REST.Handlers.Agents do
  # Stub — replaced by Task 3
  use Plug.Router
  plug :match
  plug :dispatch
  match _ do
    send_resp(conn, 501, "not implemented")
  end
end
