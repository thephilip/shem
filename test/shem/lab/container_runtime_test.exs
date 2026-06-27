defmodule Shem.Lab.ContainerRuntimeTest do
  # Run with: mix test --only container_integration
  # Requires podman/docker + the python:3.12-slim image (auto-pulled on first run).
  use ExUnit.Case, async: false
  @moduletag :container_integration

  alias Shem.Lab.{Workspace, Languages, PortPool, Sandbox}

  setup do
    bin = System.find_executable("podman") || System.find_executable("docker")
    if is_nil(bin), do: flunk("no container runtime")

    prev = Application.get_env(:shem, :container_runtime_bin)
    Application.put_env(:shem, :container_runtime_bin, Path.basename(bin))

    prev_lab = Application.get_env(:shem, :lab_dir)
    lab = Path.join(System.tmp_dir!(), "shem-cr-#{System.unique_integer([:positive])}")
    Application.put_env(:shem, :lab_dir, lab)

    on_exit(fn ->
      Sandbox.cleanup_tool(Path.basename(bin), "ctool")
      File.rm_rf(lab)
      Application.put_env(:shem, :lab_dir, prev_lab)
      Application.put_env(:shem, :container_runtime_bin, prev)
    end)

    %{bin: Path.basename(bin)}
  end

  test "a graduated python tool round-trips through a containerized pool", %{bin: bin} do
    # write the runtime file directly (avoid depending on the full graduation gate here)
    dir = Path.join(Application.get_env(:shem, :lab_dir), "graduated")
    File.mkdir_p!(dir)
    src = "def run(args):\n    return {\"result\": args[\"n\"] * 2}\n"
    File.write!(Path.join(dir, "ctool.py"), src)
    rt = Workspace.runtime_path("ctool", "python")
    File.write!(rt, Languages.wrapper("python", src))

    pool_name = :"shem_port_pool_ctool_python"
    {:ok, _} =
      start_supervised(
        {PortPool, [tool_id: "ctool", runtime_path: rt, language: "python", pool_size: 1, name: pool_name]}
      )

    assert {:ok, %{"result" => 42}} = PortPool.call(pool_name, %{"n" => 21})

    # the worker container is labeled for sweep + per-tool cleanup
    {out, 0} = System.cmd(bin, ["ps", "-q", "--filter", "label=shem.tool=ctool"])
    assert String.trim(out) != ""

    # terminate removes it by label. The pool's child id is the pool NAME
    # (PortPool.child_spec sets id: name), not the module, so stop by pool_name.
    :ok = stop_supervised(pool_name)
    Process.sleep(500)
    {out2, 0} = System.cmd(bin, ["ps", "-aq", "--filter", "label=shem.tool=ctool"])
    assert String.trim(out2) == ""
  end

  test "sweep_orphans removes a planted shem-managed orphan", %{bin: bin} do
    # --stop-signal=SIGKILL so `rm -f` is instant: a bare `sleep` runs as container
    # PID 1, which ignores SIGTERM, making the default `rm -f` wait podman's full
    # 10s stop-grace before SIGKILL. We're testing the sweep's label targeting, not
    # podman's stop timeout, so kill immediately.
    {_, 0} =
      System.cmd(bin, [
        "run", "-d", "--rm", "--stop-signal=SIGKILL", "--label", "shem.managed=1",
        "python:3.12-slim", "sleep", "60"
      ])

    Sandbox.sweep_orphans(bin)
    Process.sleep(800)

    {out, 0} = System.cmd(bin, ["ps", "-aq", "--filter", "label=shem.managed=1"])
    assert String.trim(out) == ""
  end
end
