defmodule Shem.Lab.ExecutorTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.Executor

  # Test env resolves to the Local backend: run_source executes a real host
  # `elixir` subprocess — the fallback path. Container path is covered by the
  # :elixir_integration e2e.

  test "run_source returns the inspected run/0 result of the last module" do
    source = """
    defmodule ExecSourceOk do
      def run, do: {:answer, 21 * 2}
    end
    """

    assert {:ok, "{:answer, 42}"} = Executor.run_source(source)
  end

  test "run_source reports compile failure" do
    # Unparseable source is caught by the host-fallback scan before the
    # subprocess; parseable-but-uncompilable source exercises the subprocess.
    source = """
    defmodule ExecSourceBadCompile do
      def run, do: this_function_does_not_exist()
    end
    """

    assert {:error, msg} = Executor.run_source(source)
    assert msg =~ ~r/exit \d+/
  end

  test "run_source reports runtime failure" do
    source = """
    defmodule ExecSourceBoom do
      def run, do: raise("boom")
    end
    """

    assert {:error, msg} = Executor.run_source(source)
    assert msg =~ "boom"
  end

  test "run_source times out" do
    source = """
    defmodule ExecSourceHang do
      def run, do: Process.sleep(60_000)
    end
    """

    assert {:error, msg} = Executor.run_source(source, timeout: 2_000)
    assert msg =~ "timeout"
  end
end
