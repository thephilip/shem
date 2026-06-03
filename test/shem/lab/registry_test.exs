defmodule Shem.Lab.RegistryTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.Registry
  alias Shem.Lab.Workspace
  alias Shem.Tool

  @tool %Tool{
    id: "greeter_v1",
    name: "Greeter",
    module: Greeter,
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

  test "all/0 returns an empty list when no tools are registered" do
    {:ok, pid} = start_supervised({Registry, [name: :test_registry_3]})
    assert [] = GenServer.call(pid, :all)
  end

  test "all/0 returns all registered tools" do
    {:ok, pid} = start_supervised({Registry, [name: :test_registry_4]})
    GenServer.call(pid, {:register, @tool})
    tools = GenServer.call(pid, :all)
    assert length(tools) == 1
    assert hd(tools).id == "greeter_v1"
  end

  test "boot scan loads tools pre-written to the graduated directory" do
    Workspace.graduate(@tool)
    {:ok, pid} = start_supervised({Registry, [name: :test_registry_5]})
    tools = GenServer.call(pid, :all)
    assert length(tools) == 1
    assert hd(tools).id == "greeter_v1"
  end
end
