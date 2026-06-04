defmodule Shem.MCP.Handlers.ListToolsTest do
  use ExUnit.Case, async: false

  alias Shem.MCP.Handlers.ListTools
  alias Shem.Lab.Registry
  alias Shem.Tool

  @tool %Tool{
    id: "lt_tool_1",
    name: "LtTool1",
    module: LtTool1,
    source: "defmodule LtTool1 do\n  def run(_args), do: :ok\nend",
    test_source: "",
    graduated_at: DateTime.utc_now(),
    input_schema: %{"x" => %{"type" => "integer"}}
  }

  test "returns empty list when no tools are registered" do
    assert {:ok, []} = ListTools.call(%{})
  end

  test "returns tool summaries for registered tools" do
    Registry.register(@tool)
    {:ok, tools} = ListTools.call(%{})
    found = Enum.find(tools, &(&1["id"] == "lt_tool_1"))
    assert found["name"] == "LtTool1"
    assert found["input_schema"] == %{"x" => %{"type" => "integer"}}
  end
end
