defmodule Shem.MCP.ServerBootTest do
  use ExUnit.Case, async: false

  test "non-loopback bind without auth_token raises at init" do
    Application.put_env(:shem, :mcp_host, "0.0.0.0")
    on_exit(fn -> Application.delete_env(:shem, :mcp_host) end)

    assert_raise RuntimeError, ~r/auth\.token/, fn ->
      Shem.MCP.Server.init([])
    end
  end

  test "non-loopback bind with token is accepted" do
    Application.put_env(:shem, :mcp_host, "0.0.0.0")
    Application.put_env(:shem, :auth_token, "sekrit")

    on_exit(fn ->
      Application.delete_env(:shem, :mcp_host)
      Application.delete_env(:shem, :auth_token)
    end)

    assert {:ok, _} = Shem.MCP.Server.init([])
  end

  test "loopback without token is fine" do
    assert {:ok, _} = Shem.MCP.Server.init([])
  end
end
