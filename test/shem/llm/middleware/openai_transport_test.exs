defmodule Shem.LLM.Middleware.OpenAITransportTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.Middleware.OpenAITransport
  alias Shem.LLM.{Request, Response}

  defp req(model \\ :default), do: %Request{prompt: "hello", model: model}

  defp mock_post(status, body) do
    fn _url, _opts -> {:ok, %{status: status, body: body}} end
  end

  defp success_body(content, tokens) do
    %{
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{"total_tokens" => tokens}
    }
  end

  describe "call/3 — success" do
    test "returns Response with content, tokens_used, and latency_ms" do
      opts = [
        model_string: "gpt-4o",
        api_key: "sk-test",
        http_post_fn: mock_post(200, success_body("Hello", 20))
      ]

      assert {:ok, %Response{} = resp} = OpenAITransport.call(req(), opts, nil)
      assert resp.content == "Hello"
      assert resp.tokens_used == 20
      assert resp.latency_ms >= 0
      assert resp.model == :default
    end
  end

  describe "call/3 — HTTP errors" do
    test "401 returns {:error, {:transport, :unauthorized}}" do
      opts = [api_key: "bad-key", http_post_fn: mock_post(401, %{})]
      assert {:error, {:transport, :unauthorized}} = OpenAITransport.call(req(), opts, nil)
    end

    test "429 returns {:error, {:transport, :rate_limited}}" do
      opts = [api_key: "sk-test", http_post_fn: mock_post(429, %{})]
      assert {:error, {:transport, :rate_limited}} = OpenAITransport.call(req(), opts, nil)
    end

    test "500 returns {:error, {:transport, {:http_error, 500}}}" do
      opts = [api_key: "sk-test", http_post_fn: mock_post(500, %{})]
      assert {:error, {:transport, {:http_error, 500}}} = OpenAITransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — parse errors" do
    test "malformed body returns {:error, {:parse_error, _}}" do
      opts = [api_key: "sk-test", http_post_fn: mock_post(200, %{"unexpected" => "shape"})]
      assert {:error, {:parse_error, _}} = OpenAITransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — network error" do
    test "Req error returns {:error, {:transport, reason}}" do
      opts = [api_key: "sk-test", http_post_fn: fn _url, _opts -> {:error, :timeout} end]
      assert {:error, {:transport, :timeout}} = OpenAITransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — missing api_key" do
    test "returns missing_api_key when no api key is configured" do
      request = %Request{prompt: "hello", model: :default}
      assert {:error, {:transport, :missing_api_key}} =
        OpenAITransport.call(request, [api_key: nil], fn _, _ -> flunk("should not be called") end)
    end
  end

  describe "call/3 — tools" do
    test "injects tools array and tool_choice into body when request.tools present" do
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

      opts = [api_key: "sk-test", http_post_fn: mock]
      assert {:ok, %Response{}} = OpenAITransport.call(request, opts, nil)
    end

    test "does not inject tools when request.tools is nil" do
      request = %Request{prompt: "hello", model: :default}

      mock = fn _url, opts ->
        body = opts[:json]
        refute Map.has_key?(body, "tools")
        refute Map.has_key?(body, "tool_choice")
        {:ok, %{status: 200, body: success_body("hi", 5)}}
      end

      opts = [api_key: "sk-test", http_post_fn: mock]
      assert {:ok, %Response{}} = OpenAITransport.call(request, opts, nil)
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
        "usage" => %{"total_tokens" => 30}
      }

      opts = [api_key: "sk-test", http_post_fn: mock_post(200, body)]
      assert {:ok, %Response{} = resp} = OpenAITransport.call(req(), opts, nil)
      assert resp.content == nil
      assert [%{id: "call_abc", name: "run_code", args: %{"source" => "IO.puts 1"}}] = resp.tool_calls
    end
  end

  describe "call/3 — message formatting" do
    test "formats assistant message with tool_calls" do
      calls = [%{id: "call_1", name: "run_code", args: %{"source" => "1+1"}}]
      messages = [
        %{role: :assistant, content: nil, tool_calls: calls},
        %{role: :tool, content: "2", tool_call_id: "call_1"}
      ]
      request = %Request{prompt: "go", model: :default, messages: messages}

      mock = fn _url, opts ->
        msgs = opts[:json]["messages"]
        # system message won't be present (no request.system)
        [asst, tool_msg] = msgs
        assert asst["role"] == "assistant"
        [tc] = asst["tool_calls"]
        assert tc["id"] == "call_1"
        assert tc["type"] == "function"
        assert tc["function"]["name"] == "run_code"
        assert Jason.decode!(tc["function"]["arguments"]) == %{"source" => "1+1"}
        assert tool_msg["role"] == "tool"
        assert tool_msg["tool_call_id"] == "call_1"
        assert tool_msg["content"] == "2"
        {:ok, %{status: 200, body: success_body("done", 10)}}
      end

      opts = [api_key: "sk-test", http_post_fn: mock]
      assert {:ok, %Response{}} = OpenAITransport.call(request, opts, nil)
    end
  end

  describe "stream/4 — text response" do
    test "calls chunk_fn per text token and returns assembled Response" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

      http_stream_fn = fn _url, _body, cf ->
        cf.("Hello ")
        cf.("world")
        {:ok, %Shem.LLM.Response{
          content: "Hello world",
          tool_calls: nil,
          tokens_used: 10,
          model: :default,
          latency_ms: 0
        }}
      end

      request = %Shem.LLM.Request{prompt: "hi", model: :default}
      opts = [api_key: "sk-test", http_stream_fn: http_stream_fn]

      assert {:ok, %{content: "Hello world", tool_calls: nil, tokens_used: 10}} =
               OpenAITransport.stream(request, opts, chunk_fn, fn _, _ -> {:error, :no_next} end)

      assert Agent.get(collector, & &1) == ["Hello ", "world"]
    end
  end

  describe "stream/4 — tool call response" do
    test "returns tool_calls in Response; mock controls chunk emission" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

      http_stream_fn = fn _url, _body, cf ->
        cf.("Let me check")
        {:ok, %Shem.LLM.Response{
          content: "Let me check",
          tool_calls: [%{id: "call_1", name: "shell", args: %{"cmd" => "ls"}}],
          tokens_used: 15,
          model: :default,
          latency_ms: 0
        }}
      end

      request = %Shem.LLM.Request{prompt: "ls", model: :default, tools: nil}
      opts = [api_key: "sk-test", http_stream_fn: http_stream_fn]

      assert {:ok, %{tool_calls: [%{name: "shell"}]}} =
               OpenAITransport.stream(request, opts, chunk_fn, fn _, _ -> {:error, :no_next} end)

      assert Agent.get(collector, & &1) == ["Let me check"]
    end
  end

  describe "stream/4 — error handling" do
    test "returns {:error, {:transport, :missing_api_key}} when api_key is nil" do
      request = %Shem.LLM.Request{prompt: "test", model: :default}
      assert {:error, {:transport, :missing_api_key}} =
               OpenAITransport.stream(request, [api_key: nil], fn _ -> :ok end, fn _, _ -> :ok end)
    end
  end

  describe "call/3 — structured messages" do
    test "uses request.messages array and prepends system message when present" do
      messages = [
        %{role: :user, content: "Available tools:\n- shell: Run shell"},
        %{role: :user, content: "What is 2+2?"},
        %{role: :assistant, content: "Let me compute."}
      ]
      request = %Request{
        prompt: "fallback prompt",
        model: :default,
        system: "Be concise.",
        messages: messages
      }

      mock = fn _url, opts ->
        body = opts[:json]
        msgs = body["messages"]
        assert hd(msgs) == %{"role" => "system", "content" => "Be concise."}
        assert Enum.any?(msgs, &(&1["content"] == "What is 2+2?"))
        assert Enum.any?(msgs, &(&1["role"] == "assistant"))
        {:ok, %{status: 200, body: success_body("4", 10)}}
      end

      opts = [api_key: "sk-test", http_post_fn: mock]
      assert {:ok, %Response{content: "4"}} = OpenAITransport.call(request, opts, nil)
    end

    test "falls back to prompt-wrap when request.messages is nil" do
      request = %Request{prompt: "hello", model: :default}

      mock = fn _url, opts ->
        msgs = opts[:json]["messages"]
        assert msgs == [%{"role" => "user", "content" => "hello"}]
        {:ok, %{status: 200, body: success_body("hi", 5)}}
      end

      opts = [api_key: "sk-test", http_post_fn: mock]
      assert {:ok, %Response{content: "hi"}} = OpenAITransport.call(request, opts, nil)
    end
  end
end
