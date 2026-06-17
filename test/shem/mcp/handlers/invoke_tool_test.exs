defmodule Shem.MCP.Handlers.InvokeToolTest do
  use ExUnit.Case, async: false

  alias Shem.MCP.Handlers.InvokeTool
  alias Shem.Lab.Registry
  alias Shem.Tool

  @source """
  defmodule InvokeTarget1 do
    def run(args), do: {:ok, Map.get(args, "n", 0) * 2}
  end
  """

  @tool %Tool{
    id: "invoke_target_1",
    name: "InvokeTarget1",
    runtime: {:beam, InvokeTarget1},
    source: @source,
    test_source: "",
    graduated_at: DateTime.utc_now(),
    input_schema: %{"n" => %{"type" => "integer"}}
  }

  setup do
    Registry.register(@tool)
    :ok
  end

  test "loads module and calls run/1 with args, returning result" do
    assert {:ok, {:ok, 84}} =
             InvokeTool.call(%{"id" => "invoke_target_1", "args" => %{"n" => 42}})
  end

  test "second call reuses already-loaded module" do
    InvokeTool.call(%{"id" => "invoke_target_1", "args" => %{"n" => 1}})
    assert {:ok, {:ok, 4}} = InvokeTool.call(%{"id" => "invoke_target_1", "args" => %{"n" => 2}})
  end

  test "returns not_found for unknown tool id" do
    assert {:error, :not_found} = InvokeTool.call(%{"id" => "no_such_tool", "args" => %{}})
  end

  test "returns invalid_args when required id field is missing" do
    assert {:error, :invalid_args, _} = InvokeTool.call(%{"args" => %{}})
  end
end
