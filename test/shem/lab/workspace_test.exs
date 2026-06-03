defmodule Shem.Lab.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.Workspace
  alias Shem.Tool

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir)
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
      module: Adder,
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

  test "list_graduated/0 returns [{id, path}] tuples after graduation" do
    tool = %Tool{
      id: "multiplier_v1",
      name: "Multiplier",
      module: Multiplier,
      source: "defmodule Multiplier do\n  def mul(a, b), do: a * b\nend",
      test_source: "",
      graduated_at: DateTime.utc_now()
    }

    Workspace.graduate(tool)
    assert [{"multiplier_v1", path}] = Workspace.list_graduated()
    assert String.ends_with?(path, "graduated/multiplier_v1.ex")
  end
end
