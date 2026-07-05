defmodule Shem.EventLog.RedactTest do
  use ExUnit.Case, async: false
  alias Shem.EventLog.Redact

  test "plain payloads pass through unchanged" do
    p = %{tool: "x", result: "ok", n: 1, l: [1, "a"]}
    assert Redact.redact(p) == p
  end

  test "sensitive wrapper map is replaced with $redacted marker" do
    out = Redact.redact(%{"r" => %{"$sensitive" => "hunter2"}})
    assert %{"r" => %{"$redacted" => h}} = out
    assert byte_size(h) == 16
    refute inspect(out) =~ "hunter2"
  end

  test "redaction is deterministic for identical values" do
    a = Redact.redact(%{"r" => %{"$sensitive" => "same"}})
    b = Redact.redact(%{"r" => %{"$sensitive" => "same"}})
    assert a == b
  end

  test "JSON string results containing $sensitive are redacted" do
    s = Jason.encode!(%{"value" => %{"$sensitive" => "hunter2"}, "ok" => true})
    out = Redact.redact(%{result: s})
    refute out.result =~ "hunter2"
    assert Jason.decode!(out.result)["value"]["$redacted"]
    assert Jason.decode!(out.result)["ok"] == true
  end

  test "non-JSON string containing $sensitive is fully redacted (fail closed)" do
    out = Redact.redact(%{result: ~s(prefix {"$sensitive": "hunter2"} suffix)})
    assert %{"$redacted" => _} = out.result
    refute inspect(out) =~ "hunter2"
  end

  test "map with $sensitive plus other keys is walked, not treated as a wrapper" do
    out = Redact.redact(%{"m" => %{"$sensitive" => "x", "other" => %{"$sensitive" => "y"}}})
    # only single-key wrappers redact; the outer map walks its values
    assert %{"m" => %{"$sensitive" => "x", "other" => %{"$redacted" => _}}} = out
  end

  test "appended events store the redacted form and the chain verifies" do
    {:ok, session_id} = Shem.EventLog.start_session()

    {:ok, ev} =
      Shem.EventLog.append(session_id, :agent_tool_result,
        %{tool: "t", result: %{"$sensitive" => "hunter2"}})

    assert %{"$redacted" => _} = ev.payload.result

    {:ok, events} = Shem.EventLog.events(session_id)
    assert {:ok, :verified, _} = Shem.EventLog.Chain.verify(events, session_id)
    refute inspect(events) =~ "hunter2"
  end
end
