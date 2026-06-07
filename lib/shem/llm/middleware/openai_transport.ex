defmodule Shem.LLM.Middleware.OpenAITransport do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(request, opts, _next) do
    api_key = Keyword.get(opts, :api_key, System.get_env("OPENAI_API_KEY"))

    if is_nil(api_key) or api_key == "" do
      {:error, {:transport, :missing_api_key}}
    else
      base_url = Keyword.get(opts, :base_url, "https://api.openai.com")
      http_post = Keyword.get(opts, :http_post_fn, &Req.post/2)
      timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
      model_string = Keyword.get(opts, :model_string, "gpt-4o")
      max_tokens = Map.get(request.options, :max_tokens, 512)

      messages =
        case request.messages do
          nil ->
            [%{"role" => "user", "content" => request.prompt}]

          msgs ->
            system_msgs =
              if request.system do
                [%{"role" => "system", "content" => request.system}]
              else
                []
              end

            formatted = Enum.map(msgs, &format_message/1)

            system_msgs ++ formatted
        end

      base_body = %{
        "model" => model_string,
        "messages" => messages,
        "max_tokens" => max_tokens
      }

      tools_fields =
        case request.tools do
          nil ->
            %{}

          tools ->
            %{
              "tools" =>
                Enum.map(tools, fn %{name: n, description: d, schema: s} ->
                  %{"type" => "function", "function" => %{"name" => n, "description" => d, "parameters" => s}}
                end),
              "tool_choice" => "auto"
            }
        end

      body = Map.merge(base_body, tools_fields)

      headers = [{"authorization", "Bearer #{api_key}"}]
      start_ms = System.monotonic_time(:millisecond)

      case http_post.(base_url <> "/v1/chat/completions",
             json: body,
             headers: headers,
             receive_timeout: timeout_ms
           ) do
        {:ok, %{status: 200, body: resp_body}} ->
          parse_response(resp_body, request.model, start_ms)

        {:ok, %{status: 401}} ->
          {:error, {:transport, :unauthorized}}

        {:ok, %{status: 429}} ->
          {:error, {:transport, :rate_limited}}

        {:ok, %{status: status}} ->
          {:error, {:transport, {:http_error, status}}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end

  defp format_message(%{role: :assistant, content: c, tool_calls: calls}) do
    %{
      "role" => "assistant",
      "content" => c,
      "tool_calls" =>
        Enum.map(calls, fn %{id: id, name: n, args: a} ->
          %{
            "id" => id,
            "type" => "function",
            "function" => %{"name" => n, "arguments" => Jason.encode!(a)}
          }
        end)
    }
  end

  defp format_message(%{role: :tool, content: c, tool_call_id: id}) do
    %{"role" => "tool", "tool_call_id" => id, "content" => c}
  end

  defp format_message(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end

  defp parse_response(
         %{"choices" => [%{"message" => message} | _], "usage" => usage},
         model,
         start_ms
       ) do
    tokens_used = Map.get(usage, "total_tokens", 0)
    latency_ms = System.monotonic_time(:millisecond) - start_ms
    content = message["content"]

    tool_calls =
      case message["tool_calls"] do
        nil ->
          nil

        raw ->
          Enum.map(raw, fn %{"id" => id, "function" => %{"name" => n, "arguments" => args_str}} ->
            %{id: id, name: n, args: Jason.decode!(args_str)}
          end)
      end

    {:ok,
     %Shem.LLM.Response{
       content: content,
       tool_calls: tool_calls,
       tokens_used: tokens_used,
       model: model,
       latency_ms: latency_ms
     }}
  end

  defp parse_response(raw_body, _model, _start_ms) do
    {:error, {:parse_error, raw_body}}
  end
end
