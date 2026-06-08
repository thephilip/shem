defmodule Shem.Lab.Executor.Backend.LocalTest do
  use ExUnit.Case, async: true

  alias Shem.Lab.Executor.Backend.Local

  test "returns {:ok, output} for successful command" do
    assert {:ok, output} = Local.run_shell("echo hello", 5_000, [])
    assert String.trim(output) == "hello"
  end

  test "returns {:error, exit_N: output} for non-zero exit" do
    result = Local.run_shell("exit 2", 5_000, [])
    assert match?({:error, "exit 2:" <> _}, result)
  end

  test "returns {:error, timeout} when command exceeds timeout_ms" do
    result = Local.run_shell("sleep 10", 50, [])
    assert result == {:error, "timeout after 50ms"}
  end
end
