defmodule Shem.Lab.GraduationGate.Hardening do
  @moduledoc """
  Lightweight single-turn trust check, run at graduation.

  One LLM call reviews a freshly graduated tool's source against its declared
  description and schema — does the behavior match the schema, and would boundary
  inputs produce sensible errors? — and returns a trust score in `[0.0, 1.0]`.

  This is the cheap, automatic half of hardening. The full multi-round adversarial
  red-team loop stays opt-in via `Shem.Adversarial.start_hardening/1`.

  Never blocks graduation: if disabled or the LLM call fails, returns `:skip` and
  the caller falls back to its default trust seed.
  """
  alias Shem.LLM
  alias Shem.EventLog

  @spec check(Shem.Tool.t(), boolean()) :: {:ok, float()} | :skip
  def check(tool, enabled \\ Application.get_env(:shem, :progressive_hardening, true)) do
    if enabled, do: do_check(tool), else: :skip
  catch
    # a check must never crash a graduation
    :exit, _ -> :skip
  end

  defp do_check(tool) do
    request = %LLM.Request{
      prompt: prompt(tool),
      # ponytail: reuse the :shadow background-reasoning lane — BudgetCheck skips it
      # and the Router falls back to :default, so no new route/config is needed.
      model: :shadow,
      system: system_prompt(),
      session_id: nil,
      tools: []
    }

    with {:ok, %{content: content}} when is_binary(content) <- LLM.complete(request),
         {:ok, %{"score" => score, "reasoning" => reasoning}} <- decode_verdict(content),
         true <- is_number(score) do
      clamped = score |> max(0.0) |> min(1.0) |> Kernel./(1)
      log(tool, clamped, reasoning)
      {:ok, clamped}
    else
      _ -> :skip
    end
  end

  # Local models often wrap the JSON in prose or markdown fences. Try the whole
  # string first, then fall back to the first {...} object found. A model that
  # emits no JSON at all safely yields :error -> :skip (flat-seed fallback).
  defp decode_verdict(content) do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      _ ->
        case Regex.run(~r/\{.*\}/s, content) do
          [json] -> Jason.decode(json)
          _ -> :error
        end
    end
  end

  defp log(tool, score, reasoning) do
    {:ok, sid} = EventLog.start_session()

    EventLog.append(sid, :hardening_check, %{
      tool: tool.name,
      tool_id: tool.id,
      score: score,
      reasoning: reasoning
    })
  catch
    :exit, _ -> :ok
  end

  defp system_prompt do
    """
    You are a tool safety reviewer. You read one tool's source and its declared interface
    and judge how much to trust it. Consider: does the behavior match the declared schema?
    Would boundary or malformed inputs produce sensible errors rather than crashes or garbage?
    Score 0.0 (do not trust) to 1.0 (fully trustworthy).
    Respond with JSON only: {"score": <float>, "reasoning": "<one sentence>"}
    Do not add commentary outside the JSON.
    """
  end

  defp prompt(tool) do
    """
    Tool: #{tool.name}
    Description: #{tool.metadata["description"]}
    Schema: #{Jason.encode!(tool.metadata["schema"] || %{})}

    Source:
    #{tool.source}
    """
  end
end
