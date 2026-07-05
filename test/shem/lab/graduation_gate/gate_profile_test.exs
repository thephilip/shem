defmodule Shem.Lab.GraduationGate.GateProfileTest do
  use ExUnit.Case, async: false

  # Deviation from the plan's app-env run_fn sketch: run_fn is a per-call
  # backend opt, not app env, and no gate threads it. The existing seam is the
  # process-local backend override (same one pack_contract_test uses), so we
  # inject a capturing backend instead of inventing a new mechanism.
  defmodule CaptureBackend do
    def run_shell(_cmd, _timeout_ms, opts) do
      send(Process.get(:gate_profile_test_pid), {:gate_opts, opts})
      {:error, "stop here"}
    end
  end

  setup do
    Process.put(:gate_profile_test_pid, self())
    Process.put(:shem_executor_backend, CaptureBackend)
    :ok
  end

  test "python gate uses granted image and mounts" do
    Shem.Lab.GraduationGate.Python.run(
      "def run(a):\n    return a\n",
      "def test_x():\n    assert True\n",
      sandbox: %{
        "image" => "docker.io/x/y:1",
        "mounts" => [%{"host" => "/tmp", "container" => "/cache", "mode" => "ro"}]
      }
    )

    assert_receive {:gate_opts, opts}
    assert opts[:image] == "docker.io/x/y:1"

    normalized =
      Enum.map(opts[:mounts], fn
        {h, c} -> {h, c, "ro"}
        {h, c, m} -> {h, c, m}
      end)

    assert {"/tmp", "/cache", "ro"} in normalized
  end

  test "js gate uses granted image" do
    Shem.Lab.GraduationGate.JS.run("export function run(a) { return a; }", "",
      sandbox: %{"image" => "docker.io/x/deno:9"}
    )

    assert_receive {:gate_opts, opts}
    assert opts[:image] == "docker.io/x/deno:9"
  end

  test "go gate uses granted image" do
    Shem.Lab.GraduationGate.Go.run("package tool", "package tool",
      sandbox: %{"image" => "docker.io/x/go:9"}
    )

    assert_receive {:gate_opts, opts}
    assert opts[:image] == "docker.io/x/go:9"
  end
end
