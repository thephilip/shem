defmodule Shem.MCP.InvocationLog do
  @moduledoc """
  Logs every MCP `tools/call` as a `:tool_invoked` event in a dedicated
  hash-chained session — the recurrence instrument for Compounding Skills
  (ROADMAP Phase 8), same pattern as Recall's `ses_RECALL_QUERIES`.

  Args are digested, never stored: the log answers "what ran, in what order,
  how often" without ever holding argument plaintext (secret hygiene).
  Best-effort by contract: a logging failure never breaks the tool call.
  """

  require Logger

  @session "ses_TOOL_INVOCATIONS"

  @spec session_id() :: String.t()
  def session_id, do: @session

  @doc "Append a :tool_invoked event. Never raises; returns :ok always."
  @spec log(String.t(), term(), term()) :: :ok
  def log(tool, args, result) do
    outcome =
      case result do
        {:ok, _} -> :ok
        {:input_required, _} -> :ok
        _ -> :error
      end

    with {:ok, _} <- Shem.EventLog.start_session(@session),
         {:ok, _} <-
           Shem.EventLog.append(@session, :tool_invoked, %{
             tool: tool,
             args_digest: digest(args),
             outcome: outcome
           }) do
      :ok
    else
      err ->
        Logger.warning("invocation log append failed: #{inspect(err)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("invocation log append raised: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("invocation log append exited: #{inspect(reason)}")
      :ok
  end

  # ponytail: term_to_binary map ordering is deterministic per value, which is
  # all recurrence mining needs; switch to canonical JSON if digests must ever
  # be compared across OTP releases.
  defp digest(args) do
    :crypto.hash(:sha256, :erlang.term_to_binary(args))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
