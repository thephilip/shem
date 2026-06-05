defmodule Shem.Lab.ExecutorTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.Executor

  test "returns {:ok, value} when source compiles and fun succeeds" do
    source = """
    defmodule ExecAdd do
      def add(a, b), do: a + b
    end
    """

    assert {:ok, 7} = Executor.run(source, fn mod -> mod.add(3, 4) end)
  end

  test "returns {:error, :compile, reason} for syntactically invalid source" do
    assert {:error, :compile, reason} =
             Executor.run("this is not valid elixir!!!", fn _ -> :ok end)

    assert is_binary(reason)
  end

  test "returns {:error, :runtime, _} when fun raises" do
    source = """
    defmodule ExecBoom do
      def boom, do: raise "explosion"
    end
    """

    assert {:error, :runtime, _} = Executor.run(source, fn mod -> mod.boom() end)
  end

  test "returns {:error, :timeout} when fun exceeds configured timeout" do
    source = """
    defmodule ExecHang do
      def hang, do: Process.sleep(:infinity)
    end
    """

    assert {:error, :timeout} = Executor.run(source, fn mod -> mod.hang() end, timeout: 50)
  end

  test "loads all modules in source; fun receives the last defined module atom" do
    source = """
    defmodule ExecHelper do
      def val, do: 42
    end

    defmodule ExecMain do
      def result, do: ExecHelper.val() * 2
    end
    """

    assert {:ok, 84} = Executor.run(source, fn mod -> mod.result() end)
  end

  describe "remote node dispatch" do
    test "node: nil uses local execution (existing behavior)" do
      source = """
      defmodule RemoteTestLocal do
        def run, do: :local_result
      end
      """
      assert {:ok, :local_result} = Shem.Lab.Executor.run(source, fn m -> m.run() end, node: nil)
    end

    test "node: Node.self() uses local execution" do
      source = """
      defmodule RemoteTestSelf do
        def run, do: :self_result
      end
      """
      assert {:ok, :self_result} =
               Shem.Lab.Executor.run(source, fn m -> m.run() end, node: Node.self())
    end

    test "node: :nonexistent@host returns {:error, _} " do
      source = "defmodule RemoteTestFail do\n  def run, do: :ok\nend"
      result = Shem.Lab.Executor.run(source, fn m -> m.run() end, node: :"nonexistent@127.0.0.1")
      assert match?({:error, _}, result)
    end
  end
end
