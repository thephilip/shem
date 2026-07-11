defmodule Shem.Lab.SandboxTest do
  use ExUnit.Case, async: true
  alias Shem.Lab.Sandbox

  test "image/1 returns the per-language default" do
    assert Sandbox.image("python") == "python:3.12-slim"
    assert Sandbox.image("javascript") == "docker.io/denoland/deno:alpine"
    assert Sandbox.image("go") == "docker.io/library/golang:alpine"
  end

  test "elixir image is configurable with fully-qualified default" do
    assert Sandbox.image("elixir") == "docker.io/library/elixir:1.19-alpine"
  end

  test "spawn_spec host mode (runtime_bin nil) spawns the interpreter directly" do
    {exe, args, port_opts} =
      Sandbox.spawn_spec(nil, %{
        runtime_path: "/lab/graduated/foo_runtime.py",
        language: "python",
        tool_id: "foo",
        host_exe: "python3"
      })

    assert exe == "python3"
    assert args == ["/lab/graduated/foo_runtime.py"]
    assert port_opts == []
  end

  test "spawn_spec host mode for a :dir runtime (go) runs with cd into the dir" do
    {exe, args, port_opts} =
      Sandbox.spawn_spec(nil, %{
        runtime_path: "/lab/graduated/bar_runtime",
        language: "go",
        tool_id: "bar",
        host_exe: "go"
      })

    assert exe == "go"
    assert args == ["run", "/lab/graduated/bar_runtime"]
    assert port_opts == [cd: "/lab/graduated/bar_runtime"]
  end

  test "spawn_spec container mode (python :file) wraps the interpreter in podman run" do
    {exe, args, port_opts} =
      Sandbox.spawn_spec("podman", %{
        runtime_path: "/lab/graduated/foo_runtime.py",
        language: "python",
        tool_id: "foo",
        host_exe: "python3"
      })

    assert exe == "podman"
    assert port_opts == []
    # core flags present
    assert ["run", "-i", "--rm" | _] = args
    assert "--network=none" in args
    assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["-v", "/lab/graduated:/workspace:ro"])
    assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--label", "shem.managed=1"])
    assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--label", "shem.tool=foo"])
    assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["-w", "/workspace"])
    # unique name with the right prefix
    name = args |> Enum.drop_while(&(&1 != "--name")) |> Enum.at(1)
    assert String.starts_with?(name, "shem-foo-")
    # image + in-container argv come last
    assert List.last(args) == "/workspace/foo_runtime.py"
    assert Enum.at(args, -2) == "python3"
    assert Enum.at(args, -3) == "python:3.12-slim"
  end

  test "spawn_spec container mode (javascript :file) runs deno on the in-container path" do
    {exe, args, _} =
      Sandbox.spawn_spec("podman", %{
        runtime_path: "/lab/graduated/baz_runtime.ts",
        language: "javascript",
        tool_id: "baz",
        host_exe: "deno"
      })

    assert exe == "podman"
    assert Enum.take(args, -4) == ["docker.io/denoland/deno:alpine", "deno", "run", "/workspace/baz_runtime.ts"]
    assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["-v", "/lab/graduated:/workspace:ro"])
  end

  test "spawn_spec container mode (go :dir) mounts the dir, sets GOPROXY=off, runs go run /workspace" do
    {exe, args, _} =
      Sandbox.spawn_spec("podman", %{
        runtime_path: "/lab/graduated/bar_runtime",
        language: "go",
        tool_id: "bar",
        host_exe: "go"
      })

    assert exe == "podman"
    assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["-v", "/lab/graduated/bar_runtime:/workspace:ro"])
    assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["-e", "GOPROXY=off"])
    assert Enum.take(args, -4) == ["docker.io/library/golang:alpine", "go", "run", "/workspace"]
  end

  test "cleanup_tool/sweep_orphans are no-ops when runtime_bin is nil" do
    assert Sandbox.cleanup_tool(nil, "anything") == :ok
    assert Sandbox.sweep_orphans(nil) == :ok
  end

  test "sweep_orphans with the default (env) arg does not raise" do
    # In test, container_runtime_bin is nil → no-op. Exercises the 0-arity default head.
    assert Sandbox.sweep_orphans() == :ok
  end
end
