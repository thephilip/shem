defmodule Shem.REST.Router do
  # Stub — Task 2 will replace this with the real REST router implementation.
  use Plug.Router

  plug :match
  plug :dispatch

  match _ do
    send_resp(conn, 404, "not found")
  end
end
