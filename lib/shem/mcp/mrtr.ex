defmodule Shem.MCP.MRTR do
  @moduledoc """
  SEP-2322 multi-round-trip wrapper over the existing co-driver loop.

  Shem's co-driver loop is MRTR-native via elicitation: a client-brained
  spawn_agent parks awaiting its turn; instead of the proprietary
  agent_status/provide_turn poll, an MRTR-capable client receives an
  `InputRequiredResult` carrying an `elicitation/create` request and a signed
  `requestState` (the turn token), and retries the call with the human's
  answer. Not a second loop — a wire-format adapter over park/provide_turn.

  Sampling over MRTR is deliberately absent: deprecated by SEP-2577.
  """

  alias Shem.MCP.Handlers.{AgentCommon, SpawnAgent}

  @park_poll_ms 20
  @park_poll_attempts 100

  @doc "Initial MRTR-eligible spawn: start the agent, wait for it to park, wrap the prompt."
  def spawn_and_park(arguments) do
    with {:ok, %{"agent_id" => sid}} <- SpawnAgent.call(arguments) do
      case await_park(sid, @park_poll_attempts) do
        {:ok, prompt, tuple} ->
          {:input_required, input_required(sid, prompt, tuple)}

        :timeout ->
          # never parked in time — degrade to the classic non-blocking contract
          {:ok, %{"agent_id" => sid, "status" => "running"}}
      end
    end
  end

  @doc "Retried tools/call carrying requestState (+ inputResponses)."
  def retry(params) do
    with {:ok, sid, tuple} <- decode_state(params["requestState"]),
         {:ok, name} <- find(sid) do
      case get_in(params, ["inputResponses", "turn"]) do
        %{"action" => "accept", "content" => %{"content" => content}} when is_binary(content) ->
          provide(name, sid, tuple, content)

        %{"action" => action} when action in ["decline", "cancel"] ->
          {:ok,
           %{
             "agent_id" => sid,
             "status" => "awaiting_turn",
             "note" =>
               "turn #{action}d — agent stays parked; steer it via agent_status/provide_turn"
           }}

        _missing_or_malformed ->
          # SEP-2322 error handling: re-request the missing input, don't error
          case agent_park_info(name) do
            {:ok, prompt, live_tuple} -> {:input_required, input_required(sid, prompt, live_tuple)}
            :not_parked -> {:error, :stale_turn, "agent is not awaiting a turn"}
          end
      end
    end
  end

  defp provide(name, sid, tuple, content) do
    case Shem.Agent.provide_turn(name, tuple, content) do
      {:ok, %{status: :awaiting_turn, prompt: p, turn_token: t}} ->
        {:input_required, input_required(sid, p, t)}

      {:ok, %{status: :done, output: out}} ->
        {:ok, %{"agent_id" => sid, "status" => "done", "output" => out}}

      {:ok, %{status: :error, reason: r}} ->
        {:ok, %{"agent_id" => sid, "status" => "error", "reason" => r}}

      {:ok, %{status: :waiting, output: out}} ->
        {:ok, %{"agent_id" => sid, "status" => "waiting", "output" => out}}

      {:error, :stale_turn} ->
        {:error, :stale_turn, "requestState does not match the awaited turn"}

      {:error, :not_found} ->
        {:error, :not_found, "no live agent #{sid}"}
    end
  end

  defp input_required(sid, prompt, tuple) do
    %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "turn" => %{
          "method" => "elicitation/create",
          "params" => %{
            "mode" => "form",
            "message" => prompt,
            "requestedSchema" => %{
              "type" => "object",
              "properties" => %{
                "content" => %{
                  "type" => "string",
                  "description" =>
                    "Next turn for the agent: embed a {\"tool\":…,\"args\":…} JSON object to call a tool, or plain text to finish"
                }
              },
              "required" => ["content"]
            }
          }
        }
      },
      # the signed turn token IS the integrity-protected requestState
      # (binds agent session id + turn + nonce + expiry; SEP-2322 req. 4-5)
      "requestState" => Shem.TurnToken.encode(sid, tuple)
    }
  end

  defp decode_state(state) do
    case Shem.TurnToken.decode(state) do
      {:ok, sid, tuple} -> {:ok, sid, tuple}
      {:error, :expired} -> {:error, :invalid_args, "expired requestState"}
      {:error, :invalid} -> {:error, :invalid_args, "bad requestState"}
    end
  end

  defp find(sid) do
    case AgentCommon.find_by_session(sid) do
      {:ok, name} -> {:ok, name}
      :not_found -> {:error, :not_found, "no live agent #{sid}"}
    end
  end

  defp agent_park_info(name) do
    case Shem.Agent.info(name) do
      {:ok, %{status: :awaiting_turn, awaiting_prompt: p, turn_token: t}} -> {:ok, p, t}
      _ -> :not_parked
    end
  end

  defp await_park(_sid, 0), do: :timeout

  defp await_park(sid, attempts) do
    case AgentCommon.find_by_session(sid) do
      {:ok, name} ->
        case agent_park_info(name) do
          {:ok, prompt, tuple} ->
            {:ok, prompt, tuple}

          :not_parked ->
            Process.sleep(@park_poll_ms)
            await_park(sid, attempts - 1)
        end

      :not_found ->
        Process.sleep(@park_poll_ms)
        await_park(sid, attempts - 1)
    end
  end
end
