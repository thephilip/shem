defmodule Shem.Recall.ScannerTest do
  use ExUnit.Case, async: false

  alias Shem.Recall.Scanner
  alias Shem.EventLog.Event

  setup do
    path = "tmp/test_recall_scan_#{:erlang.unique_integer([:positive])}"
    File.mkdir_p!(path)
    orig = Application.get_env(:shem, :event_log_path, "tmp/test_events")
    Application.put_env(:shem, :event_log_path, path)

    on_exit(fn ->
      Application.put_env(:shem, :event_log_path, orig)
      File.rm_rf!(path)
    end)

    %{path: path}
  end

  defp write_session(session_id, events, path) do
    dets_file = Path.join(path, "#{session_id}.dets") |> String.to_charlist()
    table = :"recall_scan_#{session_id}_#{:erlang.unique_integer([:positive])}"
    {:ok, tab} = :dets.open_file(table, file: dets_file, type: :set)
    for event <- events, do: :dets.insert(tab, {event.id, event})
    :dets.close(tab)
  end

  test "sessions/0 lists dets sessions with cache keys", %{path: path} do
    write_session("ses_RC_A", [Event.new("ses_RC_A", :agent_started, %{task: "t"})], path)

    assert [%{session_id: "ses_RC_A", cache_key: {mtime, size}}] = Scanner.sessions()
    assert is_integer(mtime) and is_integer(size) and size > 0
  end

  test "sessions/0 excludes the query-log session", %{path: path} do
    write_session(Scanner.query_session_id(), [], path)
    write_session("ses_RC_B", [Event.new("ses_RC_B", :agent_started, %{task: "t"})], path)

    assert [%{session_id: "ses_RC_B"}] = Scanner.sessions()
  end

  test "sessions/0 returns [] when the directory doesn't exist" do
    Application.put_env(:shem, :event_log_path, "tmp/does_not_exist_#{:erlang.unique_integer([:positive])}")
    assert Scanner.sessions() == []
  end

  test "events/1 reads a written session's events", %{path: path} do
    write_session("ses_RC_C", [Event.new("ses_RC_C", :agent_started, %{task: "readable"})], path)

    assert {:ok, [%Event{type: :agent_started}]} = Scanner.events("ses_RC_C")
  end
end
