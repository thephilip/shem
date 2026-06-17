defmodule Shem.ToolTest do
  use ExUnit.Case, async: true

  alias Shem.Tool

  test "can be constructed with all required fields using runtime:" do
    tool = %Tool{
      id: "parse_csv_v1",
      name: "ParseCsv",
      runtime: {:beam, ParseCsv},
      source: "defmodule ParseCsv do end",
      test_source: "defmodule ParseCsvTest do def run, do: :ok end",
      graduated_at: ~U[2026-06-03 00:00:00Z]
    }

    assert tool.id == "parse_csv_v1"
    assert tool.runtime == {:beam, ParseCsv}
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
      runtime: {:beam, Foo},
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
      runtime: {:beam, Bar},
      source: "defmodule Bar do\nend",
      test_source: "",
      graduated_at: DateTime.utc_now(),
      input_schema: %{"n" => %{"type" => "integer"}}
    }
    assert tool.input_schema == %{"n" => %{"type" => "integer"}}
  end

  test "accepts python port runtime" do
    tool = %Shem.Tool{
      id: "py_tool",
      name: "PyTool",
      runtime: {:port, "/abs/path/py_tool_runtime.py"},
      source: "def run(args): return args",
      test_source: "",
      graduated_at: DateTime.utc_now()
    }
    assert tool.runtime == {:port, "/abs/path/py_tool_runtime.py"}
  end
end
