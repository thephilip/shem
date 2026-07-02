defmodule Shem.REST.Handlers.Tools do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    tools =
      Shem.Lab.Registry.all()
      |> Enum.map(fn t ->
        %{id: t.id, description: t.metadata["description"], schema: t.input_schema}
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{tools: tools}))
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end
end
