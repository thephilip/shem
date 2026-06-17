defmodule Shem.MCP.Handlers.GraduateToolTest do
  use ExUnit.Case, async: false

  alias Shem.MCP.Handlers.GraduateTool

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir, System.tmp_dir!())
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  test "graduates a valid tool and returns the tool struct" do
    source = """
    defmodule GradHandlerTool1 do
      def run(args), do: {:ok, args}
    end
    """

    test_source = """
    defmodule GradHandlerTool1Test do
      def run do
        unless match?({:ok, _}, GradHandlerTool1.run(%{})), do: raise "broken"
        :ok
      end
    end
    """

    args = %{"source" => source, "test_source" => test_source}
    assert {:ok, tool} = GraduateTool.call(args)
    assert tool.id == "grad_handler_tool1"
    assert tool.runtime == {:beam, GradHandlerTool1}
  end

  test "accepts optional input_schema and stores it on the tool" do
    source = """
    defmodule GradHandlerTool2 do
      def run(args), do: {:ok, args}
    end
    """

    test_source = """
    defmodule GradHandlerTool2Test do
      def run do
        unless match?({:ok, _}, GradHandlerTool2.run(%{})), do: raise "broken"
        :ok
      end
    end
    """

    schema = %{"n" => %{"type" => "integer"}}
    args = %{"source" => source, "test_source" => test_source, "input_schema" => schema}
    assert {:ok, tool} = GraduateTool.call(args)
    assert tool.input_schema == schema
  end

  test "returns gate error when test source fails" do
    source = """
    defmodule GradHandlerTool3 do
      def run(args), do: {:ok, args}
    end
    """

    bad_test = """
    defmodule GradHandlerTool3Test do
      def run(), do: raise "deliberate failure"
    end
    """

    args = %{"source" => source, "test_source" => bad_test}
    assert {:error, :gate, _} = GraduateTool.call(args)
  end

  test "returns invalid_args error when source is missing" do
    test_source = """
    defmodule GradHandlerTool4Test do
      def run do
        :ok
      end
    end
    """

    assert {:error, :invalid_args, _} = GraduateTool.call(%{"test_source" => test_source})
  end
end
