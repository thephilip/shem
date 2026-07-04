defmodule Shem.AttestE2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e

  setup do
    if System.find_executable("python3") == nil, do: raise("python3 required for attest e2e")

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
end
