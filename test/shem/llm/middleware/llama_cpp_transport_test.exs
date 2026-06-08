defmodule Shem.LLM.Middleware.LlamaCppTransportTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.Middleware.LlamaCppTransport
  alias Shem.LLM.{Request, Response}

  defp req(model \\ :default), do: %Request{prompt: "hello", model: model}

  defp mock_post(status, body) do
    fn _url, _opts -> {:ok, %{status: status, body: body}} end
  end

  defp success_body(content, tokens) do
    %{
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{"completion_tokens" => tokens, "prompt_tokens" => 5}
    }
  end

  describe "call/3 — success" do
    test "returns Response with content, tokens_used, and latency_ms" do
      opts = [
        url: "http://localhost:8080",
        http_post_fn: mock_post(200, success_body("Hello", 20))
      ]
      assert {:ok, %Response{} = resp} = LlamaCppTransport.call(req(), opts, nil)
      assert resp.content == "Hello"
      assert resp.tokens_used == 25  # completion(20) + prompt(5)
      assert resp.latency_ms >= 0
      assert resp.model == :default
    end
  end

  describe "call/3 — /v1/chat/completions endpoint" do
    test "uses /v1/chat/completions endpoint" do
      mock = fn url, _opts ->
        assert String.ends_with?(url, "/v1/chat/completions")
        {:ok, %{status: 200, body: success_body("hi", 5)}}
      end
      opts = [url: "http://localhost:8080", http_post_fn: mock]
      assert {:ok, %Response{}} = LlamaCppTransport.call(req(), opts, nil)
    end

    test "wraps prompt as user message when request.messages nil" do
      mock = fn _url, opts ->
        msgs = opts[:json]["messages"]
        assert msgs == [%{"role" => "user", "content" => "hello"}]
        {:ok, %{status: 200, body: success_body("hi", 5)}}
      end
      opts = [url: "http://localhost:8080", http_post_fn: mock]
      assert {:ok, %Response{}} = LlamaCppTransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — tools" do
    test "injects tools with function wrapper and tool_choice when request.tools present" do
      tools = [%{name: "run_code", description: "Run Elixir", schema: %{"type" => "object", "properties" => %{}, "required" => []}}]
      request = %Request{prompt: "go", model: :default, tools: tools}

      mock = fn _url, opts ->
        body = opts[:json]
        assert body["tool_choice"] == "auto"
        [tool] = body["tools"]
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "run_code"
        {:ok, %{status: 200, body: success_body("ok", 5)}}
      end

      opts = [url: "http://localhost:8080", http_post_fn: mock]
      assert {:ok, %Response{}} = LlamaCppTransport.call(request, opts, nil)
    end
  end

  describe "call/3 — tool_calls in response" do
    test "decodes tool_calls from response, content may be nil" do
      body = %{
        "choices" => [%{"message" => %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [%{
            "id" => "call_abc",
            "type" => "function",
            "function" => %{"name" => "run_code", "arguments" => "{\"source\":\"IO.puts 1\"}"}
          }]
        }}],
        "usage" => %{"completion_tokens" => 10, "prompt_tokens" => 5}
      }

      opts = [url: "http://localhost:8080", http_post_fn: mock_post(200, body)]
      assert {:ok, %Response{} = resp} = LlamaCppTransport.call(req(), opts, nil)
      assert resp.content == nil
      assert [%{id: "call_abc", name: "run_code", args: %{"source" => "IO.puts 1"}}] = resp.tool_calls
    end
  end

  describe "call/3 — HTTP errors" do
    test "500 returns {:error, {:transport, {:http_error, 500}}}" do
      opts = [url: "http://localhost:8080", http_post_fn: mock_post(500, %{})]
      assert {:error, {:transport, {:http_error, 500}}} = LlamaCppTransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — network error" do
    test "Req error returns {:error, {:transport, reason}}" do
      opts = [url: "http://localhost:8080", http_post_fn: fn _url, _opts -> {:error, :timeout} end]
      assert {:error, {:transport, :timeout}} = LlamaCppTransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — parse errors" do
    test "malformed body returns {:error, {:parse_error, _}}" do
      opts = [url: "http://localhost:8080", http_post_fn: mock_post(200, %{"unexpected" => "shape"})]
      assert {:error, {:parse_error, _}} = LlamaCppTransport.call(req(), opts, nil)
    end
  end

  describe "stream/4 — via http_stream_fn mock" do
    test "calls chunk_fn per text token and returns assembled Response" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

      http_stream_fn = fn _url, _body, cf ->
        cf.("alpha")
        cf.(" beta")
        {:ok, %Shem.LLM.Response{
          content: "alpha beta",
          tool_calls: nil,
          tokens_used: 8,
          model: :default,
          latency_ms: 0
        }}
      end

      request = %Shem.LLM.Request{prompt: "hi", model: :default}
      opts = [http_stream_fn: http_stream_fn]

      assert {:ok, %{content: "alpha beta", tokens_used: 8}} =
               LlamaCppTransport.stream(request, opts, chunk_fn, fn _, _ -> :ok end)

      assert Agent.get(collector, & &1) == ["alpha", " beta"]
    end

    test "returns tool_calls in Response" do
      http_stream_fn = fn _url, _body, _cf ->
        {:ok, %Shem.LLM.Response{
          content: nil,
          tool_calls: [%{id: "call_x", name: "shell", args: %{"cmd" => "pwd"}}],
          tokens_used: 12,
          model: :default,
          latency_ms: 0
        }}
      end

      request = %Shem.LLM.Request{prompt: "pwd", model: :default}
      opts = [http_stream_fn: http_stream_fn]

      assert {:ok, %{tool_calls: [%{name: "shell"}]}} =
               LlamaCppTransport.stream(request, opts, fn _ -> :ok end, fn _, _ -> :ok end)
    end
  end

  describe "stream/4 — SSE parser via req_fn injection" do
    test "two-chunk content stream assembles content and calls chunk_fn" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

      req_fn = fn _url, opts ->
        into_fn = opts[:into]
        {:cont, acc1} = into_fn.({:data, "data: {\"choices\":[{\"delta\":{\"content\":\"alpha\"}}]}\n\n"}, "")
        {:cont, _} = into_fn.({:data, "data: {\"choices\":[{\"delta\":{\"content\":\" beta\"}}]}\n\ndata: {\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2}}\n\n"}, acc1)
        {:ok, %{status: 200}}
      end

      request = %Shem.LLM.Request{prompt: "hi", model: :default, tools: nil}
      opts = [req_fn: req_fn]

      assert {:ok, %{content: "alpha beta", tokens_used: 6}} =
               LlamaCppTransport.stream(request, opts, chunk_fn, fn _, _ -> {:error, :no_next} end)

      assert Agent.get(collector, & &1) == ["alpha", " beta"]
    end

    test "tool call accumulation suppresses chunk_fn and decodes args" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

      req_fn = fn _url, opts ->
        into_fn = opts[:into]
        tc1 = ~s|data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"shell","arguments":""}}]}}]}\n\n|
        tc2 = ~s|data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"cmd\\":\\"pwd\\"}"}}]}}]}\n\ndata: {"usage":{"prompt_tokens":8,"completion_tokens":4}}\n\n|
        {:cont, acc} = into_fn.({:data, tc1}, "")
        {:cont, _} = into_fn.({:data, tc2}, acc)
        {:ok, %{status: 200}}
      end

      request = %Shem.LLM.Request{prompt: "pwd", model: :default, tools: nil}
      opts = [req_fn: req_fn]

      assert {:ok, %{tool_calls: [%{id: "call_1", name: "shell", args: %{"cmd" => "pwd"}}], tokens_used: 12}} =
               LlamaCppTransport.stream(request, opts, chunk_fn, fn _, _ -> {:error, :no_next} end)

      assert Agent.get(collector, & &1) == []
    end

    test "[DONE] event is ignored" do
      req_fn = fn _url, opts ->
        into_fn = opts[:into]
        {:cont, acc} = into_fn.({:data, "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"}, "")
        {:cont, _} = into_fn.({:data, "data: [DONE]\n\n"}, acc)
        {:ok, %{status: 200}}
      end

      request = %Shem.LLM.Request{prompt: "hi", model: :default, tools: nil}
      opts = [req_fn: req_fn]

      assert {:ok, %{content: "hi"}} =
               LlamaCppTransport.stream(request, opts, fn _ -> :ok end, fn _, _ -> {:error, :no_next} end)
    end
  end
end
