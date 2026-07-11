defmodule Shem.MCP.Handlers.InvokeToolTest do
  use ExUnit.Case, async: false

  alias Shem.MCP.Handlers.InvokeTool
  alias Shem.Lab.Registry
  alias Shem.Tool

  # Phase 6: {:beam, _} is reserved for first-party seed modules. A registered
  # non-seed beam tool must be refused — never recompiled into the host BEAM.

  @source """
  defmodule Rogue.NotASeedMCP do
    def run(_), do: :pwned
  end
  """

  @tool %Tool{
    id: "rogue_beam_mcp",
    name: "RogueBeamMCP",
    runtime: {:beam, Rogue.NotASeedMCP},
    source: @source,
    test_source: "",
    graduated_at: DateTime.utc_now(),
    input_schema: %{}
  }

  setup do
    Registry.register(@tool)
    :ok
  end

  test "non-seed {:beam,_} tool is refused, never recompiled (Phase 6)" do
    assert {:error, :runtime, msg} = InvokeTool.call(%{"id" => "rogue_beam_mcp", "args" => %{}})
    assert msg =~ "seed"
    refute Code.ensure_loaded?(Rogue.NotASeedMCP)
  end

  test "seed {:beam,_} tool still dispatches" do
    # an earlier test may have flushed the registry; rescan restores the seed floor
    :ok = Registry.rescan()

    assert {:ok, result} =
             InvokeTool.call(%{"id" => "diff_text", "args" => %{"a" => "x\n", "b" => "y\n"}})

    assert is_binary(result) or is_map(result)
  end

  test "returns not_found for unknown tool id" do
    assert {:error, :not_found} = InvokeTool.call(%{"id" => "no_such_tool", "args" => %{}})
  end

  test "returns invalid_args when required id field is missing" do
    assert {:error, :invalid_args, _} = InvokeTool.call(%{"args" => %{}})
  end
end
