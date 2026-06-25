defmodule Shem.Lab.RegistryTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.Registry
  alias Shem.Lab.Workspace
  alias Shem.Tool

  @tool %Tool{
    id: "greeter_v1",
    name: "Greeter",
    runtime: {:beam, Greeter},
    source: "defmodule Greeter do\n  def hi(name), do: \"Hello, \#{name}\"\nend",
    test_source: "",
    graduated_at: ~U[2026-06-03 00:00:00Z]
  }

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir, System.tmp_dir!())
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  test "lookup/1 returns {:error, :not_found} for an unknown id" do
    {:ok, pid} = start_supervised({Registry, [name: :test_registry_1]})
    assert {:error, :not_found} = GenServer.call(pid, {:lookup, "nonexistent"})
  end

  test "register/1 makes a tool findable via lookup/1" do
    {:ok, pid} = start_supervised({Registry, [name: :test_registry_2]})
    GenServer.call(pid, {:register, @tool})
    assert {:ok, @tool} = GenServer.call(pid, {:lookup, "greeter_v1"})
  end

  test "all/0 returns only seed tools when no graduated tools are registered" do
    {:ok, pid} = start_supervised({Registry, [name: :test_registry_3]})
    ids = GenServer.call(pid, :all) |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["diff_text", "extract_signatures", "graphify_query", "json_query"]
  end

  test "all/0 returns all registered tools" do
    {:ok, pid} = start_supervised({Registry, [name: :test_registry_4]})
    GenServer.call(pid, {:register, @tool})
    ids = GenServer.call(pid, :all) |> Enum.map(& &1.id)
    assert "greeter_v1" in ids
    assert "diff_text" in ids
    assert "json_query" in ids
    assert "graphify_query" in ids
  end

  test "boot scan loads tools pre-written to the graduated directory" do
    Workspace.graduate(@tool)
    {:ok, pid} = start_supervised({Registry, [name: :test_registry_5]})
    ids = GenServer.call(pid, :all) |> Enum.map(& &1.id)
    assert "greeter_v1" in ids
  end

  test "boot scan quarantines a graduated tool with unloadable source instead of crashing" do
    Workspace.graduate(@tool)
    # corrupt the source so extract_module fails — must not bring down the registry
    File.write!(Workspace.graduated_path(@tool.id), "not elixir at all")

    assert {:ok, pid} = start_supervised({Registry, [name: :test_registry_broken]})
    ids = GenServer.call(pid, :all) |> Enum.map(& &1.id)
    # corrupted graduated tool must be absent; seeds must still be present
    refute "greeter_v1" in ids
    assert "diff_text" in ids
    assert "json_query" in ids
    assert "graphify_query" in ids

    # the broken tool is moved aside (preserved, not deleted) so it stops
    # re-warning every boot and is no longer in the active graduated/ scan path
    broken_dir = Path.join(Path.dirname(Workspace.manifest_path(@tool.id)), ".broken")
    assert File.exists?(Path.join(broken_dir, "greeter_v1.json"))
    assert File.exists?(Path.join(broken_dir, "greeter_v1.ex"))
    refute File.exists?(Workspace.manifest_path(@tool.id))
    refute File.exists?(Workspace.graduated_path(@tool.id))
  end

  describe "lookup_by_name/1" do
    test "returns {:ok, tool} when a tool with that name exists" do
      source = """
      defmodule LookupByNameTool do
        def run(_args), do: :ok
      end
      """
      test_src = """
      defmodule LookupByNameToolTest do
        def run, do: :ok
      end
      """
      {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
      assert {:ok, found} = Shem.Lab.Registry.lookup_by_name(tool.name)
      assert found.id == tool.id
    end

    test "returns {:error, :not_found} for unknown name" do
      assert {:error, :not_found} = Shem.Lab.Registry.lookup_by_name("no_such_tool")
    end
  end

  test "rescan/0 rebuilds the table and keeps the always-on seed floor" do
    assert :ok = Shem.Lab.Registry.rescan()
    ids = Shem.Lab.Registry.all() |> Enum.map(& &1.id)
    assert "graphify_query" in ids
    assert "diff_text" in ids
  end
end
