defmodule Shem.Lab.GraduationGate.PythonTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.GraduationGate.Python

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir, System.tmp_dir!())
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  describe "extract_name/1" do
    test "returns name from # name: comment" do
      source = "# name: MyPyTool\ndef run(args):\n    return args"
      assert Python.extract_name(source) == "MyPyTool"
    end

    test "returns class name (stripped) when present" do
      source = "class DataLoader:\n    pass\ndef run(args):\n    return args"
      assert Python.extract_name(source) == "DataLoader"
    end

    test "falls back to python_tool when no name hint" do
      source = "def run(args):\n    return args"
      assert Python.extract_name(source) == "python_tool"
    end

    test "returns python_tool when no run function present" do
      source = "def not_run(args):\n    return args"
      assert Python.extract_name(source) == "python_tool"
    end
  end

  describe "unique_id/1" do
    test "returns 12-char hex string" do
      id = Python.unique_id("some source")
      assert String.length(id) == 12
      assert id =~ ~r/^[0-9a-f]+$/
    end

    test "same source produces same id (idempotent)" do
      assert Python.unique_id("abc") == Python.unique_id("abc")
    end

    test "different source produces different id" do
      refute Python.unique_id("abc") == Python.unique_id("def")
    end
  end

  @tag :python_integration
  test "graduates a valid Python tool via pytest in container" do
    source = """
    def run(args):
        return {"result": args.get("n", 0) * 2}
    """

    test_source = """
    import sys
    sys.path.insert(0, '.')
    from tool import run

    def test_doubles():
        assert run({"n": 5}) == {"result": 10}

    def test_zero():
        assert run({}) == {"result": 0}
    """

    opts = [description: "doubles n", schema: %{"n" => %{"type" => "integer"}}]

    assert {:ok, tool} = Python.run(source, test_source, opts)
    assert match?({:port, _}, tool.runtime)
    assert tool.metadata["description"] == "doubles n"

    {:port, runtime_path} = tool.runtime
    assert File.exists?(runtime_path)
  end

  @tag :python_integration
  test "returns {:error, :gate, _} when pytest fails" do
    source = "def run(args):\n    return args"
    test_source = """
    from tool import run
    def test_always_fails():
        assert False, "intentional failure"
    """

    assert {:error, :gate, _reason} = Python.run(source, test_source, [])
  end
end
