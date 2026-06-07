defmodule Shem.REST.Handlers.Routes do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    routes =
      Shem.LLM.Router.all()
      |> Enum.into(%{}, fn {model_atom, {backend_key, model_string}} ->
        {Atom.to_string(model_atom), "#{backend_key}:#{model_string}"}
      end)

    send_json(conn, 200, routes)
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
