defmodule Shem.MCP.SchemaTest do
  use ExUnit.Case, async: true

  alias Shem.MCP.Schema

  @schema %{
    "source" => %{"type" => "string"},
    "count"  => %{"type" => "integer"},
    "flag"   => %{"type" => "boolean", "required" => false}
  }

  test "valid args with all fields pass through" do
    args = %{"source" => "foo", "count" => 3, "flag" => true}
    assert {:ok, ^args} = Schema.validate(args, @schema)
  end

  test "valid args without optional field pass through" do
    args = %{"source" => "foo", "count" => 3}
    assert {:ok, ^args} = Schema.validate(args, @schema)
  end

  test "missing required field returns error" do
    args = %{"count" => 3}
    assert {:error, :invalid_args, details} = Schema.validate(args, @schema)
    assert details =~ "source"
  end

  test "wrong type returns error" do
    args = %{"source" => 42, "count" => 3}
    assert {:error, :invalid_args, details} = Schema.validate(args, @schema)
    assert details =~ "source"
  end

  test "empty schema accepts any args" do
    assert {:ok, %{"anything" => "goes"}} = Schema.validate(%{"anything" => "goes"}, %{})
  end
end
