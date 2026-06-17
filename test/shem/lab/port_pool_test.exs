defmodule Shem.Lab.PortPoolTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.PortPool

  @echo_script """
  #!/bin/sh
  while IFS= read -r line; do
    printf '%s\\n' "$line"
  done
  """

  setup do
    script = Path.join(System.tmp_dir!(), "shem_pool_test_#{:erlang.unique_integer([:positive])}.sh")
    File.write!(script, @echo_script)
    File.chmod!(script, 0o755)
    on_exit(fn -> File.rm(script) end)
    {:ok, script: script}
  end

  test "call/2 sends JSON to worker and receives JSON response", %{script: script} do
    pool_name = :"pool_test_#{:erlang.unique_integer()}"
    {:ok, _pid} = start_supervised(
      {PortPool, [tool_id: "echo_tool", runtime_path: script, pool_size: 1, name: pool_name, executable: "sh"]}
    )

    assert {:ok, response} = PortPool.call(pool_name, %{"x" => 42})
    assert response["x"] == 42
  end

  test "pool handles concurrent calls via queue", %{script: script} do
    pool_name = :"pool_conc_#{:erlang.unique_integer()}"
    {:ok, _pid} = start_supervised(
      {PortPool, [tool_id: "conc_tool", runtime_path: script, pool_size: 2, name: pool_name, executable: "sh"]}
    )

    tasks = for i <- 1..5 do
      Task.async(fn -> PortPool.call(pool_name, %{"i" => i}) end)
    end

    results = Task.await_many(tasks, 10_000)
    assert length(results) == 5
    assert Enum.all?(results, fn
      {:ok, _} -> true
      _ -> false
    end)
  end

  test "returns {:error, reason} for __error__ response" do
    error_script = Path.join(System.tmp_dir!(), "shem_error_#{:erlang.unique_integer()}.sh")
    File.write!(error_script, "#!/bin/sh\nwhile IFS= read -r line; do printf '{\"__error__\":\"intentional error\"}\\n'; done\n")
    File.chmod!(error_script, 0o755)

    pool_name = :"pool_err_#{:erlang.unique_integer()}"
    {:ok, _pid} = start_supervised(
      {PortPool, [tool_id: "err_tool", runtime_path: error_script, pool_size: 1, name: pool_name, executable: "sh"]}
    )

    assert {:error, "intentional error"} = PortPool.call(pool_name, %{"x" => 1})

    File.rm(error_script)
  end
end
