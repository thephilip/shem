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
    assert {:ok, tool} = GraduationGate.run(source, test_source, constraints: constraints)
    assert tool.constraints == constraints
  end

  describe "opts keyword arg" do
    test "stores description in tool.metadata" do
      source = """
      defmodule GateDesc1 do
        def run(%{"x" => x}), do: x * 2
      end
      """
      test_src = """
      defmodule GateDesc1Test do
        def run do
          unless GateDesc1.run(%{"x" => 3}) == 6, do: raise "broken"
          :ok
        end
      end
      """
      assert {:ok, tool} = GraduationGate.run(source, test_src,
        description: "Doubles x. Args: x (integer). Returns integer.")
      assert tool.metadata["description"] == "Doubles x. Args: x (integer). Returns integer."
    end

    test "stores schema in tool.metadata" do
      source = """
      defmodule GateDesc2 do
        def run(%{"x" => x}), do: x + 1
      end
      """
      test_src = """
      defmodule GateDesc2Test do
        def run do
          unless GateDesc2.run(%{"x" => 1}) == 2, do: raise "broken"
          :ok
        end
      end
      """
      schema = %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}}
      assert {:ok, tool} = GraduationGate.run(source, test_src, schema: schema)
      assert tool.metadata["schema"] == schema
    end

    test "description defaults to empty string and schema defaults to empty map when not provided" do
      source = """
      defmodule GateDesc3 do
        def run(_args), do: :ok
      end
      """
      test_src = """
      defmodule GateDesc3Test do
        def run, do: :ok
      end
      """
      assert {:ok, tool} = GraduationGate.run(source, test_src)
      assert tool.metadata["description"] == ""
      assert tool.metadata["schema"] == %{}
    end
  end

  describe "property-gated graduation" do
    test "a tool without property tests graduates seeded at trust :medium" do
      source = """
      defmodule NoPropTool1 do
        def run(_args), do: :ok
      end
      """

      test_src = """
      defmodule NoPropTool1Test do
        def run, do: :ok
      end
      """

      assert {:ok, tool} = GraduationGate.run(source, test_src)
      assert tool.metadata.property_tested == false
      assert {:ok, 0.5} = Shem.Trust.Store.score(tool.id)
    end

    test "a tool with a passing StreamData property graduates unrated" do
      source = """
      defmodule PropTool1 do
        def run(args), do: {:ok, args}
      end
      """

      test_src = """
      defmodule PropTool1Test do
        def run do
          {:ok, _} =
            StreamData.check_all(StreamData.integer(), [initial_seed: {42, 0, 0}], fn i ->
              case PropTool1.run(i) do
                {:ok, ^i} -> {:ok, i}
                other -> {:error, other}
              end
            end)

          :ok
        end
      end
      """

      assert {:ok, tool} = GraduationGate.run(source, test_src)
      assert tool.metadata.property_tested == true
      assert {:error, :unrated} = Shem.Trust.Store.score(tool.id)
    end

    test "a failing property still fails the gate" do
      source = """
      defmodule PropTool2 do
        def run(_args), do: :wrong
      end
      """

      test_src = """
      defmodule PropTool2Test do
        def run do
          {:ok, _} =
            StreamData.check_all(StreamData.integer(), [initial_seed: {42, 0, 0}], fn _i ->
              {:error, :always_fails}
            end)

          :ok
        end
      end
      """

      assert {:error, _, _} = GraduationGate.run(source, test_src)
    end
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
