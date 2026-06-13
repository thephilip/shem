defmodule Shem.EventLog.Chain do
  @moduledoc """
  Per-session hash chain over EventLog events.

  Each event's hash commits to the previous hash and the event's identity,
  type, payload, and timestamp — so any retroactive edit breaks every
  subsequent link. Legacy events (hash: nil) from before the chain existed
  are tolerated as an unverifiable prefix; a nil hash appearing AFTER a
  hashed event is a break.
  """

  alias Shem.EventLog.Event

  @spec genesis(String.t()) :: String.t()
  def genesis(session_id) do
    Base.encode16(:crypto.hash(:sha256, session_id))
  end

  @spec next(String.t(), Event.t()) :: String.t()
  def next(prev_hash, %Event{} = event) do
    Base.encode16(:crypto.hash(:sha256, prev_hash <> canonical(event)))
  end

  @spec verify([Event.t()], String.t()) ::
          {:ok, :verified | :legacy, non_neg_integer()}
          | {:error, {:broken_at, String.t()}}
  def verify(events, session_id) do
    {_legacy_prefix, hashed} = Enum.split_while(events, &is_nil(&1.hash))

    case hashed do
      [] -> {:ok, :legacy, length(events)}
      _ -> walk(hashed, genesis(session_id), length(events))
    end
  end

  defp walk([], _prev, total), do: {:ok, :verified, total}

  defp walk([%Event{hash: nil} = e | _rest], _prev, _total),
    do: {:error, {:broken_at, e.id}}

  defp walk([e | rest], prev, total) do
    if e.hash == next(prev, e) do
      walk(rest, e.hash, total)
    else
      {:error, {:broken_at, e.id}}
    end
  end

  defp canonical(%Event{} = e) do
    :erlang.term_to_binary({e.id, e.session_id, e.type, e.payload, DateTime.to_iso8601(e.timestamp)})
  end
end
