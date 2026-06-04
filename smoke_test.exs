# Smoke test: Shem.MCP.Client against @modelcontextprotocol/server-filesystem
#
# Usage: mix run smoke_test.exs
#
# Overrides config to disable TUI, enable MCP, and wire in the filesystem server.

# start_tui: false is set via SHEM_NO_TUI=1 in runtime.exs (before app starts)
Application.put_env(:shem, :start_mcp, true)
Application.put_env(:shem, :mcp_port, 4000)
Application.put_env(:shem, :mcp_client_timeout_ms, 10_000)
Application.put_env(:shem, :mcp_clients, [
  %{name: "filesystem", cmd: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]}
])

# Restart the client supervisor with the new config (MCP server, TUI already gated by runtime.exs)
Supervisor.terminate_child(Shem.Supervisor, Shem.MCP.Client.Supervisor)
Supervisor.delete_child(Shem.Supervisor, Shem.MCP.Client.Supervisor)
{:ok, _} = Supervisor.start_child(Shem.Supervisor, Shem.MCP.Client.Supervisor)

IO.puts("\n=== Shem MCP Client Smoke Test ===\n")

# Give the ServerConn time to complete the MCP handshake
IO.puts("Waiting for MCP handshake...")
:timer.sleep(3_000)

# 1. connected_servers/0
IO.puts("\n--- connected_servers/0 ---")
servers = Shem.MCP.Client.connected_servers()
IO.inspect(servers, label: "servers")

case Enum.find(servers, &(&1.name == "filesystem" and &1.status == :ready)) do
  nil ->
    IO.puts("❌ filesystem server not :ready — status: #{inspect(Enum.map(servers, & &1.status))}")
  _s ->
    IO.puts("✅ filesystem server connected and ready")
end

# 2. list_tools/1
IO.puts("\n--- list_tools/1 ---")
case Shem.MCP.Client.list_tools("filesystem") do
  {:ok, tools} ->
    IO.puts("✅ #{length(tools)} tools discovered:")
    Enum.each(tools, fn t -> IO.puts("   - #{t["name"]}") end)
  {:error, reason} ->
    IO.puts("❌ list_tools failed: #{inspect(reason)}")
end

# 3. call/3 — list directory contents
IO.puts("\n--- call/3: read_file on a known path ---")
case Shem.MCP.Client.call("filesystem", "list_directory", %{"path" => "/tmp"}) do
  {:ok, result} ->
    IO.puts("✅ list_directory /tmp succeeded:")
    IO.inspect(result, limit: 5)
  {:error, reason} ->
    IO.puts("❌ list_directory failed: #{inspect(reason)}")
end

# 4. call/3 — unknown tool (MCP tool error path)
# Per MCP spec: tool errors are returned as {:ok, %{"isError" => true, ...}},
# not as JSON-RPC errors. The client correctly reflects this.
IO.puts("\n--- call/3: unknown tool (MCP isError path) ---")
case Shem.MCP.Client.call("filesystem", "nonexistent_tool", %{}) do
  {:ok, %{"isError" => true} = result} ->
    [%{"text" => msg}] = result["content"]
    IO.puts("✅ nonexistent_tool returned MCP tool error (isError: true): #{msg}")
  {:ok, result} ->
    IO.puts("⚠️  unexpected success without isError: #{inspect(result)}")
  {:error, reason} ->
    IO.puts("⚠️  protocol error (expected MCP tool error): #{inspect(reason)}")
end

# 5. call/3 — unknown server
IO.puts("\n--- call/3: unknown server ---")
case Shem.MCP.Client.call("ghost-server", "some_tool", %{}) do
  {:error, :unknown_server} ->
    IO.puts("✅ unknown server correctly returned {:error, :unknown_server}")
  other ->
    IO.puts("❌ unexpected: #{inspect(other)}")
end

IO.puts("\n=== Smoke test complete ===\n")
