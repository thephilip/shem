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
    input_schema: %{"x" => %{"type" => "integer"}},
    metadata: %{"description" => "Seed-shaped tool."}
  }

  # Pack/graduated tools load from a manifest: schema lands in metadata, not
  # on the struct. This is the shape that listed as an unusable `{}`.
  @manifest_tool %Tool{
    id: "lt_tool_2",
    name: "browser",
    runtime: {:port, "/tmp/lt_tool_2"},
    source: "",
    test_source: "",
    graduated_at: DateTime.utc_now(),
    metadata: %{
      "description" => "Control a web browser: navigate, screenshot.",
      "schema" => %{"url" => %{"type" => "string"}}
    }
  }

  test "returns a nudge map when no tools are graduated" do
    Registry.flush()
    assert {:ok, %{"tools" => [], "note" => note}} = ListTools.call(%{})
    assert note =~ "graduate_tool"
  end

  test "returns tool summaries for registered tools" do
    Registry.register(@tool)
    {:ok, %{"tools" => tools, "note" => note}} = ListTools.call(%{})
    found = Enum.find(tools, &(&1["id"] == "lt_tool_1"))
    assert found["name"] == "LtTool1"
    assert found["description"] == "Seed-shaped tool."
    assert found["input_schema"] == %{"x" => %{"type" => "integer"}}
    assert note =~ "invoke_tool"
  end

  test "surfaces description and schema for manifest-loaded tools" do
    Registry.register(@manifest_tool)
    {:ok, %{"tools" => tools}} = ListTools.call(%{})
    found = Enum.find(tools, &(&1["id"] == "lt_tool_2"))
    assert found["description"] =~ "Control a web browser"
    assert found["input_schema"] == %{"url" => %{"type" => "string"}}
  end
end
