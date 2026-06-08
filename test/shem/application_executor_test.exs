defmodule Shem.ApplicationExecutorTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Shem.Application, as: ShemApp

  setup do
    old_backend = Application.get_env(:shem, :executor_backend)
    old_resolved = Application.get_env(:shem, :resolved_executor_backend)
    old_bin = Application.get_env(:shem, :container_runtime_bin)

    on_exit(fn ->
      if old_backend do
        Application.put_env(:shem, :executor_backend, old_backend)
      else
        Application.delete_env(:shem, :executor_backend)
      end
      if old_resolved do
        Application.put_env(:shem, :resolved_executor_backend, old_resolved)
      else
        Application.delete_env(:shem, :resolved_executor_backend)
      end
      if old_bin do
        Application.put_env(:shem, :container_runtime_bin, old_bin)
      else
        Application.delete_env(:shem, :container_runtime_bin)
      end
    end)

    :ok
  end

  test ":local resolves to Backend.Local without detection" do
    Application.put_env(:shem, :executor_backend, :local)
    ShemApp.resolve_executor_backend()
    assert Application.get_env(:shem, :resolved_executor_backend) ==
             Shem.Lab.Executor.Backend.Local
  end

  test ":container with runtime resolves to Backend.Container" do
    Application.put_env(:shem, :executor_backend, :container)
    ShemApp.resolve_executor_backend(fn -> "docker" end)
    assert Application.get_env(:shem, :resolved_executor_backend) ==
             Shem.Lab.Executor.Backend.Container
    assert Application.get_env(:shem, :container_runtime_bin) == "docker"
  end

  test ":container with no runtime resolves to Backend.Container and logs error" do
    Application.put_env(:shem, :executor_backend, :container)

    log =
      capture_log(fn ->
        ShemApp.resolve_executor_backend(fn -> nil end)
      end)

    assert Application.get_env(:shem, :resolved_executor_backend) ==
             Shem.Lab.Executor.Backend.Container
    assert Application.get_env(:shem, :container_runtime_bin) == nil
    assert log =~ "no container runtime found"
  end

  test ":auto with no runtime falls back to Local and emits warning" do
    Application.put_env(:shem, :executor_backend, :auto)

    log =
      capture_log(fn ->
        ShemApp.resolve_executor_backend(fn -> nil end)
      end)

    assert Application.get_env(:shem, :resolved_executor_backend) ==
             Shem.Lab.Executor.Backend.Local
    assert log =~ "no container runtime found"
  end

  test ":auto with podman resolves to Container" do
    Application.put_env(:shem, :executor_backend, :auto)

    ShemApp.resolve_executor_backend(fn -> "podman" end)

    assert Application.get_env(:shem, :resolved_executor_backend) ==
             Shem.Lab.Executor.Backend.Container
    assert Application.get_env(:shem, :container_runtime_bin) == "podman"
  end
end
