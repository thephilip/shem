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
      model_string = Keyword.get(opts, :model_string, "claude-sonnet-5")
      max_tokens = Map.get(request.options, :max_tokens, 512)
      base_url = Keyword.get(opts, :base_url, "https://api.anthropic.com")

      {body_messages, maybe_system} =
        case request.messages do
          nil ->
            {[%{"role" => "user", "content" => request.prompt}], nil}

          msgs ->
            formatted = format_messages(msgs)
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
      body = put_cache_control(body)

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

  @impl true
  def stream(request, opts, chunk_fn, _next) do
    api_key = Keyword.get(opts, :api_key, System.get_env("ANTHROPIC_API_KEY"))

    if is_nil(api_key) or api_key == "" do
      {:error, {:transport, :missing_api_key}}
    else
      timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
      model_string = Keyword.get(opts, :model_string, "claude-sonnet-5")
      max_tokens = Map.get(request.options, :max_tokens, 512)
      base_url = Keyword.get(opts, :base_url, "https://api.anthropic.com")

      {body_messages, maybe_system} =
        case request.messages do
          nil -> {[%{"role" => "user", "content" => request.prompt}], nil}
          msgs -> {format_messages(msgs), request.system}
        end

      base_body = %{
        "model" => model_string,
        "messages" => body_messages,
        "max_tokens" => max_tokens,
        "stream" => true
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
      body = put_cache_control(body)
      headers = [{"x-api-key", api_key}, {"anthropic-version", "2023-06-01"}]
      req_fn = Keyword.get(opts, :req_fn, &Req.post/2)

      http_stream =
        Keyword.get(opts, :http_stream_fn, fn url, b, hdrs, t_ms, model, cf ->
          do_anthropic_sse(url, b, hdrs, t_ms, model, cf, req_fn)
        end)

      http_stream.(base_url <> "/v1/messages", body, headers, timeout_ms, request.model, chunk_fn)
    end
  end

  defp do_anthropic_sse(url, body, headers, timeout_ms, model, chunk_fn, req_fn) do
    start_ms = System.monotonic_time(:millisecond)
    ref = make_ref()

    Process.put(ref, %{
      buf: "",
      content: "",
      tool_calls: %{},
      tool_cut: false,
      input_tokens: 0,
      output_tokens: 0,
      cache_read: 0,
      cache_creation: 0
    })

    {result, final} =
      try do
        r =
          req_fn.(url,
            json: body,
            headers: headers,
            receive_timeout: timeout_ms,
            into: fn {:data, data}, acc ->
              Process.put(ref, process_anthropic_data(data, Process.get(ref), chunk_fn))
              {:cont, acc}
            end
          )

        {r, Process.get(ref)}
      after
        Process.delete(ref)
      end

    latency_ms = System.monotonic_time(:millisecond) - start_ms

    case result do
      {:ok, %{status: 200}} -> assemble_anthropic_response(final, model, latency_ms)
      {:ok, %{status: 401}} -> {:error, {:transport, :unauthorized}}
      {:ok, %{status: 429}} -> {:error, {:transport, :rate_limited}}
      {:ok, %{status: status}} -> {:error, {:transport, {:http_error, status}}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp process_anthropic_data(data, state, chunk_fn) do
    {events, new_buf} = split_anthropic_events(state.buf <> data)
    Enum.reduce(events, %{state | buf: new_buf}, &process_anthropic_event(&1, &2, chunk_fn))
  end

  defp split_anthropic_events(buffer) do
    parts = String.split(buffer, "\n\n")

    case parts do
      [single] ->
        {[], single}

      _ ->
        events = parts |> Enum.slice(0..-2//1) |> Enum.reject(&(&1 == ""))
        {events, List.last(parts)}
    end
  end

  defp process_anthropic_event(event, state, chunk_fn) do
    data_line =
      event
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "data: "))

    case data_line do
      nil ->
        state

      "data: " <> json_str ->
        case Jason.decode(json_str) do
          {:ok, decoded} -> apply_anthropic_chunk(decoded, state, chunk_fn)
          _ -> state
        end
    end
  end

  defp apply_anthropic_chunk(
         %{"type" => "message_start", "message" => %{"usage" => usage}},
         state,
         _cf
       ) do
    %{
      state
      | input_tokens: Map.get(usage, "input_tokens", 0),
        cache_read: Map.get(usage, "cache_read_input_tokens", 0),
        cache_creation: Map.get(usage, "cache_creation_input_tokens", 0)
    }
  end

  defp apply_anthropic_chunk(
         %{
           "type" => "content_block_start",
           "index" => idx,
           "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
         },
         state,
         _cf
       ) do
    %{
      state
      | tool_calls: Map.put(state.tool_calls, idx, %{id: id, name: name, args_buf: ""}),
        tool_cut: true
    }
  end

  defp apply_anthropic_chunk(
         %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "text_delta", "text" => text}
         },
         state,
         chunk_fn
       )
       when is_binary(text) and text != "" do
    unless state.tool_cut, do: chunk_fn.(text)
    %{state | content: state.content <> text}
  end

  defp apply_anthropic_chunk(
         %{
           "type" => "content_block_delta",
           "index" => idx,
           "delta" => %{"type" => "input_json_delta", "partial_json" => partial}
         },
         state,
         _cf
       ) do
    existing = Map.get(state.tool_calls, idx, %{id: nil, name: nil, args_buf: ""})
    updated = %{existing | args_buf: existing.args_buf <> partial}
    %{state | tool_calls: Map.put(state.tool_calls, idx, updated)}
  end

  defp apply_anthropic_chunk(%{"type" => "message_delta", "usage" => usage}, state, _cf) do
    %{state | output_tokens: Map.get(usage, "output_tokens", 0)}
  end

  defp apply_anthropic_chunk(_decoded, state, _cf), do: state

  defp assemble_anthropic_response(final, model, latency_ms) do
    tokens_used = final.input_tokens + final.output_tokens

    tool_calls =
      if map_size(final.tool_calls) == 0 do
        nil
      else
        final.tool_calls
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.map(fn {_, %{id: id, name: name, args_buf: args_buf}} ->
          args =
            case Jason.decode(args_buf) do
              {:ok, d} -> d
              {:error, _} -> %{}
            end

          %{id: id, name: name, args: args}
        end)
      end

    content = if final.content == "", do: nil, else: final.content

    {:ok,
     %Shem.LLM.Response{
       content: content,
       tool_calls: tool_calls,
       tokens_used: tokens_used,
       model: model,
       latency_ms: latency_ms,
       cache_read_input_tokens: final.cache_read,
       cache_creation_input_tokens: final.cache_creation
     }}
  end

  defp format_messages(msgs) do
    msgs
    |> Enum.chunk_by(fn m -> m[:role] == :tool end)
    |> Enum.flat_map(fn chunk ->
      case chunk do
        [%{role: :tool} | _] ->
          blocks =
            Enum.map(chunk, fn %{role: :tool, content: c, tool_call_id: id} ->
              %{"type" => "tool_result", "tool_use_id" => id, "content" => c}
            end)

          [%{"role" => "user", "content" => blocks}]

        other ->
          Enum.map(other, &format_message/1)
      end
    end)
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
    cache_read = Map.get(usage, "cache_read_input_tokens", 0)
    cache_creation = Map.get(usage, "cache_creation_input_tokens", 0)

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
       latency_ms: latency_ms,
       cache_read_input_tokens: cache_read,
       cache_creation_input_tokens: cache_creation
     }}
  end

  defp parse_response(raw_body, _model, _start_ms) do
    {:error, {:parse_error, raw_body}}
  end

  # ponytail: cache the stable prefix only. Breakpoint on system (renders after
  # tools, so it caches tools+system); fall back to the last tool when no system.
  # Sonnet 5's min cacheable prefix is 2048 tokens; shorter prompts silently
  # won't cache — degrades to prior behavior. Upgrade path: a second breakpoint
  # on the message tail if long-conversation reuse ever matters.
  defp put_cache_control(body) do
    ephemeral = %{"type" => "ephemeral"}

    cond do
      is_binary(body["system"]) and body["system"] != "" ->
        Map.put(body, "system", [
          %{"type" => "text", "text" => body["system"], "cache_control" => ephemeral}
        ])

      is_list(body["tools"]) and body["tools"] != [] ->
        Map.update!(body, "tools", fn tools ->
          List.update_at(tools, -1, &Map.put(&1, "cache_control", ephemeral))
        end)

      true ->
        body
    end
  end
end
