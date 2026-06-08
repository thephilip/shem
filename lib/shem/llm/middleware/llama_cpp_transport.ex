defmodule Shem.LLM.Middleware.LlamaCppTransport do
  @behaviour Shem.LLM.Middleware

  require Logger

  @impl true
  def call(request, opts, _next) do
    url = Keyword.get(opts, :url, Application.get_env(:shem, :llm_llama_cpp_url, "http://localhost:8080"))
    http_post = Keyword.get(opts, :http_post_fn, &Req.post/2)
    timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))

    messages =
      case request.messages do
        nil -> [%{"role" => "user", "content" => request.prompt}]
        msgs -> Enum.map(msgs, &format_message/1)
      end

    base_body = %{
      "model" => resolve_model(request.model, opts),
      "messages" => messages,
      "max_tokens" => Map.get(request.options, :max_tokens, 512)
    }

    tools_fields =
      case request.tools do
        nil ->
          %{}

        tools ->
          %{
            "tools" =>
              Enum.map(tools, fn %{name: n, description: d, schema: s} ->
                %{
                  "type" => "function",
                  "function" => %{"name" => n, "description" => d, "parameters" => s}
                }
              end),
            "tool_choice" => "auto"
          }
      end

    body = Map.merge(base_body, tools_fields)

    start_ms = System.monotonic_time(:millisecond)

    case http_post.(url <> "/v1/chat/completions", json: body, receive_timeout: timeout_ms) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_response(resp_body, request.model, start_ms)

      {:ok, %{status: status}} ->
        {:error, {:transport, {:http_error, status}}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp format_message(%{role: :assistant, content: c, tool_calls: calls}) do
    %{
      "role" => "assistant",
      "content" => c,
      "tool_calls" =>
        Enum.map(calls, fn %{id: id, name: n, args: a} ->
          %{"id" => id, "type" => "function", "function" => %{"name" => n, "arguments" => Jason.encode!(a)}}
        end)
    }
  end

  defp format_message(%{role: :tool, content: c, tool_call_id: id}) do
    %{"role" => "tool", "tool_call_id" => id, "content" => c}
  end

  defp format_message(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end

  defp resolve_model(model_atom, opts) do
    case Keyword.fetch(opts, :model_string) do
      {:ok, str} ->
        str

      :error ->
        models = Application.get_env(:shem, :llm_models, %{})

        case Map.get(models, model_atom) do
          nil ->
            Logger.warning("Unknown LLM model atom #{inspect(model_atom)}, falling back to string")
            Atom.to_string(model_atom)

          str ->
            str
        end
    end
  end

  defp parse_response(
         %{"choices" => [%{"message" => message} | _], "usage" => usage},
         model,
         start_ms
       ) do
    tokens_used =
      Map.get(usage, "completion_tokens", 0) + Map.get(usage, "prompt_tokens", 0)

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

  @impl true
  def stream(request, opts, chunk_fn, _next) do
    url = Keyword.get(opts, :url, Application.get_env(:shem, :llm_llama_cpp_url, "http://localhost:8080"))
    timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
    max_tokens = Map.get(request.options, :max_tokens, 512)

    messages =
      case request.messages do
        nil -> [%{"role" => "user", "content" => request.prompt}]
        msgs -> Enum.map(msgs, &format_message/1)
      end

    base_body = %{
      "model" => resolve_model(request.model, opts),
      "messages" => messages,
      "max_tokens" => max_tokens,
      "stream" => true,
      "stream_options" => %{"include_usage" => true}
    }

    tools_fields =
      case request.tools do
        nil -> %{}
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
    req_fn = Keyword.get(opts, :req_fn, &Req.post/2)

    http_stream =
      Keyword.get(opts, :http_stream_fn, fn u, b, cf ->
        do_sse_stream_llama(u, b, timeout_ms, request.model, cf, req_fn)
      end)

    http_stream.(url <> "/v1/chat/completions", body, chunk_fn)
  end

  defp do_sse_stream_llama(url, body, timeout_ms, model, chunk_fn, req_fn) do
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

    {result, final} =
      try do
        r = req_fn.(url,
          json: body,
          receive_timeout: timeout_ms,
          into: fn {:data, data}, acc ->
            Process.put(ref, process_llama_sse_data(data, Process.get(ref), chunk_fn))
            {:cont, acc}
          end
        )
        {r, Process.get(ref)}
      after
        Process.delete(ref)
      end

    latency_ms = System.monotonic_time(:millisecond) - start_ms

    case result do
      {:ok, %{status: 200}} -> assemble_llama_response(final, model, latency_ms)
      {:ok, %{status: status}} -> {:error, {:transport, {:http_error, status}}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp process_llama_sse_data(data, state, chunk_fn) do
    {events, new_buf} = split_llama_sse_events(state.buf <> data)
    Enum.reduce(events, %{state | buf: new_buf}, &process_llama_event(&1, &2, chunk_fn))
  end

  defp split_llama_sse_events(buffer) do
    parts = String.split(buffer, "\n\n")
    case parts do
      [single] -> {[], single}
      _ ->
        events = parts |> Enum.slice(0..-2//1) |> Enum.reject(&(&1 == ""))
        {events, List.last(parts)}
    end
  end

  defp process_llama_event(event, state, chunk_fn) do
    data_line = event |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "data: "))
    case data_line do
      nil -> state
      "data: [DONE]" -> state
      "data: " <> json_str ->
        case Jason.decode(json_str) do
          {:ok, decoded} -> apply_llama_chunk(decoded, state, chunk_fn)
          _ -> state
        end
    end
  end

  defp apply_llama_chunk(%{"choices" => [%{"delta" => delta} | _]} = msg, state, chunk_fn) do
    state =
      case delta do
        %{"content" => content} when is_binary(content) and content != "" ->
          unless state.tool_cut, do: chunk_fn.(content)
          %{state | content: state.content <> content}

        %{"tool_calls" => raw_calls} ->
          Enum.reduce(raw_calls, %{state | tool_cut: true}, fn %{"index" => idx} = tc, acc ->
            existing = Map.get(acc.tool_calls, idx, %{id: nil, name: nil, args_buf: ""})
            updated = %{
              id: Map.get(tc, "id", existing.id),
              name: get_in(tc, ["function", "name"]) || existing.name,
              args_buf: existing.args_buf <> (get_in(tc, ["function", "arguments"]) || "")
            }
            %{acc | tool_calls: Map.put(acc.tool_calls, idx, updated)}
          end)

        _ -> state
      end

    case Map.get(msg, "usage") do
      nil -> state
      usage ->
        %{state |
          prompt_tokens: Map.get(usage, "prompt_tokens", state.prompt_tokens),
          completion_tokens: Map.get(usage, "completion_tokens", state.completion_tokens)}
    end
  end

  defp apply_llama_chunk(%{"usage" => usage}, state, _cf) do
    %{state |
      prompt_tokens: Map.get(usage, "prompt_tokens", state.prompt_tokens),
      completion_tokens: Map.get(usage, "completion_tokens", state.completion_tokens)}
  end

  defp apply_llama_chunk(_decoded, state, _cf), do: state

  defp assemble_llama_response(final, model, latency_ms) do
    tokens_used = final.prompt_tokens + final.completion_tokens

    tool_calls =
      if map_size(final.tool_calls) == 0 do
        nil
      else
        final.tool_calls
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.map(fn {_, %{id: id, name: name, args_buf: args_buf}} ->
          args = case Jason.decode(args_buf) do
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
       latency_ms: latency_ms
     }}
  end
end
