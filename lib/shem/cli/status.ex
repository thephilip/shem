defmodule Shem.CLI.Status do
  @moduledoc false

  def run do
    Application.ensure_all_started(:req)
    port = detect_port()
    url = "http://#{detect_host()}:#{port}/api/health"

    version_line = "Shem v#{current_version()}"
    IO.puts("")
    IO.puts(version_line)
    IO.puts("")

    case Req.get(url, receive_timeout: 2_000, headers: auth_headers()) do
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

  # HostGuard exempts no route, so an unauthenticated probe of a healthy daemon
  # 401s and reads as "not running".
  defp auth_headers do
    case Shem.CLI.ConfigFile.get("auth.token") do
      {:ok, token} when is_binary(token) and token != "" ->
        [{"authorization", "Bearer #{token}"}]

      _ ->
        []
    end
  end

  # A LAN bind (server.host) is a healthy daemon that 127.0.0.1 can't see.
  defp detect_host do
    case Shem.CLI.ConfigFile.get("server.host") do
      {:ok, host} when is_binary(host) and host != "" -> host
      _ -> "127.0.0.1"
    end
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
