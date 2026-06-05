# test/shem/agent/turn_test.exs
defmodule Shem.Agent.TurnTest do
  use ExUnit.Case, async: true

  alias Shem.Agent.Turn

  describe "parse_response/1" do
    test "returns {:done, content} when no JSON tool call present" do
      assert {:done, "The answer is 42."} = Turn.parse_response("The answer is 42.")
    end

    test "extracts a single tool call embedded in prose" do
      content = ~s(I'll write a tool.\n{"tool": "write_tool", "args": {"name": "Foo"}}\nDone.)
      assert {:tool_calls, [call], ^content} = Turn.parse_response(content)
      assert call == %{tool: "write_tool", args: %{"name" => "Foo"}}
    end

    test "extracts multiple tool calls" do
      content = ~s({"tool": "run_code", "args": {"source": "x"}}\n{"tool": "list_tools", "args": {}})
      assert {:tool_calls, [c1, c2], ^content} = Turn.parse_response(content)
      assert c1.tool == "run_code"
      assert c2.tool == "list_tools"
    end

    test "ignores non-tool JSON objects" do
      content = ~s(Here is some JSON: {"key": "value"}. No tool call.)
      assert {:done, ^content} = Turn.parse_response(content)
    end

    test "handles tool call with no args key — defaults to empty map" do
      content = ~s({"tool": "list_tools"})
      assert {:tool_calls, [%{tool: "list_tools", args: %{}}], ^content} = Turn.parse_response(content)
    end

    test "returns {:done, content} on empty string" do
      assert {:done, ""} = Turn.parse_response("")
    end

    test "handles nested args object" do
      content = ~s({"tool": "write_tool", "args": {"name": "T", "source": "defmodule T do\\nend"}})
      assert {:tool_calls, [call], _} = Turn.parse_response(content)
      assert call.args["source"] =~ "defmodule"
    end
  end
end
