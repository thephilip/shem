defmodule Shem.TUI.Views.HistoryTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.Views.History
  alias Shem.EventLog.HistoryScanner
  alias Shem.TUI.AgentView

  defp base_model do
    %{
      history_sessions: [],
      history_cursor: 0,
      history_detail: nil
    }
  end

  defp summary(opts \\ []) do
    %HistoryScanner{
      session_id: Keyword.get(opts, :session_id, "ses_TEST"),
      task: Keyword.get(opts, :task, "test task"),
      started_at: Keyword.get(opts, :started_at, DateTime.utc_now()),
      status: Keyword.get(opts, :status, :done),
      turn_count: Keyword.get(opts, :turn_count, 3)
    }
  end

  test "render/1 does not raise for empty session list" do
    model = base_model()
    assert is_map(History.render(model))
  end

  test "render/1 does not raise for populated session list" do
    model = %{base_model() | history_sessions: [summary()], history_cursor: 0}
    assert is_map(History.render(model))
  end

  test "render/1 does not raise with history_detail populated" do
    model = %{
      base_model()
      | history_sessions: [summary()],
        history_cursor: 0,
        history_detail: %AgentView{}
    }
    assert is_map(History.render(model))
  end

  test "render/1 does not raise when cursor is beyond session list" do
    model = %{base_model() | history_sessions: [summary()], history_cursor: 5}
    assert is_map(History.render(model))
  end
end
