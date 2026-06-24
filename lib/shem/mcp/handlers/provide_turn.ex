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
         {:ok, token} <- decode_token(valid["turn_token"]),
         {:ok, name} <- find(valid["agent_id"]) do
      case Shem.Agent.provide_turn(name, token, valid["content"]) do
        {:ok, %{status: :awaiting_turn, prompt: p, turn_token: t}} ->
          {:ok, %{"status" => "awaiting_turn", "prompt" => p, "turn_token" => encode_token(t)}}

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

  @spec encode_token({integer(), integer()}) :: String.t()
  def encode_token({turn, nonce}), do: "#{turn}:#{nonce}"

  defp find(sid) do
    case AgentCommon.find_by_session(sid) do
      {:ok, name} -> {:ok, name}
      :not_found -> {:error, :not_found, "no live agent #{sid}"}
    end
  end

  defp decode_token(s) do
    case String.split(s, ":") do
      [t, n] -> {:ok, {String.to_integer(t), String.to_integer(n)}}
      _ -> {:error, :invalid_args, "bad turn_token"}
    end
  rescue
    ArgumentError -> {:error, :invalid_args, "bad turn_token"}
  end
end
