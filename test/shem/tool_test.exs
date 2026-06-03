defmodule Shem.ToolTest do
  use ExUnit.Case, async: true

  alias Shem.Tool

  test "can be constructed with all required fields" do
    tool = %Tool{
      id: "parse_csv_v1",
      name: "ParseCsv",
      module: ParseCsv,
      source: "defmodule ParseCsv do end",
      test_source: "defmodule ParseCsvTest do def run, do: :ok end",
      graduated_at: ~U[2026-06-03 00:00:00Z]
    }

    assert tool.id == "parse_csv_v1"
    assert tool.module == ParseCsv
    assert tool.constraints == []
    assert tool.metadata == %{}
  end

  test "raises if a required field is missing" do
    assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
      struct!(Tool, %{id: "x"})
    end
  end

  test "defaults input_schema to empty map" do
    tool = %Shem.Tool{
      id: "foo",
      name: "Foo",
      module: Foo,
      source: "defmodule Foo do\nend",
      test_source: "",
      graduated_at: DateTime.utc_now()
    }
    assert tool.input_schema == %{}
  end

  test "accepts a non-empty input_schema" do
    tool = %Shem.Tool{
      id: "bar",
      name: "Bar",
      module: Bar,
      source: "defmodule Bar do\nend",
      test_source: "",
      graduated_at: DateTime.utc_now(),
      input_schema: %{"n" => %{"type" => "integer"}}
    }
    assert tool.input_schema == %{"n" => %{"type" => "integer"}}
  end
end
