defmodule Shem.REST.Handlers.Presets do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    presets =
      Shem.Agent.Preset.all()
      |> Enum.map(fn p ->
        %{
          name: p.name,
          description: p.system_prompt,
          deletable: p.source == :dynamic
        }
      end)

    send_json(conn, 200, presets)
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
