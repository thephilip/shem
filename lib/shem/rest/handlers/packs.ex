defmodule Shem.REST.Handlers.Packs do
  use Plug.Router

  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :match
  plug :dispatch

  get "/" do
    send_json(conn, 200, %{packs: Shem.Lab.Pack.list_packs()})
  end

  post "/" do
    repo = String.trim(conn.body_params["repo"] || "")
    path = conn.body_params["path"] || "."

    if repo == "" do
      send_json(conn, 422, %{error: "repo is required"})
    else
      case Shem.Lab.Pack.install(repo, path) do
        {:ok, result} -> send_json(conn, 201, result)
        {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
      end
    end
  end

  delete "/:name" do
    {:ok, result} = Shem.Lab.Pack.uninstall(name)
    send_json(conn, 200, result)
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
