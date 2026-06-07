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
end
