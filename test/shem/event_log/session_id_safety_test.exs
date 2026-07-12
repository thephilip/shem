defmodule Shem.EventLog.SessionIdSafetyTest do
  use ExUnit.Case, async: false

  alias Shem.EventLog.Event

  # A session_id is used to build a filesystem path (<events dir>/<id>.dets).
  # Ids with path separators or dot segments must never escape the events dir.

  setup do
    base = "tmp/test_sid_safety_#{:erlang.unique_integer([:positive])}"
    events_dir = Path.join(base, "events")
    outside_dir = Path.join(base, "outside")
    File.mkdir_p!(events_dir)
    File.mkdir_p!(outside_dir)
    orig = Application.get_env(:shem, :event_log_path, "tmp/test_events")
    Application.put_env(:shem, :event_log_path, events_dir)

    on_exit(fn ->
      Application.put_env(:shem, :event_log_path, orig)
      File.rm_rf!(base)
    end)

    %{outside_dir: outside_dir}
  end

  defp write_dets(dir, name, events) do
    file = Path.join(dir, "#{name}.dets") |> String.to_charlist()
    table = :"sid_safety_#{:erlang.unique_integer([:positive])}"
    {:ok, tab} = :dets.open_file(table, file: file, type: :set)
    for event <- events, do: :dets.insert(tab, {event.id, event})
    :dets.close(tab)
  end

  test "a traversal session_id cannot read a dets file outside the events dir", %{
    outside_dir: outside_dir
  } do
    write_dets(outside_dir, "loot", [Event.new("ses_X", :agent_started, %{task: "outside"})])

    assert {:error, :not_found} =
             Shem.EventLog.read_session_events("../outside/loot")
  end

  test "ids with path separators or dot segments are refused, valid ids still read" do
    events_dir = Application.get_env(:shem, :event_log_path)
    write_dets(events_dir, "ses_SAFE", [Event.new("ses_SAFE", :agent_started, %{task: "in"})])

    for evil <- ["../ses_SAFE", "a/b", "..", ".", "ses_SAFE/"] do
      assert {:error, :not_found} = Shem.EventLog.read_session_events(evil),
             "expected refusal for #{inspect(evil)}"
    end

    assert {:ok, [%Event{}]} = Shem.EventLog.read_session_events("ses_SAFE")
  end
end
