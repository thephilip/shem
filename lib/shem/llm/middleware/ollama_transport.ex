defmodule Shem.LLM.Middleware.OllamaTransport do
  @behaviour Shem.LLM.Middleware

  require Logger

  @impl true
  def call(request, opts, _next) do
    url = Keyword.get(opts, :url, Application.get_env(:shem, :llm_ollama_url, "http://localhost:11434"))
    http_post = Keyword.get(opts, :http_post_fn, &Req.post/2)

    messages =
      case request.messages do
        nil -> [%{"role" => "user", "content" => request.prompt}]
        msgs -> Enum.map(msgs, &format_message/1)
      end

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
              end)
          }
      end

    body =
      Map.merge(
        %{
          "model" => resolve_model(request.model, opts),
          "messages" => messages,
          "stream" => false
        },
        tools_fields
      )

    start_ms = System.monotonic_time(:millisecond)

    case http_post.(url <> "/api/chat", json: body) do
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
          %{
            "id" => id,
            "type" => "function",
            "function" => %{"name" => n, "arguments" => Jason.encode!(a)}
          }
        end)
    }
  end

  defp format_message(%{role: :tool, content: c, tool_call_id: _}) do
    %{"role" => "tool", "content" => c}
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

  defp parse_response(%{"message" => message, "done" => true} = body, model, start_ms) do
    tokens_used = Map.get(body, "eval_count", 0) + Map.get(body, "prompt_eval_count", 0)
    latency_ms = System.monotonic_time(:millisecond) - start_ms
    content = message["content"]

    tool_calls =
      case message["tool_calls"] do
        nil ->
          nil

        [] ->
          nil

        raw ->
          Enum.map(raw, fn %{"function" => %{"name" => n, "arguments" => a}} ->
            %{id: "ollama_#{:erlang.unique_integer([:positive, :monotonic])}", name: n, args: a}
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
    url = Keyword.get(opts, :url, Application.get_env(:shem, :llm_ollama_url, "http://localhost:11434"))

    messages =
      case request.messages do
        nil -> [%{"role" => "user", "content" => request.prompt}]
        msgs -> Enum.map(msgs, &format_message/1)
      end

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
              end)
          }
      end

    body =
      Map.merge(
        %{
          "model" => resolve_model(request.model, opts),
          "messages" => messages,
          "stream" => true
        },
        tools_fields
      )

    req_fn = Keyword.get(opts, :req_fn, &Req.post/2)

    http_stream =
      Keyword.get(opts, :http_stream_fn, fn u, b, cf ->
        do_ollama_stream(u, b, request.model, cf, req_fn)
      end)

    http_stream.(url <> "/api/chat", body, chunk_fn)
  end

  defp do_ollama_stream(url, body, model, chunk_fn, req_fn) do
    start_ms = System.monotonic_time(:millisecond)
    ref = make_ref()

    Process.put(ref, %{
      buf: "",
      content: "",
      tool_calls: nil,
      tool_cut: false,
      eval_count: 0,
      prompt_eval_count: 0
    })

    {result, final} =
      try do
        r =
          req_fn.(url,
            json: body,
            into: fn {:data, data}, acc ->
              Process.put(ref, process_ollama_data(data, Process.get(ref), chunk_fn))
              {:cont, acc}
            end
          )

        {r, Process.get(ref)}
      after
        Process.delete(ref)
      end

    latency_ms = System.monotonic_time(:millisecond) - start_ms

    case result do
      {:ok, %{status: 200}} -> assemble_ollama_response(final, model, latency_ms)
      {:ok, %{status: status}} -> {:error, {:transport, {:http_error, status}}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp process_ollama_data(data, state, chunk_fn) do
    full = state.buf <> data
    {lines, new_buf} = split_ndjson_lines(full)
    Enum.reduce(lines, %{state | buf: new_buf}, &process_ollama_line(&1, &2, chunk_fn))
  end

  defp split_ndjson_lines(buffer) do
    parts = String.split(buffer, "\n")

    case parts do
      [single] ->
        {[], single}

      _ ->
        lines = parts |> Enum.slice(0..-2//1) |> Enum.reject(&(&1 == ""))
        {lines, List.last(parts)}
    end
  end

  defp process_ollama_line(line, state, chunk_fn) do
    case Jason.decode(line) do
      {:ok, %{"done" => false, "message" => %{"content" => content}}}
      when is_binary(content) and content != "" ->
        unless state.tool_cut, do: chunk_fn.(content)
        %{state | content: state.content <> content}

      {:ok, %{"done" => true} = msg} ->
        raw_calls = get_in(msg, ["message", "tool_calls"])

        tool_calls =
          case raw_calls do
            nil ->
              nil

            [] ->
              nil

            calls ->
              Enum.map(calls, fn %{"function" => %{"name" => n, "arguments" => a}} ->
                %{
                  id: "ollama_#{:erlang.unique_integer([:positive, :monotonic])}",
                  name: n,
                  args: a
                }
              end)
          end

        %{state
          | tool_calls: tool_calls,
            tool_cut: not is_nil(tool_calls),
            eval_count: Map.get(msg, "eval_count", 0),
            prompt_eval_count: Map.get(msg, "prompt_eval_count", 0)}

      _ ->
        state
    end
  end

  defp assemble_ollama_response(final, model, latency_ms) do
    tokens_used = final.eval_count + final.prompt_eval_count
    content = if final.content == "", do: nil, else: final.content

    {:ok,
     %Shem.LLM.Response{
       content: content,
       tool_calls: final.tool_calls,
       tokens_used: tokens_used,
       model: model,
       latency_ms: latency_ms
     }}
  end
end
