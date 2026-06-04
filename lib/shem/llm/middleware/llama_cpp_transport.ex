defmodule Shem.LLM.Middleware.LlamaCppTransport do
  @behaviour Shem.LLM.Middleware

  require Logger

  @impl true
  def call(request, opts, _next) do
    url = Keyword.get(opts, :url, Application.get_env(:shem, :llm_llama_cpp_url, "http://localhost:8080"))
    http_post = Keyword.get(opts, :http_post_fn, &Req.post/2)
    timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))

    body = %{
      "model" => resolve_model(request.model),
      "prompt" => request.prompt,
      "max_tokens" => Map.get(request.options, :max_tokens, 512),
      "stream" => false
    }

    start_ms = System.monotonic_time(:millisecond)

    case http_post.(url <> "/v1/completions", json: body, receive_timeout: timeout_ms) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_response(resp_body, request.model, start_ms)

      {:ok, %{status: status}} ->
        {:error, {:transport, {:http_error, status}}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp resolve_model(model_atom) do
    models = Application.get_env(:shem, :llm_models, %{})

    case Map.get(models, model_atom) do
      nil ->
        Logger.warning("Unknown LLM model atom #{inspect(model_atom)}, falling back to string")
        Atom.to_string(model_atom)

      str ->
        str
    end
  end

  defp parse_response(
         %{"choices" => [%{"text" => content} | _], "usage" => usage},
         model,
         start_ms
       ) do
    tokens_used =
      Map.get(usage, "completion_tokens", 0) + Map.get(usage, "prompt_tokens", 0)

    latency_ms = System.monotonic_time(:millisecond) - start_ms

    {:ok,
     %Shem.LLM.Response{
       content: content,
       tokens_used: tokens_used,
       model: model,
       latency_ms: latency_ms
     }}
  end

  defp parse_response(raw_body, _model, _start_ms) do
    {:error, {:parse_error, raw_body}}
  end
end
