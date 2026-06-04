defmodule Shem.LLM.Middleware.EventLogger do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(%{session_id: nil} = request, _opts, next), do: next.(request)

  def call(request, _opts, next) do
    Shem.EventLog.append(request.session_id, :llm_call_started, %{
      model: request.model,
      prompt: request.prompt
    })

    start_ms = System.monotonic_time(:millisecond)
    result = next.(request)
    latency_ms = System.monotonic_time(:millisecond) - start_ms

    case result do
      {:ok, response} ->
        Shem.EventLog.append(request.session_id, :llm_call_completed, %{
          tokens_used: response.tokens_used,
          latency_ms: latency_ms,
          content: response.content
        })

      {:error, reason} ->
        Shem.EventLog.append(request.session_id, :llm_call_failed, %{
          reason: inspect(reason)
        })
    end

    result
  end
end
