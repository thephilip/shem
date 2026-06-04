defmodule Shem.LLM.ReplayTransport do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(request, opts, _next) do
    server = Keyword.get(opts, :server, __MODULE__.Server)

    case Shem.LLM.ReplayTransport.Server.pop(server) do
      {:ok, %{error: reason_string}, _call_index} ->
        {:error, {:replayed_failure, reason_string}}

      {:ok, %{prompt: original_prompt, content: content, tokens_used: tokens_used}, call_index} ->
        if request.prompt != original_prompt and not is_nil(request.session_id) do
          Shem.EventLog.append(request.session_id, :llm_call_diverged, %{
            call_index: call_index,
            original_prompt: original_prompt,
            replay_prompt: request.prompt,
            recorded_content: content
          })
        end

        {:ok,
         %Shem.LLM.Response{
           content: content,
           tokens_used: tokens_used,
           model: request.model,
           latency_ms: 0
         }}

      {:exhausted, call_index} ->
        if not is_nil(request.session_id) do
          Shem.EventLog.append(request.session_id, :replay_exhausted, %{
            call_index: call_index,
            replay_prompt: request.prompt
          })
        end

        {:error, :replay_exhausted}
    end
  end
end
