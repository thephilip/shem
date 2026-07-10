defmodule Shem.TurnToken do
  @moduledoc """
  Integrity-protected co-driver turn tokens (and MRTR `requestState`).

  Wire format: `base64url(payload) <> "." <> base64url(hmac_sha256(secret, payload))`
  with `payload = "session_id|turn|nonce|exp_unix"`. Binds the parked agent's
  session id, the awaited turn, and a short expiry — a forged, tampered,
  cross-agent, or expired token fails `decode/1`.

  Tokens are minted fresh on every status read, so the TTL never strands a
  long-parked agent: re-polling yields a new token.
  """

  @ttl_seconds 900

  # ponytail: per-boot node-local secret — parked turns live in agent GenServer
  # state and die with the node, so tokens never outlive a boot. A multi-node
  # front door would need a shared secret from config; add when one exists.
  defp secret do
    case :persistent_term.get({__MODULE__, :secret}, nil) do
      nil ->
        s = :crypto.strong_rand_bytes(32)
        :persistent_term.put({__MODULE__, :secret}, s)
        s

      s ->
        s
    end
  end

  @spec encode(String.t(), {integer(), integer()}, keyword()) :: String.t()
  def encode(session_id, {turn, nonce}, opts \\ []) do
    exp = System.system_time(:second) + Keyword.get(opts, :ttl, @ttl_seconds)
    payload = "#{session_id}|#{turn}|#{nonce}|#{exp}"

    Base.url_encode64(payload, padding: false) <>
      "." <> Base.url_encode64(sign(payload), padding: false)
  end

  @spec decode(any()) ::
          {:ok, String.t(), {integer(), integer()}} | {:error, :invalid} | {:error, :expired}
  def decode(token) when is_binary(token) do
    with [p64, s64] <- String.split(token, "."),
         {:ok, payload} <- Base.url_decode64(p64, padding: false),
         {:ok, sig} <- Base.url_decode64(s64, padding: false),
         true <- valid_sig?(payload, sig),
         [sid, t, n, e] <- String.split(payload, "|"),
         {turn, ""} <- Integer.parse(t),
         {nonce, ""} <- Integer.parse(n),
         {exp, ""} <- Integer.parse(e) do
      if exp >= System.system_time(:second),
        do: {:ok, sid, {turn, nonce}},
        else: {:error, :expired}
    else
      _ -> {:error, :invalid}
    end
  end

  def decode(_), do: {:error, :invalid}

  defp sign(payload), do: :crypto.mac(:hmac, :sha256, secret(), payload)

  # :crypto.hash_equals raises on unequal sizes — guard first.
  defp valid_sig?(payload, sig),
    do: byte_size(sig) == 32 and :crypto.hash_equals(sign(payload), sig)
end
