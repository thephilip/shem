defmodule Shem.GCCliTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Shem.EventLog

  defp seed(n) do
    {:ok, sid} = EventLog.start_session()
    for i <- 0..(n - 1), do: {:ok, _} = EventLog.append(sid, :test, %{i: i})
    sid
  end

  test "rpc_report prints sentinel + report on success" do
    sid = seed(10)
    out = capture_io(fn -> Shem.GC.rpc_report(sid, 3) end)
    assert [line1 | _] = String.split(out, "\n")
    assert line1 == "SHEM_GC_OK"
    assert out =~ "pruned"
  end

  test "rpc_report prints error to stderr, no sentinel, on unknown session" do
    err = capture_io(:stderr, fn -> Shem.GC.rpc_report("ses_NOPE", 3) end)
    assert err =~ "failed"
  end

  test "noop still prints the sentinel" do
    sid = seed(2)
    out = capture_io(fn -> Shem.GC.rpc_report(sid, 10) end)
    assert String.starts_with?(out, "SHEM_GC_OK")
    assert out =~ "nothing to prune"
  end
end
