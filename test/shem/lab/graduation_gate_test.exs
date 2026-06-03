defmodule Shem.Lab.GraduationGateTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.{GraduationGate, Workspace}

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir, System.tmp_dir!())
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  # Each test uses a unique module name to avoid Registry contamination.
  # The Registry is app-started and persists across the entire test suite.

  test "returns {:ok, %Tool{}} and writes file when tests pass" do
    source = """
    defmodule GateAdd1 do
      def add(a, b), do: a + b
    end
    """
    test_source = """
    defmodule GateAdd1Test do
      def run do
        unless GateAdd1.add(2, 3) == 5, do: raise "2+3 should be 5"
        :ok
      end
    end
    """
    assert {:ok, tool} = GraduationGate.run(source, test_source)
    assert tool.id == "gate_add1"
    assert tool.module == GateAdd1
    assert tool.source == source
    assert File.exists?(Workspace.graduated_path("gate_add1"))
  end

  test "returns {:error, :gate, ...} when test module's run/0 raises" do
    source = """
    defmodule GateAdd2 do
      def add(a, b), do: a + b
    end
    """
    test_source = """
    defmodule GateAdd2Test do
      def run, do: raise "property violation: broken"
    end
    """
    assert {:error, :gate, _reason} = GraduationGate.run(source, test_source)
    refute File.exists?(Workspace.graduated_path("gate_add2"))
  end

  test "returns {:error, :compile, reason} when test source is syntactically invalid" do
    source = """
    defmodule GateAdd3 do
      def add(a, b), do: a + b
    end
    """
    bad_test = """
    defmodule GateAdd3Test do
      this is not valid elixir
    end
    """
    assert {:error, :compile, reason} = GraduationGate.run(source, bad_test)
    assert is_binary(reason)
  end

  test "stores user-provided constraints on the tool" do
    source = """
    defmodule GateAdd4 do
      def add(a, b), do: a + b
    end
    """
    test_source = """
    defmodule GateAdd4Test do
      def run do
        unless GateAdd4.add(1, 1) == 2, do: raise "broken"
        :ok
      end
    end
    """
    constraints = ["must handle negative numbers", "must return integer"]
    assert {:ok, tool} = GraduationGate.run(source, test_source, constraints)
    assert tool.constraints == constraints
  end

  test "generates versioned id when a tool with the same base id already exists" do
    source_v1 = """
    defmodule GateAdd5 do
      def add(a, b), do: a + b
    end
    """
    test_v1 = """
    defmodule GateAdd5Test do
      def run do
        unless GateAdd5.add(1, 2) == 3, do: raise "broken"
        :ok
      end
    end
    """
    {:ok, _} = GraduationGate.run(source_v1, test_v1)

    source_v2 = """
    defmodule GateAdd5 do
      def add(a, b), do: a + b + 0
    end
    """
    test_v2 = """
    defmodule GateAdd5Test do
      def run do
        unless GateAdd5.add(1, 1) == 2, do: raise "broken"
        :ok
      end
    end
    """
    assert {:ok, tool_v2} = GraduationGate.run(source_v2, test_v2)
    assert tool_v2.id == "gate_add5_v2"
  end
end
