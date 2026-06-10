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

  post "/" do
    name   = String.trim(conn.body_params["name"] || "")
    prompt = String.trim(conn.body_params["system_prompt"] || "")

    cond do
      name == "" or prompt == "" ->
        send_json(conn, 422, %{error: "name and system_prompt are required"})

      Enum.any?(Shem.Agent.Preset.all(), &(&1.name == name)) ->
        send_json(conn, 409, %{error: "preset already exists: #{name}"})

      true ->
        Shem.Agent.PresetStore.put(name, %{name: name, system_prompt: prompt})
        send_json(conn, 201, %{name: name, description: prompt, deletable: true})
    end
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
