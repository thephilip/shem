defmodule Shem.MCP.Handlers.ListToolsTest do
  use ExUnit.Case, async: false

  alias Shem.MCP.Handlers.ListTools
  alias Shem.Lab.Registry
  alias Shem.Tool

  @tool %Tool{
    id: "lt_tool_1",
    name: "LtTool1",
    runtime: {:beam, LtTool1},
    source: "defmodule LtTool1 do\n  def run(_args), do: :ok\nend",
    test_source: "",
    graduated_at: DateTime.utc_now(),
    input_schema: %{"x" => %{"type" => "integer"}}
  }

  test "returns a nudge map when no tools are graduated" do
    Registry.flush()
    assert {:ok, %{"tools" => [], "note" => note}} = ListTools.call(%{})
    assert note =~ "graduate_tool"
  end

  test "returns tool summaries for registered tools" do
    Registry.register(@tool)
    {:ok, tools} = ListTools.call(%{})
    assert is_list(tools)
    found = Enum.find(tools, &(&1["id"] == "lt_tool_1"))
    assert found["name"] == "LtTool1"
    assert found["input_schema"] == %{"x" => %{"type" => "integer"}}
  end
end
