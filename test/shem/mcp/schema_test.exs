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

  describe "validate_input/2 (JSON-Schema-shaped tool schemas)" do
    @json_schema %{
      "type" => "object",
      "properties" => %{
        "n" => %{"type" => "integer"},
        "label" => %{"type" => "string"},
        "opts" => %{"type" => "object"}
      },
      "required" => ["n"]
    }

    test "valid args pass" do
      args = %{"n" => 3, "label" => "x", "opts" => %{}}
      assert {:ok, ^args} = Schema.validate_input(args, @json_schema)
    end

    test "missing required property errors" do
      assert {:error, :invalid_args, msg} = Schema.validate_input(%{"label" => "x"}, @json_schema)
      assert msg =~ "n"
    end

    test "wrong type errors" do
      assert {:error, :invalid_args, msg} =
               Schema.validate_input(%{"n" => "three"}, @json_schema)

      assert msg =~ "integer"
    end

    test "non-required properties may be omitted" do
      assert {:ok, _} = Schema.validate_input(%{"n" => 1}, @json_schema)
    end

    test "empty and malformed schemas pass anything through" do
      assert {:ok, _} = Schema.validate_input(%{"whatever" => 1}, %{})
      assert {:ok, _} = Schema.validate_input(%{"whatever" => 1}, nil)
      assert {:ok, _} = Schema.validate_input(%{"whatever" => 1}, %{"properties" => "junk"})
      # atom-keyed / nonconforming property specs are skipped, not crashed on
      assert {:ok, _} = Schema.validate_input(%{}, %{"properties" => %{"n" => "integer"}})
    end
  end
end
