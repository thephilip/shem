defmodule Shem.MCP.Handlers.ExecuteCodeTest do
  use ExUnit.Case, async: false

  alias Shem.MCP.Handlers.ExecuteCode

  test "executes source that defines a module with run/0 and returns result" do
    source = """
    defmodule ExecTest1 do
      def run(), do: {:ok, 42}
    end
    """
    assert {:ok, {:ok, 42}} = ExecuteCode.call(%{"source" => source})
  end

  test "returns compile error for invalid Elixir source" do
    source = "this is not valid elixir !!!"
    assert {:error, :compile, reason} = ExecuteCode.call(%{"source" => source})
    assert is_binary(reason)
  end

  test "returns runtime error when run/0 raises" do
    source = """
    defmodule ExecTest2 do
      def run(), do: raise "boom"
    end
    """
    assert {:error, :runtime, _reason} = ExecuteCode.call(%{"source" => source})
  end

  test "returns missing_source error when source key is absent" do
    assert {:error, :invalid_args, _} = ExecuteCode.call(%{})
  end
end
