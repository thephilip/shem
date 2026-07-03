defmodule Shem.EventLog.Chain do
  @moduledoc """
  Per-session hash chain over EventLog events.

  Each event's hash commits to the previous hash and the event's identity,
  type, payload, and timestamp — so any retroactive edit breaks every
  subsequent link. Legacy events (hash: nil) from before the chain existed
  are tolerated as an unverifiable prefix; a nil hash appearing AFTER a
  hashed event is a break.

  Canonical form uses `:erlang.term_to_binary/2` with `:deterministic`; chains
  are local-only and not guaranteed stable across major OTP version upgrades.
  Chains recorded before the `:deterministic` canonicalization (pre-2026-07-03)
  do not re-verify and read as broken — re-record such sessions.
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
    # `:deterministic` is REQUIRED: without it, a payload map built in memory and
    # the same map reconstructed via binary_to_term (a DETS/Mnesia read) can
    # serialize to different bytes, so a hash committed at append time fails to
    # re-verify from a cold read in another process. That breaks cross-process
    # chain verification (e.g. `shem replay --check` on a stored golden).
    :erlang.term_to_binary(
      {e.id, e.session_id, e.type, e.payload, DateTime.to_iso8601(e.timestamp), e.parent_id},
      [:deterministic]
    )
  end
end
