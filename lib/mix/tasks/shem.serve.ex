defmodule Mix.Tasks.Shem.Serve do
  use Mix.Task

  @shortdoc "Run Shem headless (MCP/REST server, no TUI)"
  @moduledoc """
  Boots Shem without the TUI or cluster — a plain HTTP server exposing the
  MCP endpoint (SSE at /mcp/sse) and REST API (/api) on `:mcp_port` (default 4000).

  Wire it into Claude Code:

      mix shem.serve
      claude mcp add --transport sse shem http://127.0.0.1:4000/mcp/sse
  """

  @impl true
  def run(_args) do
    Application.put_env(:shem, :start_tui, false)
    Application.put_env(:shem, :start_cluster, false)
    {:ok, _} = Application.ensure_all_started(:shem)

    port = Application.get_env(:shem, :mcp_port, 4000)
    Mix.shell().info("Shem serving — MCP: http://127.0.0.1:#{port}/mcp/sse  REST: http://127.0.0.1:#{port}/api")
    Process.sleep(:infinity)
  end
end
