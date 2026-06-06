defmodule Shem.EventLog.HistoryScannerTest do
  use ExUnit.Case, async: false

  alias Shem.EventLog.HistoryScanner
  alias Shem.EventLog.Event

  @base_path "tmp/test_scanner"

  setup do
    path = @base_path <> "_#{:erlang.unique_integer([:positive])}"
    File.mkdir_p!(path)
    orig_path = Application.get_env(:shem, :event_log_path, "tmp/test_events")
    Application.put_env(:shem, :event_log_path, path)

    on_exit(fn ->
      Application.put_env(:shem, :event_log_path, orig_path)
      File.rm_rf!(path)
    end)

    %{path: path}
  end

  defp write_session(session_id, events, path) do
    dets_file = Path.join(path, "#{session_id}.dets") |> String.to_charlist()
    table = :"test_scan_#{session_id}_#{:erlang.unique_integer([:positive])}"
    {:ok, tab} = :dets.open_file(table, file: dets_file, type: :set)
    for event <- events, do: :dets.insert(tab, {event.id, event})
    :dets.close(tab)
  end

  test "scan/0 returns empty list when directory has no dets files", %{path: _path} do
    assert HistoryScanner.scan() == []
  end

  test "scan/0 returns a summary for a done session", %{path: path} do
    sid = "ses_SCAN_DONE"
    write_session(sid, [
      Event.new(sid, :agent_started, %{task: "test scan task", model: :default, max_turns: 20}),
      Event.new(sid, :agent_done, %{content: "result", reason: :answer})
    ], path)

    [summary] = HistoryScanner.scan()
    assert summary.session_id == sid
    assert summary.task == "test scan task"
    assert summary.status == :done
    assert summary.turn_count == 0
  end

  test "scan/0 infers :error status from agent_error event", %{path: path} do
    sid = "ses_SCAN_ERR"
    write_session(sid, [
      Event.new(sid, :agent_started, %{task: "failing task", model: :default, max_turns: 20}),
      Event.new(sid, :agent_error, %{reason: "llm timeout"})
    ], path)

    [summary] = HistoryScanner.scan()
    assert summary.status == :error
  end

  test "scan/0 infers :unknown for sessions without done or error", %{path: path} do
    sid = "ses_SCAN_UNK"
    write_session(sid, [
      Event.new(sid, :agent_started, %{task: "interrupted", model: :default, max_turns: 20})
    ], path)

    [summary] = HistoryScanner.scan()
    assert summary.status == :unknown
  end

  test "scan/0 counts turn_count from agent_turn_completed events", %{path: path} do
    sid = "ses_SCAN_TURNS"
    write_session(sid, [
      Event.new(sid, :agent_started, %{task: "t", model: :default, max_turns: 20}),
      Event.new(sid, :agent_turn_completed, %{turn: 1}),
      Event.new(sid, :agent_turn_completed, %{turn: 2}),
      Event.new(sid, :agent_done, %{content: "done"})
    ], path)

    [summary] = HistoryScanner.scan()
    assert summary.turn_count == 2
  end

  test "scan/0 returns multiple sessions sorted most-recent-first", %{path: path} do
    sid_a = "ses_SCAN_A"
    sid_b = "ses_SCAN_B"

    write_session(sid_a, [
      Event.new(sid_a, :agent_started, %{task: "older", model: :default, max_turns: 20}),
      Event.new(sid_a, :agent_done, %{content: "done"})
    ], path)

    Process.sleep(5)

    write_session(sid_b, [
      Event.new(sid_b, :agent_started, %{task: "newer", model: :default, max_turns: 20}),
      Event.new(sid_b, :agent_done, %{content: "done"})
    ], path)

    [first, second] = HistoryScanner.scan()
    assert first.task == "newer"
    assert second.task == "older"
  end

  test "scan/0 skips corrupt/unreadable session files gracefully", %{path: path} do
    sid_bad = "ses_SCAN_BAD"
    File.write!(Path.join(path, "#{sid_bad}.dets"), "not a dets file at all")

    sid_good = "ses_SCAN_GOOD"
    write_session(sid_good, [
      Event.new(sid_good, :agent_started, %{task: "good", model: :default, max_turns: 20}),
      Event.new(sid_good, :agent_done, %{content: "done"})
    ], path)

    summaries = HistoryScanner.scan()
    assert length(summaries) == 1
    assert hd(summaries).session_id == sid_good
  end
end
