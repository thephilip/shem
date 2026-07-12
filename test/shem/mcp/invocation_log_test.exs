defmodule Shem.MCP.InvocationLogTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Shem.MCP.{InvocationLog, Router}
  alias Shem.EventLog.Event

  @opts Router.init([])

  defp call_tool(name, arguments) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments},
        "id" => 1
      })

    conn(:post, "/message", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp invocation_events do
    case Shem.EventLog.read_session_events(InvocationLog.session_id()) do
      {:ok, events} -> Enum.filter(events, &(&1.type == :tool_invoked))
      _ -> []
    end
  end

  test "a tools/call appends a :tool_invoked event with digest and outcome" do
    before = length(invocation_events())
    conn = call_tool("list_tools", %{})
    assert conn.status == 200

    events = invocation_events()
    assert length(events) == before + 1
    assert %Event{payload: p} = List.last(events)
    assert p.tool == "list_tools"
    assert is_binary(p.args_digest) and byte_size(p.args_digest) == 16
    assert p.outcome == :ok
  end

  test "a failed tool call logs outcome :error" do
    call_tool("no_such_tool", %{"x" => 1})

    assert %Event{payload: p} = List.last(invocation_events())
    assert p.tool == "no_such_tool"
    assert p.outcome == :error
  end

  test "digest is stable for equal args and differs for different args" do
    call_tool("list_tools", %{"a" => 1})
    call_tool("list_tools", %{"a" => 1})
    call_tool("list_tools", %{"a" => 2})

    [d1, d2, d3] =
      invocation_events() |> Enum.take(-3) |> Enum.map(& &1.payload.args_digest)

    assert d1 == d2
    refute d2 == d3
  end

  test "raw args never appear in the log payload" do
    call_tool("list_tools", %{"secret_looking" => "hunter2-plaintext"})

    %Event{payload: p} = List.last(invocation_events())
    refute inspect(p) =~ "hunter2-plaintext"
  end

  test "a dead EventLog never breaks the tool call" do
    :ok = Supervisor.terminate_child(Shem.Supervisor, Shem.EventLog)

    on_exit(fn ->
      Supervisor.restart_child(Shem.Supervisor, Shem.EventLog)
    end)

    conn = call_tool("list_tools", %{})
    assert conn.status == 200
    assert %{"result" => _} = Jason.decode!(conn.resp_body)
  end
end
