defmodule Shem.Lab.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.Workspace
  alias Shem.Tool

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir, System.tmp_dir!())
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  test "messy_path/1 returns a path ending in messy/<id>.ex" do
    assert Workspace.messy_path("my_tool") |> String.ends_with?("messy/my_tool.ex")
  end

  test "graduated_path/1 returns a path ending in graduated/<id>.ex" do
    assert Workspace.graduated_path("my_tool") |> String.ends_with?("graduated/my_tool.ex")
  end

  test "graduate/1 writes tool.source to graduated/<id>.ex and returns :ok" do
    tool = %Tool{
      id: "adder_v1",
      name: "Adder",
      runtime: {:beam, Adder},
      source: "defmodule Adder do\n  def add(a, b), do: a + b\nend",
      test_source: "",
      graduated_at: DateTime.utc_now()
    }

    assert :ok = Workspace.graduate(tool)
    assert File.read!(Workspace.graduated_path("adder_v1")) == tool.source
  end

  test "list_graduated/0 returns [] when no tools are graduated" do
    assert Workspace.list_graduated() == []
  end

  test "list_graduated/0 returns [{id, json_path}] tuples after graduation" do
    tool = %Tool{
      id: "multiplier_v1",
      name: "Multiplier",
      runtime: {:beam, Multiplier},
      source: "defmodule Multiplier do\n  def mul(a, b), do: a * b\nend",
      test_source: "",
      graduated_at: DateTime.utc_now()
    }

    Workspace.graduate(tool)
    assert [{"multiplier_v1", path}] = Workspace.list_graduated()
    assert String.ends_with?(path, "graduated/multiplier_v1.json")
  end

  test "graduate/1 writes a companion .json manifest with metadata" do
    tool = %Tool{
      id: "manifest_test_tool",
      name: "ManifestTestTool",
      runtime: {:beam, ManifestTestTool},
      source: "defmodule ManifestTestTool do\n  def run(_), do: :ok\nend",
      test_source: "test source here",
      graduated_at: ~U[2026-06-16 12:00:00Z],
      metadata: %{"description" => "adds things", "schema" => %{"type" => "object"}}
    }

    assert :ok = Workspace.graduate(tool)

    manifest_path = Workspace.manifest_path("manifest_test_tool")
    assert File.exists?(manifest_path)

    manifest = manifest_path |> File.read!() |> Jason.decode!()
    assert manifest["id"] == "manifest_test_tool"
    assert manifest["name"] == "ManifestTestTool"
    assert manifest["language"] == "elixir"
    assert manifest["description"] == "adds things"
    assert manifest["test_source"] == "test source here"
  end

  test "runtime_path/2 returns absolute path with correct extension for the language" do
    py_path = Workspace.runtime_path("my_tool", "python")
    assert String.ends_with?(py_path, "graduated/my_tool_runtime.py")
    assert Path.type(py_path) == :absolute

    js_path = Workspace.runtime_path("my_tool", "javascript")
    assert String.ends_with?(js_path, "graduated/my_tool_runtime.ts")
    assert Path.type(js_path) == :absolute
  end

  test "graduate writes a Deno runtime wrapper for a javascript :port tool" do
    id = "js_demo_#{System.unique_integer([:positive])}"
    rt = Shem.Lab.Workspace.runtime_path(id, "javascript")
    assert String.ends_with?(rt, "_runtime.ts")

    tool = %Shem.Tool{
      id: id, name: "JsDemo", runtime: {:port, rt},
      source: "function run(a){ return a }", test_source: "",
      graduated_at: DateTime.utc_now(),
      metadata: %{"language" => "javascript"}
    }

    :ok = Shem.Lab.Workspace.graduate(tool)
    assert File.read!(rt) =~ "Deno.stdin.readable"
  end
end
