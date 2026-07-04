# test/shem/attest_test.exs
defmodule Shem.AttestTest do
  use ExUnit.Case, async: false
  alias Shem.Attest

  setup do
    # Other async: false tests elsewhere in the suite call Registry.flush()
    # in their own setup and never restore it, leaving the shared global
    # ETS-backed registry empty for whatever test runs next. Since tests
    # run serially, that can be us. Rescan restores the seed floor (incl.
    # DiffText) that this test depends on, regardless of prior test damage.
    Shem.Lab.Registry.rescan()
    {:ok, sid} = Shem.EventLog.start_session()
    # Minimal replayable-shaped session: a start event + a tool call by name.
    {:ok, _} = Shem.EventLog.append(sid, :agent_started, %{task: "t", preset: "general"})
    {:ok, _} = Shem.EventLog.append(sid, :agent_tool_called, %{tool: "DiffText", args: %{}})
    {:ok, _} = Shem.EventLog.append(sid, :agent_tool_called, %{tool: "no_such_tool", args: %{}})
    out = Path.join(System.tmp_dir!(), "attest_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(out) end)
    %{sid: sid, out: out}
  end

  test "writes a bundle with manifest, events, and present/missing tools", %{sid: sid, out: out} do
    assert {:ok, dir} = Attest.build(sid, out: out)
    assert File.dir?(dir)

    manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    assert manifest["session_id"] == sid
    assert manifest["event_count"] == 3
    assert byte_size(manifest["portable_head"]) == 64
    assert manifest["portable_head"] == String.downcase(manifest["portable_head"])

    tools = Map.new(manifest["tools"], &{&1["name"], &1})
    assert tools["DiffText"]["status"] == "present"
    assert tools["no_such_tool"]["status"] == "missing"
    assert tools["no_such_tool"]["sha256"] == nil

    # the present tool's file exists and its sha256 matches the manifest
    present = tools["DiffText"]
    tool_file = Path.join([dir, "tools", "#{present["sha256"]}.#{tool_ext(present["runtime"])}"])
    assert File.exists?(tool_file)
    computed = :crypto.hash(:sha256, File.read!(tool_file)) |> Base.encode16(case: :lower)
    assert computed == present["sha256"]

    # events.jsonl has one canonical line per event, no trailing blank line
    lines = dir |> Path.join("events.jsonl") |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 3

    # portable head recomputed independently equals the manifest
    head =
      Enum.reduce(lines, Attest.portable_genesis(sid), fn line, prev ->
        Attest.portable_next(prev, line)
      end)

    assert head == manifest["portable_head"]
  end

  defp tool_ext("beam"), do: "ex"
  defp tool_ext("python"), do: "py"
  defp tool_ext(_), do: "ts"
end
