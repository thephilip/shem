defmodule Shem.Lab.SandboxProfileTest do
  use ExUnit.Case, async: true
  alias Shem.Lab.Sandbox

  @spec_base %{language: "python", runtime_path: "/tmp/t.py", tool_id: "t1", host_exe: "python3"}

  test "default profile keeps --network=none and slim image" do
    {_bin, argv, _opts} = Sandbox.spawn_spec("podman", @spec_base)
    assert "--network=none" in argv
    assert Enum.any?(argv, &String.contains?(&1, "python:3.12-slim"))
  end

  test "granted network drops --network=none" do
    spec = Map.put(@spec_base, :granted, %{"network" => true})
    {_bin, argv, _opts} = Sandbox.spawn_spec("podman", spec)
    refute "--network=none" in argv
  end

  test "granted image replaces the default" do
    spec = Map.put(@spec_base, :granted, %{"image" => "docker.io/x/y:1"})
    {_bin, argv, _opts} = Sandbox.spawn_spec("podman", spec)
    assert "docker.io/x/y:1" in argv
    refute Enum.any?(argv, &String.contains?(&1, "python:3.12-slim"))
  end

  test "granted mounts are appended with expanded host path and mode" do
    spec = Map.put(@spec_base, :granted,
      %{"mounts" => [%{"host" => "~/.cache/x", "container" => "/cache", "mode" => "rw"}]})
    {_bin, argv, _opts} = Sandbox.spawn_spec("podman", spec)
    expanded = Path.expand("~/.cache/x")
    assert Enum.any?(argv, &(&1 == "#{expanded}:/cache:rw"))
  end

  test "requires_container?" do
    refute Sandbox.requires_container?(%{})
    refute Sandbox.requires_container?(nil)
    assert Sandbox.requires_container?(%{"network" => true})
  end
end
