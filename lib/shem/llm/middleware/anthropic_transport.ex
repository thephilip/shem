defmodule Shem.LLM.Middleware.AnthropicTransport do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(request, opts, _next) do
    api_key = Keyword.get(opts, :api_key, System.get_env("ANTHROPIC_API_KEY"))

    if is_nil(api_key) or api_key == "" do
      {:error, {:transport, :missing_api_key}}
    else
      http_post = Keyword.get(opts, :http_post_fn, &Req.post/2)
      timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
      model_string = Keyword.get(opts, :model_string, "claude-sonnet-4-6")
      max_tokens = Map.get(request.options, :max_tokens, 512)
      base_url = Keyword.get(opts, :base_url, "https://api.anthropic.com")

      {body_messages, maybe_system} =
        case request.messages do
          nil ->
            {[%{"role" => "user", "content" => request.prompt}], nil}

          msgs ->
            formatted = Enum.map(msgs, &format_message/1)
            {formatted, request.system}
        end

      base_body = %{
        "model" => model_string,
        "messages" => body_messages,
        "max_tokens" => max_tokens
      }

      body = if maybe_system, do: Map.put(base_body, "system", maybe_system), else: base_body

      tools_fields =
        case request.tools do
          nil ->
            %{}

          tools ->
            %{
              "tools" =>
                Enum.map(tools, fn %{name: n, description: d, schema: s} ->
                  %{"name" => n, "description" => d, "input_schema" => s}
                end)
            }
        end

      body = Map.merge(body, tools_fields)

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ]

      start_ms = System.monotonic_time(:millisecond)

      case http_post.(base_url <> "/v1/messages",
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

  defp format_message(%{role: :assistant, tool_calls: calls} = msg) when not is_nil(calls) do
    c = Map.get(msg, :content)
    text_blocks = if c && c != "", do: [%{"type" => "text", "text" => c}], else: []

    call_blocks =
      Enum.map(calls, fn %{id: id, name: n, args: a} ->
        %{"type" => "tool_use", "id" => id, "name" => n, "input" => a}
      end)

    %{"role" => "assistant", "content" => text_blocks ++ call_blocks}
  end

  defp format_message(%{role: :tool, content: c, tool_call_id: id}) do
    %{
      "role" => "user",
      "content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => c}]
    }
  end

  defp format_message(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end

  defp parse_response(
         %{"content" => content_blocks, "usage" => usage},
         model,
         start_ms
       )
       when is_list(content_blocks) do
    tokens_used = Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
    latency_ms = System.monotonic_time(:millisecond) - start_ms

    text =
      content_blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("", & &1["text"])

    content = if text == "", do: nil, else: text

    raw_tool_calls = Enum.filter(content_blocks, &(&1["type"] == "tool_use"))

    tool_calls =
      case raw_tool_calls do
        [] ->
          nil

        calls ->
          Enum.map(calls, fn %{"id" => id, "name" => n, "input" => a} ->
            %{id: id, name: n, args: a}
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
