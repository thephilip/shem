defmodule Shem.Lab.ExecutorShellTest do
  # process-dict mutation — must not run concurrently
  use ExUnit.Case, async: false

  alias Shem.Lab.Executor
  alias Shem.Lab.Executor.Backend

  setup do
    # Restore after each test
    old = Process.get(:shem_executor_backend)
    on_exit(fn ->
      if old, do: Process.put(:shem_executor_backend, old),
      else: Process.delete(:shem_executor_backend)
    end)
    :ok
  end

  test "routes to Local backend when process dict overridden" do
    Process.put(:shem_executor_backend, Backend.Local)
    assert {:ok, output} = Executor.run_shell("echo routed", 5_000)
    assert String.trim(output) == "routed"
  end

  test "routes to Container backend when overridden with run_fn injection" do
    run_fn = fn _cmd, _timeout, _opts -> {:ok, "container result"} end
    Process.put(:shem_executor_backend, Backend.Container)
    assert {:ok, "container result"} = Executor.run_shell("ls", 5_000, run_fn: run_fn)
  end

  test "falls back to Application env backend when no process override" do
    Process.delete(:shem_executor_backend)
    # Application env in test is :local, so this should succeed via Local
    assert {:ok, output} = Executor.run_shell("echo configured", 5_000)
    assert String.trim(output) == "configured"
  end
end
