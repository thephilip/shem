defmodule Shem.CLI.Status do
  @moduledoc false

  def run do
    port = detect_port()
    url = "http://127.0.0.1:#{port}/api/health"

    version_line = "Shem v#{current_version()}"
    IO.puts("")
    IO.puts(version_line)
    IO.puts("")

    case Req.get(url, receive_timeout: 2_000) do
      {:ok, %{status: 200, body: body}} ->
        tui_label = if body["tui"], do: "on", else: "off (headless)"
        llm = Application.get_env(:shem, :llm_routes, %{})
        {backend, model} = format_llm(llm)

        IO.puts("  HTTP / MCP   ● running   #{body["host"]}:#{body["port"]}")
        IO.puts("  LLM backend  ● #{backend}  #{model}")
        IO.puts("  Agents        #{body["active_agents"]} active")
        IO.puts("  TUI           #{tui_label}")

      _ ->
        IO.puts("  ○ not running")
    end

    IO.puts("")
  end

  defp detect_port do
    case Shem.CLI.ConfigFile.get("server.port") do
      {:ok, port} when is_integer(port) -> port
      {:ok, port} -> String.to_integer(to_string(port))
      _ -> Application.get_env(:shem, :mcp_port, 4000)
    end
  end

  defp current_version do
    Application.spec(:shem, :vsn) |> to_string()
  end

  defp format_llm(routes) do
    case Map.get(routes, :default) do
      {backend, model} -> {to_string(backend), model}
      _ -> {"unconfigured", ""}
    end
  end
end
