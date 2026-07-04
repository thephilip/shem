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

  test "daemon_running? is true when something answers 200 on the port" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen)
      :gen_tcp.recv(sock, 0, 1_000)
      :gen_tcp.send(sock, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
      :gen_tcp.close(sock)
    end)

    assert Shem.GC.daemon_running?(port)
    :gen_tcp.close(listen)
  end

  test "daemon_running? is false when nothing listens on the port" do
    refute Shem.GC.daemon_running?(59_999)
  end
end
