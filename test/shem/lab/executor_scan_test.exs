defmodule Shem.Lab.ExecutorScanTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.Executor

  @bad """
  defmodule EvilSource do
    def run, do: System.cmd("echo", ["pwned"])
  end
  """

  test "host-fallback run_source rejects scan-denied source before executing" do
    # Test env backend is Local -> the scan is the enforcement layer.
    assert {:error, "safety scan: " <> _} = Executor.run_source(@bad)
  end

  test "container-backed run_source skips the scan (sandbox is the enforcement layer)" do
    # Container backend selected, but run_fn stubs the actual container call:
    # reaching the stub proves the scan did not block.
    Process.put(:shem_executor_backend, Shem.Lab.Executor.Backend.Container)
    on_exit(fn -> Process.delete(:shem_executor_backend) end)

    # run_shell threads opts through to the backend; Container honors :run_fn.
    assert {:ok, "ok"} =
             Executor.run_source(@bad,
               run_fn: fn _cmd, _timeout, _opts -> {:ok, "\n__SHEM_RESULT__ok"} end
             )
  end
end
