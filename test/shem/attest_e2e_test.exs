defmodule Shem.AttestE2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e

  setup do
    if System.find_executable("python3") == nil, do: raise("python3 required for attest e2e")

    # Other async: false tests elsewhere in the suite call Registry.flush()
    # in their own setup and never restore it, leaving the shared global
    # ETS-backed registry empty for whatever test runs next. Since tests
    # run serially, that can be us. Rescan restores the seed floor (incl.
    # DiffText) that this test depends on, regardless of prior test damage.
    Shem.Lab.Registry.rescan()
    {:ok, sid} = Shem.EventLog.start_session()
    {:ok, _} = Shem.EventLog.append(sid, :agent_started, %{task: "t", preset: "general"})
    {:ok, _} = Shem.EventLog.append(sid, :agent_tool_called, %{tool: "DiffText", args: %{}})
    out = Path.join(System.tmp_dir!(), "attest_e2e_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(out) end)
    {:ok, dir} = Shem.Attest.build(sid, out: out)
    %{dir: dir}
  end

  defp verify(dir) do
    System.cmd("python3", [Path.join(dir, "verify.py"), dir], stderr_to_stdout: true)
  end

  test "a clean bundle verifies (exit 0)", %{dir: dir} do
    assert {out, 0} = verify(dir)
    assert out =~ "VERIFIED"
  end

  test "a tampered events.jsonl fails (exit 1)", %{dir: dir} do
    path = Path.join(dir, "events.jsonl")
    File.write!(path, String.replace(File.read!(path), "\"t\"", "\"HACKED\"", global: false))
    assert {out, 1} = verify(dir)
    assert out =~ "CHAIN MISMATCH"
  end

  test "a tampered tool source fails (exit 1)", %{dir: dir} do
    [tool | _] = Path.wildcard(Path.join([dir, "tools", "*"]))
    File.write!(tool, File.read!(tool) <> "\n# tampered\n")
    assert {out, 1} = verify(dir)
    assert out =~ "SHA MISMATCH"
  end

  test "verify.py verifies a GC'd bundle and catches anchor tampering" do
    {:ok, sid} = Shem.EventLog.start_session()
    for i <- 0..9, do: {:ok, _} = Shem.EventLog.append(sid, :test, %{i: i})
    {:ok, _} = Shem.EventLog.gc(sid, 4)

    out_dir = Path.join(System.tmp_dir!(), "attest_e2e_gc_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(out_dir) end)
    {:ok, dir} = Shem.Attest.build(sid, out: out_dir)

    assert {out, 0} = verify(dir)
    assert out =~ "pruned"
    # true logical range (pruned+1..pruned+n), not 1-n — the bundle's surviving
    # events are seq 6..9, not a fresh 1..4.
    assert out =~ "events 7-10 OK"

    m = Jason.decode!(File.read!(Path.join(dir, "manifest.json")))
    m = put_in(m["gc"]["portable_anchor"], String.duplicate("0", 64))
    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(m))
    assert {_, 1} = verify(dir)
  end
end
