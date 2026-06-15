defmodule Shem.LLM.Middleware.OpenAITransport do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(request, opts, _next) do
    api_key =
      Keyword.get(opts, :api_key) ||
        Application.get_env(:shem, :llm_openai_api_key) ||
        System.get_env("OPENAI_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, {:transport, :missing_api_key}}
    else
      base_url =
        Keyword.get(opts, :base_url) ||
          Application.get_env(:shem, :llm_openai_base_url, "https://api.openai.com")
      http_post = Keyword.get(opts, :http_post_fn, &Req.post/2)
      timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
      model_string = Keyword.get(opts, :model_string, "gpt-4o")
      max_tokens = Map.get(request.options, :max_tokens, Application.get_env(:shem, :llm_max_tokens, 512))

      messages = build_messages(request)

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

  @impl true
  def stream(request, opts, chunk_fn, _next) do
    api_key =
      Keyword.get(opts, :api_key) ||
        Application.get_env(:shem, :llm_openai_api_key) ||
        System.get_env("OPENAI_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, {:transport, :missing_api_key}}
    else
      base_url =
        Keyword.get(opts, :base_url) ||
          Application.get_env(:shem, :llm_openai_base_url, "https://api.openai.com")
      timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
      model_string = Keyword.get(opts, :model_string, "gpt-4o")
      max_tokens = Map.get(request.options, :max_tokens, Application.get_env(:shem, :llm_max_tokens, 512))

      messages = build_messages(request)

      base_body = %{
        "model" => model_string,
        "messages" => messages,
        "max_tokens" => max_tokens,
        "stream" => true,
        "stream_options" => %{"include_usage" => true}
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

      req_fn = Keyword.get(opts, :req_fn, &Req.post/2)

      http_stream =
        Keyword.get(opts, :http_stream_fn, fn url, b, cf ->
          do_sse_stream_openai(url, b, headers, timeout_ms, request.model, cf, req_fn)
        end)

      http_stream.(base_url <> "/v1/chat/completions", body, chunk_fn)
    end
  end

  defp build_messages(request) do
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
  end

  defp do_sse_stream_openai(url, body, headers, timeout_ms, model, chunk_fn, req_fn) do
    start_ms = System.monotonic_time(:millisecond)
    ref = make_ref()

    Process.put(ref, %{
      buf: "",
      content: "",
      tool_calls: %{},
      tool_cut: false,
      prompt_tokens: 0,
      completion_tokens: 0
    })

    try do
      result =
        req_fn.(url,
          json: body,
          headers: headers,
          receive_timeout: timeout_ms,
          into: fn {:data, data}, acc ->
            st = process_openai_data(data, Process.get(ref), chunk_fn)
            Process.put(ref, st)
            {:cont, acc}
          end
        )

      final = Process.get(ref)
      latency_ms = System.monotonic_time(:millisecond) - start_ms

      case result do
        {:ok, %{status: 200}} ->
          assemble_openai_response(final, model, latency_ms)

        {:ok, %{status: 401}} ->
          {:error, {:transport, :unauthorized}}

        {:ok, %{status: 429}} ->
          {:error, {:transport, :rate_limited}}

        {:ok, %{status: status}} ->
          {:error, {:transport, {:http_error, status}}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    after
      Process.delete(ref)
    end
  end

  defp process_openai_data(data, state, chunk_fn) do
    {events, new_buf} = split_sse_events(state.buf <> data)

    Enum.reduce(events, %{state | buf: new_buf}, fn event, acc ->
      process_openai_event(event, acc, chunk_fn)
    end)
  end

  defp split_sse_events(buffer) do
    parts = String.split(buffer, "\n\n")

    case parts do
      [single] ->
        {[], single}

      _ ->
        events = parts |> Enum.slice(0..-2//1) |> Enum.reject(&(&1 == ""))
        {events, List.last(parts)}
    end
  end

  defp process_openai_event(event, state, chunk_fn) do
    data_line =
      event
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "data: "))

    case data_line do
      nil ->
        state

      "data: [DONE]" ->
        state

      "data: " <> json_str ->
        case Jason.decode(json_str) do
          {:ok, decoded} -> apply_openai_chunk(decoded, state, chunk_fn)
          _ -> state
        end
    end
  end

  defp apply_openai_chunk(%{"choices" => [%{"delta" => delta} | _]} = msg, state, chunk_fn) do
    state =
      case delta do
        %{"content" => content} when is_binary(content) and content != "" ->
          unless state.tool_cut, do: chunk_fn.(content)
          %{state | content: state.content <> content}

        %{"tool_calls" => raw_calls} ->
          Enum.reduce(raw_calls, %{state | tool_cut: true}, fn
            %{"index" => idx} = tc, acc ->
              existing = Map.get(acc.tool_calls, idx, %{id: nil, name: nil, args_buf: ""})

              updated = %{
                id: Map.get(tc, "id", existing.id),
                name: get_in(tc, ["function", "name"]) || existing.name,
                args_buf: existing.args_buf <> (get_in(tc, ["function", "arguments"]) || "")
              }

              %{acc | tool_calls: Map.put(acc.tool_calls, idx, updated)}
          end)

        _ ->
          state
      end

    case Map.get(msg, "usage") do
      nil ->
        state

      usage ->
        %{state |
          prompt_tokens: Map.get(usage, "prompt_tokens", state.prompt_tokens),
          completion_tokens: Map.get(usage, "completion_tokens", state.completion_tokens)}
    end
  end

  defp apply_openai_chunk(%{"usage" => usage}, state, _chunk_fn) do
    %{state |
      prompt_tokens: Map.get(usage, "prompt_tokens", state.prompt_tokens),
      completion_tokens: Map.get(usage, "completion_tokens", state.completion_tokens)}
  end

  defp apply_openai_chunk(_decoded, state, _chunk_fn), do: state

  defp assemble_openai_response(final, model, latency_ms) do
    tokens_used = final.prompt_tokens + final.completion_tokens

    tool_calls =
      if map_size(final.tool_calls) == 0 do
        nil
      else
        final.tool_calls
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.map(fn {_, %{id: id, name: name, args_buf: args_buf}} ->
          args = case Jason.decode(args_buf) do
            {:ok, decoded} -> decoded
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
       latency_ms: latency_ms
     }}
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

    reasoning_content =
      case message["reasoning_content"] do
        rc when is_binary(rc) and rc != "" -> rc
        _ -> nil
      end

    tool_calls =
      case message["tool_calls"] do
        nil ->
          nil

        raw ->
          Enum.map(raw, fn %{"id" => id, "function" => %{"name" => n, "arguments" => args_str}} ->
            args = case Jason.decode(args_str) do
              {:ok, decoded} -> decoded
              {:error, _} -> %{}
            end
            %{id: id, name: n, args: args}
          end)
      end

    {:ok,
     %Shem.LLM.Response{
       content: content,
       tool_calls: tool_calls,
       reasoning_content: reasoning_content,
       tokens_used: tokens_used,
       model: model,
       latency_ms: latency_ms
     }}
  end

  defp parse_response(raw_body, _model, _start_ms) do
    {:error, {:parse_error, raw_body}}
  end
end
