defmodule Shem.MCP.Handlers.ProvideTurn do
  alias Shem.MCP.Handlers.AgentCommon
  alias Shem.MCP.Schema

  @schema %{
    "agent_id" => %{"type" => "string"},
    "turn_token" => %{"type" => "string"},
    "content" => %{"type" => "string"}
  }

  @spec call(map()) :: {:ok, map()} | {:error, atom(), any()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema),
         {:ok, token} <- decode_token(valid["turn_token"], valid["agent_id"]),
         {:ok, name} <- find(valid["agent_id"]) do
      case Shem.Agent.provide_turn(name, token, valid["content"]) do
        {:ok, %{status: :awaiting_turn, prompt: p, turn_token: t}} ->
          {:ok,
           %{
             "status" => "awaiting_turn",
             "prompt" => p,
             "turn_token" => encode_token(valid["agent_id"], t)
           }}

        {:ok, %{status: :done, output: out}} ->
          {:ok, %{"status" => "done", "output" => out}}

        {:ok, %{status: :error, reason: r}} ->
          {:ok, %{"status" => "error", "reason" => r}}

        {:ok, %{status: :waiting, output: out}} ->
          {:ok, %{"status" => "waiting", "output" => out}}

        {:error, :stale_turn} ->
          {:error, :stale_turn, "turn_token does not match the awaited turn"}

        {:error, :not_found} ->
          {:error, :not_found, "no live agent #{valid["agent_id"]}"}
      end
    end
  end

  @doc "Mint the wire token for a parked turn. Shared with agent_status and the REST endpoints."
  @spec encode_token(String.t(), {integer(), integer()}) :: String.t()
  def encode_token(session_id, tuple), do: Shem.TurnToken.encode(session_id, tuple)

  defp find(sid) do
    case AgentCommon.find_by_session(sid) do
      {:ok, name} -> {:ok, name}
      :not_found -> {:error, :not_found, "no live agent #{sid}"}
    end
  end

  @doc """
  Verify a wire token against the agent it is being presented for.
  A tampered, expired, legacy-format, or cross-agent token is rejected.
  """
  def decode_token(s, expected_session_id) do
    case Shem.TurnToken.decode(s) do
      {:ok, sid, tuple} when sid == expected_session_id -> {:ok, tuple}
      {:error, :expired} -> {:error, :invalid_args, "expired turn_token"}
      _ -> {:error, :invalid_args, "bad turn_token"}
    end
  end
end
