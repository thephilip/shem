defmodule Shem.LLM.Middleware.OllamaTransportTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.{Request, Response}
  alias Shem.LLM.Middleware.OllamaTransport

  defp request(model \\ :default) do
    %Request{prompt: "hello", model: model, options: %{}}
  end

  defp mock_post(status, body) do
    fn _url, _opts -> {:ok, %{status: status, body: body}} end
  end

  defp ollama_body(content, eval \\ 20, prompt_eval \\ 10) do
    %{
      "message" => %{"role" => "assistant", "content" => content},
      "done" => true,
      "eval_count" => eval,
      "prompt_eval_count" => prompt_eval
    }
  end

  describe "successful response" do
    test "returns {:ok, %Response{}} with parsed content" do
      http_post = mock_post(200, ollama_body("Hello world"))
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:ok, %Response{content: "Hello world"}} =
               OllamaTransport.call(request(), opts, fn _ -> :unreachable end)
    end

    test "sums eval_count and prompt_eval_count as tokens_used" do
      http_post = mock_post(200, ollama_body("hi", 20, 10))
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:ok, %Response{tokens_used: 30}} =
               OllamaTransport.call(request(), opts, fn _ -> :unreachable end)
    end

    test "response carries the request model atom" do
      http_post = mock_post(200, ollama_body("hi"))
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:ok, %Response{model: :default}} =
               OllamaTransport.call(request(:default), opts, fn _ -> :unreachable end)
    end

    test "latency_ms is a non-negative integer" do
      http_post = mock_post(200, ollama_body("hi"))
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:ok, %Response{latency_ms: ms}} =
               OllamaTransport.call(request(), opts, fn _ -> :unreachable end)

      assert is_integer(ms) and ms >= 0
    end
  end

  describe "HTTP errors" do
    test "returns {:error, {:transport, {:http_error, status}}} on non-200" do
      http_post = mock_post(503, %{})
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:error, {:transport, {:http_error, 503}}} =
               OllamaTransport.call(request(), opts, fn _ -> :unreachable end)
    end

    test "returns {:error, {:transport, reason}} when HTTP call fails" do
      http_post = fn _url, _opts -> {:error, %RuntimeError{message: "econnrefused"}} end
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:error, {:transport, _}} =
               OllamaTransport.call(request(), opts, fn _ -> :unreachable end)
    end
  end

  describe "parse errors" do
    test "returns {:error, {:parse_error, body}} on unexpected response shape" do
      http_post = mock_post(200, %{"unexpected" => "shape"})
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:error, {:parse_error, %{"unexpected" => "shape"}}} =
               OllamaTransport.call(request(), opts, fn _ -> :unreachable end)
    end
  end

  describe "model resolution" do
    test "unknown model atom falls back to string representation" do
      received_body = Agent.start_link(fn -> nil end) |> elem(1)

      http_post = fn _url, opts ->
        Agent.update(received_body, fn _ -> opts[:json] end)
        {:ok, %{status: 200, body: ollama_body("ok")}}
      end

      opts = [http_post_fn: http_post, url: "http://localhost:11434"]
      OllamaTransport.call(request(:unknown_model), opts, fn _ -> :unreachable end)

      body = Agent.get(received_body, & &1)
      assert body["model"] == "unknown_model"
    end
  end

  describe "call/3 — /api/chat" do
    test "uses /api/chat endpoint with messages array" do
      mock = fn url, opts ->
        assert String.ends_with?(url, "/api/chat")
        msgs = opts[:json]["messages"]
        assert [%{"role" => "user"}] = msgs
        {:ok, %{status: 200, body: ollama_body("hi")}}
      end

      opts = [http_post_fn: mock, url: "http://localhost:11434"]
      assert {:ok, %Response{}} = OllamaTransport.call(request(), opts, fn _ -> :unreachable end)
    end

    test "injects tools with function wrapper, no tool_choice" do
      tools = [
        %{
          name: "shell",
          description: "Run shell",
          schema: %{"type" => "object", "properties" => %{}, "required" => []}
        }
      ]

      request = %Request{prompt: "go", model: :default, options: %{}, tools: tools}

      mock = fn _url, opts ->
        body = opts[:json]
        [tool] = body["tools"]
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "shell"
        refute Map.has_key?(body, "tool_choice")
        {:ok, %{status: 200, body: ollama_body("done")}}
      end

      opts = [http_post_fn: mock, url: "http://localhost:11434"]
      assert {:ok, %Response{}} = OllamaTransport.call(request, opts, fn _ -> :unreachable end)
    end
  end

  describe "call/3 — tool_calls in response" do
    test "decodes tool_calls from message, generates synthetic IDs" do
      body = %{
        "message" => %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{"function" => %{"name" => "shell", "arguments" => %{"cmd" => "ls"}}}
          ]
        },
        "done" => true,
        "eval_count" => 10,
        "prompt_eval_count" => 5
      }

      mock = mock_post(200, body)
      opts = [http_post_fn: mock, url: "http://localhost:11434"]
      assert {:ok, %Response{} = resp} = OllamaTransport.call(request(), opts, fn _ -> :unreachable end)
      assert resp.content == nil
      [call] = resp.tool_calls
      assert call.name == "shell"
      assert call.args == %{"cmd" => "ls"}
      assert is_binary(call.id) and String.starts_with?(call.id, "ollama_")
    end
  end

  describe "call/3 — message formatting" do
    test "tool result message omits tool_call_id" do
      messages = [%{role: :tool, content: "result", tool_call_id: "ollama_123"}]
      request = %Request{prompt: "go", model: :default, options: %{}, messages: messages}

      mock = fn _url, opts ->
        [msg] = opts[:json]["messages"]
        assert msg["role"] == "tool"
        assert msg["content"] == "result"
        refute Map.has_key?(msg, "tool_call_id")
        {:ok, %{status: 200, body: ollama_body("done")}}
      end

      opts = [http_post_fn: mock, url: "http://localhost:11434"]
      assert {:ok, %Response{}} = OllamaTransport.call(request, opts, fn _ -> :unreachable end)
    end
  end

  describe "stream/4 — text response" do
    test "calls chunk_fn per non-empty chunk and returns assembled Response" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

      http_stream_fn = fn _url, _body, cf ->
        cf.("Hello")
        cf.(" there")
        {:ok, %Shem.LLM.Response{
          content: "Hello there",
          tool_calls: nil,
          tokens_used: 9,
          model: :default,
          latency_ms: 0
        }}
      end

      request = %Shem.LLM.Request{prompt: "hi", model: :default}
      opts = [http_stream_fn: http_stream_fn]

      assert {:ok, %{content: "Hello there", tokens_used: 9}} =
               OllamaTransport.stream(request, opts, chunk_fn, fn _, _ -> :ok end)

      assert Agent.get(collector, & &1) == ["Hello", " there"]
    end
  end

  describe "stream/4 — tool call" do
    test "returns tool_calls from the done chunk" do
      http_stream_fn = fn _url, _body, _cf ->
        {:ok, %Shem.LLM.Response{
          content: nil,
          tool_calls: [%{id: "ollama_1", name: "shell", args: %{"cmd" => "pwd"}}],
          tokens_used: 14,
          model: :default,
          latency_ms: 0
        }}
      end

      request = %Shem.LLM.Request{prompt: "pwd", model: :default}

      assert {:ok, %{tool_calls: [%{name: "shell"}]}} =
               OllamaTransport.stream(request, [http_stream_fn: http_stream_fn], fn _ -> :ok end, fn _, _ -> :ok end)
    end
  end

  describe "stream/4 — NDJSON parser via req_fn injection" do
    test "multi-chunk text stream assembles content and calls chunk_fn" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

      req_fn = fn _url, opts ->
        into_fn = opts[:into]
        chunks = [
          ~s|{"model":"llama3","message":{"role":"assistant","content":"Hello"},"done":false}\n|,
          ~s|{"model":"llama3","message":{"role":"assistant","content":" world"},"done":false}\n{"model":"llama3","done":true,"eval_count":5,"prompt_eval_count":3}\n|
        ]
        Enum.reduce(chunks, "", fn chunk, acc ->
          {:cont, new_acc} = into_fn.({:data, chunk}, acc)
          new_acc
        end)
        {:ok, %{status: 200}}
      end

      request = %Shem.LLM.Request{prompt: "hi", model: :default, tools: nil}
      opts = [req_fn: req_fn]

      assert {:ok, %{content: "Hello world", tokens_used: 8}} =
               OllamaTransport.stream(request, opts, chunk_fn, fn _, _ -> {:error, :no_next} end)

      assert Agent.get(collector, & &1) == ["Hello", " world"]
    end

    test "tool_calls on done:true chunk; chunk_fn suppressed" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

      req_fn = fn _url, opts ->
        into_fn = opts[:into]
        done_chunk = ~s|{"model":"llama3","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"shell","arguments":{"cmd":"ls"}}}]},"done":true,"eval_count":10,"prompt_eval_count":5}\n|
        {:cont, _} = into_fn.({:data, done_chunk}, "")
        {:ok, %{status: 200}}
      end

      request = %Shem.LLM.Request{prompt: "ls", model: :default, tools: nil}
      opts = [req_fn: req_fn]

      assert {:ok, %{tool_calls: [%{name: "shell", args: %{"cmd" => "ls"}}], tokens_used: 15}} =
               OllamaTransport.stream(request, opts, chunk_fn, fn _, _ -> {:error, :no_next} end)

      assert Agent.get(collector, & &1) == []
    end
  end
end
