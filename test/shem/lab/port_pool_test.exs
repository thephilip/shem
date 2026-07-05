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
    # Ensure host execution for all tests in this module. Another test module
    # (graduation_gate_go_test) sets container_runtime_bin without restoring it,
    # which would otherwise cause PortPool to try containerizing sh scripts.
    prev_bin     = Application.get_env(:shem, :container_runtime_bin)
    prev_backend = Application.get_env(:shem, :executor_backend)
    Application.put_env(:shem, :container_runtime_bin, nil)
    Application.put_env(:shem, :executor_backend, :local)
    on_exit(fn ->
      Application.put_env(:shem, :container_runtime_bin, prev_bin)
      Application.put_env(:shem, :executor_backend, prev_backend)
    end)

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

  test "pool_name includes language so one tool_id maps to distinct pools per runtime" do
    # Guards the tool-pack replace path: re-registering a tool_id under a different
    # runtime must get a fresh pool, not the stale interpreter's pool.
    refute Shem.Lab.PortPool.Supervisor.pool_name("t", "python") ==
             Shem.Lab.PortPool.Supervisor.pool_name("t", "javascript")
  end

  @tag :go
  test "Go tool runs through the pool via go run <dir> (compile then serve)" do
    {:ok, _sup} = start_supervised(Shem.Lab.PortPool.Supervisor)

    id = "go_rt_#{System.unique_integer([:positive])}"
    dir = Shem.Lab.Workspace.runtime_path(id, "go")
    File.mkdir_p!(dir)
    for {name, content} <-
          Shem.Lab.Languages.dir_files("go",
            "package main\nimport \"strings\"\nfunc run(a map[string]any) any { s, _ := a[\"s\"].(string); return map[string]any{\"up\": strings.ToUpper(s)} }") do
      File.write!(Path.join(dir, name), content)
    end

    {:ok, pool} = Shem.Lab.PortPool.Supervisor.ensure_started(id, dir, "go")
    # first call pays compile; allow generous timeout
    assert {:ok, %{"up" => "HI"}} = Shem.Lab.PortPool.call(pool, %{"s" => "hi"}, 30_000)
    # second call is warm
    assert {:ok, %{"up" => "BYE"}} = Shem.Lab.PortPool.call(pool, %{"s" => "bye"}, 30_000)
  end

  test "warns when falling back to host execution (no container runtime, not :local)" do
    import ExUnit.CaptureLog

    prev_bin = Application.get_env(:shem, :container_runtime_bin)
    prev_backend = Application.get_env(:shem, :executor_backend)
    Application.put_env(:shem, :container_runtime_bin, nil)
    Application.put_env(:shem, :executor_backend, :auto)
    on_exit(fn ->
      Application.put_env(:shem, :container_runtime_bin, prev_bin)
      Application.put_env(:shem, :executor_backend, prev_backend)
    end)

    script = Path.join(System.tmp_dir!(), "echo_#{System.unique_integer([:positive])}.sh")
    File.write!(script, "while read line; do echo \"$line\"; done\n")
    on_exit(fn -> File.rm(script) end)

    pool_name = :"warn_pool_#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        start_supervised!(
          {Shem.Lab.PortPool,
           [tool_id: "warn_tool", runtime_path: script, language: "python",
            pool_size: 1, name: pool_name, executable: "sh"]}
        )
        # round-trip still works on the host fallback path
        assert {:ok, %{"n" => 1}} = Shem.Lab.PortPool.call(pool_name, %{"n" => 1})
      end)

    assert log =~ "UNSANDBOXED"
  end

  test "terminate cleans up by tool label and is a no-op without a runtime" do
    # container_runtime_bin is nil in test (config/test.exs executor_backend: :local),
    # so cleanup_tool is a no-op; this asserts terminate/2 exists and stops cleanly.
    script = Path.join(System.tmp_dir!(), "echo_#{System.unique_integer([:positive])}.sh")
    File.write!(script, "while read line; do echo \"$line\"; done\n")
    on_exit(fn -> File.rm(script) end)

    pool_name = :"term_pool_#{System.unique_integer([:positive])}"
    {:ok, pid} =
      start_supervised(
        {Shem.Lab.PortPool,
         [tool_id: "term_tool", runtime_path: script, language: "python",
          pool_size: 1, name: pool_name, executable: "sh"]}
      )

    assert Process.info(pid, :trap_exit) == {:trap_exit, true}

    ref = Process.monitor(pid)
    :ok = GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000
  end

  @tag :deno
  test "Deno tool round-trips JSON through the pool" do
    {:ok, _sup} = start_supervised(Shem.Lab.PortPool.Supervisor)

    dir = Path.join(System.tmp_dir!(), "ppjs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    rt = Path.join(dir, "up_runtime.ts")
    File.write!(rt, Shem.Lab.Languages.wrapper("javascript",
      "function run(a){ return { up: String(a.s).toUpperCase() } }"))

    {:ok, pool} = Shem.Lab.PortPool.Supervisor.ensure_started("up_js", rt, "javascript")
    assert {:ok, %{"up" => "HI"}} = Shem.Lab.PortPool.call(pool, %{"s" => "hi"})
  end

  test "responses longer than the port line limit round-trip intact", %{script: script} do
    pool_name = :"pool_test_#{:erlang.unique_integer()}"
    {:ok, _pid} = start_supervised(
      {PortPool, [tool_id: "long_echo", runtime_path: script, pool_size: 1, name: pool_name, executable: "sh"]}
    )

    # ~64KB value: far beyond :line's 1024-byte cap, so it arrives as many
    # :noeol chunks (a base64 screenshot in miniature)
    big = String.duplicate("A", 65_536)
    assert {:ok, response} = PortPool.call(pool_name, %{"blob" => big})
    assert response["blob"] == big
  end
end
