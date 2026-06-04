defmodule Shem.MCP.Client.ConfigTest do
  use ExUnit.Case, async: true

  alias Shem.MCP.Client.Config

  test "load/0 returns empty list when no config present" do
    Application.put_env(:shem, :mcp_clients, [])
    assert {:ok, []} = Config.load()
  end

  test "load/0 returns valid entries unchanged" do
    entry = %{name: "fs", cmd: "npx", args: ["-y", "server"]}
    Application.put_env(:shem, :mcp_clients, [entry])
    assert {:ok, [^entry]} = Config.load()
  after
    Application.put_env(:shem, :mcp_clients, [])
  end

  test "load/0 returns error for entry missing :name" do
    Application.put_env(:shem, :mcp_clients, [%{cmd: "npx", args: []}])
    assert {:error, msg} = Config.load()
    assert msg =~ "invalid"
  after
    Application.put_env(:shem, :mcp_clients, [])
  end

  test "load/0 returns error for entry missing :cmd" do
    Application.put_env(:shem, :mcp_clients, [%{name: "fs", args: []}])
    assert {:error, msg} = Config.load()
    assert msg =~ "invalid"
  after
    Application.put_env(:shem, :mcp_clients, [])
  end

  test "load/0 returns error for entry missing :args" do
    Application.put_env(:shem, :mcp_clients, [%{name: "fs", cmd: "npx"}])
    assert {:error, msg} = Config.load()
    assert msg =~ "invalid"
  after
    Application.put_env(:shem, :mcp_clients, [])
  end

  test "load/0 returns error when :name is not a binary" do
    Application.put_env(:shem, :mcp_clients, [%{name: :fs, cmd: "npx", args: []}])
    assert {:error, _} = Config.load()
  after
    Application.put_env(:shem, :mcp_clients, [])
  end

  test "load/0 returns error when :args is not a list" do
    Application.put_env(:shem, :mcp_clients, [%{name: "fs", cmd: "npx", args: "bad"}])
    assert {:error, _} = Config.load()
  after
    Application.put_env(:shem, :mcp_clients, [])
  end
end
