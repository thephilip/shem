defmodule Shem.Recall.Scanner do
  @moduledoc """
  Corpus enumeration for Recall: session DETS files under the configured
  `event_log_path`, read via `Shem.EventLog.read_session_events/1` — never a
  direct DETS open (the HistoryScanner pattern; DETS has no OS locking).
  """

  @query_session "ses_RECALL_QUERIES"

  @spec query_session_id() :: String.t()
  def query_session_id, do: @query_session

  @spec sessions() :: [%{session_id: String.t(), cache_key: {integer(), integer()}}]
  def sessions do
    path = event_log_path()

    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".dets"))
        |> Enum.map(&String.replace_suffix(&1, ".dets", ""))
        # Meta-sessions (recall's own queries, the MCP invocation log) are
        # instruments, not memories — never part of the corpus.
        |> Enum.reject(&(&1 in [@query_session, Shem.MCP.InvocationLog.session_id()]))
        |> Enum.flat_map(fn session_id ->
          case File.stat(Path.join(path, "#{session_id}.dets"), time: :posix) do
            {:ok, %File.Stat{mtime: mtime, size: size}} ->
              [%{session_id: session_id, cache_key: {mtime, size}}]

            {:error, _} ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @spec events(String.t()) :: {:ok, [Shem.EventLog.Event.t()]} | {:error, term()}
  def events(session_id), do: Shem.EventLog.read_session_events(session_id)

  defp event_log_path do
    Application.get_env(
      :shem,
      :event_log_path,
      Path.join([System.user_home!(), ".config", "shem", "lab", "events"])
    )
  end
end
