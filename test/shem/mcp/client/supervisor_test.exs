defmodule Shem.MCP.Client.SupervisorTest do
  use ExUnit.Case, async: true

  alias Shem.MCP.Client.Supervisor, as: ClientSup

  test "starts with no children when mcp_clients config is empty" do
    Application.put_env(:shem, :mcp_clients, [])

    {:ok, sup} = start_supervised({ClientSup, name: :test_client_sup_1})
    assert [] = DynamicSupervisor.which_children(sup)
  after
    Application.put_env(:shem, :mcp_clients, [])
  end

  test "returns error tuple on invalid config entry" do
    Application.put_env(:shem, :mcp_clients, [%{bad: :entry}])

    assert {:error, {{:config_error, msg}, _}} = start_supervised({ClientSup, name: :test_client_sup_bad})
    assert msg =~ "invalid"
  after
    Application.put_env(:shem, :mcp_clients, [])
  end
end
