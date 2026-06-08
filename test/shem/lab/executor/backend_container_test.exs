defmodule Shem.Lab.Executor.Backend.ContainerTest do
  use ExUnit.Case, async: true

  alias Shem.Lab.Executor.Backend.Container

  test "run_fn: success path returns {:ok, output}" do
    run_fn = fn _cmd, _timeout_ms, _opts -> {:ok, "mocked output\n"} end
    assert {:ok, "mocked output\n"} = Container.run_shell("ls", 5_000, run_fn: run_fn)
  end

  test "run_fn: non-zero exit forwarded as-is" do
    run_fn = fn _cmd, _timeout_ms, _opts -> {:error, "exit 1: permission denied"} end
    assert {:error, "exit 1: permission denied"} = Container.run_shell("ls /root", 5_000, run_fn: run_fn)
  end

  test "run_fn: timeout forwarded as-is" do
    run_fn = fn _cmd, _timeout_ms, _opts -> {:error, "timeout after 100ms"} end
    assert {:error, "timeout after 100ms"} = Container.run_shell("sleep 10", 100, run_fn: run_fn)
  end

  test "returns no-runtime error when container_runtime_bin is nil and no run_fn" do
    Application.put_env(:shem, :container_runtime_bin, nil)
    result = Container.run_shell("ls", 5_000, [])
    assert {:error, "no container runtime available (tried podman, docker)"} = result
  end
end
