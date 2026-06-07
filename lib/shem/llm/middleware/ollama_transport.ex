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
end
