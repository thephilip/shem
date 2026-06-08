defmodule Shem.LLM.Middleware.AnthropicTransportTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.Middleware.AnthropicTransport
  alias Shem.LLM.{Request, Response}

  defp req(model \\ :default), do: %Request{prompt: "hello", model: model}

  defp mock_post(status, body) do
    fn _url, _opts -> {:ok, %{status: status, body: body}} end
  end

  defp success_body(content, input_tokens, output_tokens) do
    %{
      "content" => [%{"type" => "text", "text" => content}],
      "usage" => %{"input_tokens" => input_tokens, "output_tokens" => output_tokens}
    }
  end

  describe "call/3 — success" do
    test "returns Response with content, tokens_used, and latency_ms" do
      opts = [
        model_string: "claude-sonnet-4-6",
        api_key: "sk-ant-test",
        http_post_fn: mock_post(200, success_body("Hello", 10, 5))
      ]

      assert {:ok, %Response{} = resp} = AnthropicTransport.call(req(), opts, nil)
      assert resp.content == "Hello"
      assert resp.tokens_used == 15
      assert resp.latency_ms >= 0
      assert resp.model == :default
    end

    test "respects base_url opt for proxy compatibility" do
      custom_url = "https://proxy.example.com"
      mock = fn url, _opts ->
        assert url == custom_url <> "/v1/messages"
        {:ok, %{status: 200, body: success_body("Hello", 10, 5)}}
      end
      opts = [api_key: "sk-ant-test", http_post_fn: mock, base_url: custom_url]
      assert {:ok, _resp} = AnthropicTransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — HTTP errors" do
    test "401 returns {:error, {:transport, :unauthorized}}" do
      opts = [api_key: "bad-key", http_post_fn: mock_post(401, %{})]
      assert {:error, {:transport, :unauthorized}} = AnthropicTransport.call(req(), opts, nil)
    end

    test "429 returns {:error, {:transport, :rate_limited}}" do
      opts = [api_key: "sk-ant-test", http_post_fn: mock_post(429, %{})]
      assert {:error, {:transport, :rate_limited}} = AnthropicTransport.call(req(), opts, nil)
    end

    test "500 returns {:error, {:transport, {:http_error, 500}}}" do
      opts = [api_key: "sk-ant-test", http_post_fn: mock_post(500, %{})]
      assert {:error, {:transport, {:http_error, 500}}} = AnthropicTransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — parse errors" do
    test "malformed body returns {:error, {:parse_error, _}}" do
      opts = [api_key: "sk-ant-test", http_post_fn: mock_post(200, %{"unexpected" => "shape"})]
      assert {:error, {:parse_error, _}} = AnthropicTransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — network error" do
    test "Req error returns {:error, {:transport, reason}}" do
      opts = [api_key: "sk-ant-test", http_post_fn: fn _url, _opts -> {:error, :timeout} end]
      assert {:error, {:transport, :timeout}} = AnthropicTransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — missing api_key" do
    test "returns missing_api_key when no api key is configured" do
      request = %Request{prompt: "hello", model: :default}
      assert {:error, {:transport, :missing_api_key}} =
        AnthropicTransport.call(request, [api_key: nil], fn _, _ -> flunk("should not be called") end)
    end
  end

  describe "call/3 — tools" do
    test "injects tools array with input_schema format into body" do
      tools = [%{name: "run_code", description: "Run Elixir", schema: %{"type" => "object", "properties" => %{}, "required" => []}}]
      request = %Request{prompt: "go", model: :default, tools: tools}

      mock = fn _url, opts ->
        body = opts[:json]
        [tool] = body["tools"]
        assert tool["name"] == "run_code"
        assert Map.has_key?(tool, "input_schema")
        refute Map.has_key?(tool, "type")
        refute Map.has_key?(body, "tool_choice")
        {:ok, %{status: 200, body: success_body("ok", 5, 3)}}
      end

      opts = [api_key: "sk-ant-test", http_post_fn: mock]
      assert {:ok, %Response{}} = AnthropicTransport.call(request, opts, nil)
    end
  end

  describe "call/3 — tool_calls in response" do
    test "decodes tool_use blocks from response content array" do
      body = %{
        "content" => [
          %{"type" => "tool_use", "id" => "toolu_abc", "name" => "run_code", "input" => %{"source" => "IO.puts 1"}}
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      opts = [api_key: "sk-ant-test", http_post_fn: mock_post(200, body)]
      assert {:ok, %Response{} = resp} = AnthropicTransport.call(req(), opts, nil)
      assert resp.content == nil
      assert [%{id: "toolu_abc", name: "run_code", args: %{"source" => "IO.puts 1"}}] = resp.tool_calls
    end
  end

  describe "call/3 — message formatting" do
    test "formats tool result as user message with tool_result block" do
      messages = [
        %{role: :tool, content: "result text", tool_call_id: "toolu_abc"}
      ]
      request = %Request{prompt: "go", model: :default, messages: messages}

      mock = fn _url, opts ->
        [msg] = opts[:json]["messages"]
        assert msg["role"] == "user"
        [block] = msg["content"]
        assert block["type"] == "tool_result"
        assert block["tool_use_id"] == "toolu_abc"
        assert block["content"] == "result text"
        {:ok, %{status: 200, body: success_body("done", 5, 3)}}
      end

      opts = [api_key: "sk-ant-test", http_post_fn: mock]
      assert {:ok, %Response{}} = AnthropicTransport.call(request, opts, nil)
    end

    test "formats assistant message with tool_calls as content block array" do
      calls = [%{id: "toolu_1", name: "run_code", args: %{"source" => "1+1"}}]
      messages = [
        %{role: :assistant, content: "Let me run that.", tool_calls: calls}
      ]
      request = %Request{prompt: "go", model: :default, messages: messages}

      mock = fn _url, opts ->
        [msg] = opts[:json]["messages"]
        assert msg["role"] == "assistant"
        [text_block, call_block] = msg["content"]
        assert text_block == %{"type" => "text", "text" => "Let me run that."}
        assert call_block["type"] == "tool_use"
        assert call_block["id"] == "toolu_1"
        assert call_block["name"] == "run_code"
        assert call_block["input"] == %{"source" => "1+1"}
        {:ok, %{status: 200, body: success_body("done", 5, 3)}}
      end

      opts = [api_key: "sk-ant-test", http_post_fn: mock]
      assert {:ok, %Response{}} = AnthropicTransport.call(request, opts, nil)
    end
  end

  describe "call/3 — multi-tool result grouping" do
    test "consecutive tool results are merged into a single user message" do
      calls = [
        %{id: "t1", name: "run_code", args: %{"source" => "1+1"}},
        %{id: "t2", name: "shell", args: %{"cmd" => "ls"}}
      ]
      messages = [
        %{role: :assistant, content: nil, tool_calls: calls},
        %{role: :tool, content: "result A", tool_call_id: "t1"},
        %{role: :tool, content: "result B", tool_call_id: "t2"}
      ]
      request = %Request{prompt: "go", model: :default, messages: messages}

      mock = fn _url, opts ->
        msgs = opts[:json]["messages"]
        # assistant message first
        [asst, tool_msg] = msgs
        assert asst["role"] == "assistant"
        # single user message with two tool_result blocks
        assert tool_msg["role"] == "user"
        [block_a, block_b] = tool_msg["content"]
        assert block_a["type"] == "tool_result"
        assert block_a["tool_use_id"] == "t1"
        assert block_a["content"] == "result A"
        assert block_b["type"] == "tool_result"
        assert block_b["tool_use_id"] == "t2"
        assert block_b["content"] == "result B"
        {:ok, %{status: 200, body: success_body("done", 10, 5)}}
      end

      opts = [api_key: "sk-ant-test", http_post_fn: mock]
      assert {:ok, %Response{}} = AnthropicTransport.call(request, opts, nil)
    end
  end

  describe "stream/4 — text response" do
    test "calls chunk_fn per text token" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

      http_stream_fn = fn _url, _body, _headers, _timeout, _model, cf ->
        cf.("Hello ")
        cf.("Claude")
        {:ok, %Shem.LLM.Response{
          content: "Hello Claude",
          tool_calls: nil,
          tokens_used: 12,
          model: :default,
          latency_ms: 0
        }}
      end

      request = %Shem.LLM.Request{prompt: "hi", model: :default}
      opts = [api_key: "test-key", http_stream_fn: http_stream_fn]

      assert {:ok, %{content: "Hello Claude"}} =
               AnthropicTransport.stream(request, opts, chunk_fn, fn _, _ -> :ok end)

      assert Agent.get(collector, & &1) == ["Hello ", "Claude"]
    end
  end

  describe "stream/4 — tool call" do
    test "returns tool_calls in Response" do
      http_stream_fn = fn _url, _body, _headers, _timeout, _model, cf ->
        cf.("I'll use a tool")
        {:ok, %Shem.LLM.Response{
          content: "I'll use a tool",
          tool_calls: [%{id: "toolu_abc", name: "shell", args: %{"cmd" => "ls"}}],
          tokens_used: 20,
          model: :default,
          latency_ms: 0
        }}
      end

      request = %Shem.LLM.Request{prompt: "ls", model: :default}
      opts = [api_key: "test-key", http_stream_fn: http_stream_fn]

      assert {:ok, %{tool_calls: [%{id: "toolu_abc", name: "shell"}]}} =
               AnthropicTransport.stream(request, opts, fn _ -> :ok end, fn _, _ -> :ok end)
    end
  end

  describe "stream/4 — error" do
    test "returns {:error, {:transport, :missing_api_key}} when api_key absent" do
      request = %Shem.LLM.Request{prompt: "hi", model: :default}

      assert {:error, {:transport, :missing_api_key}} =
               AnthropicTransport.stream(request, [api_key: nil], fn _ -> :ok end, fn _, _ -> :ok end)
    end
  end

  describe "stream/4 — SSE parser via req_fn injection" do
    test "text_delta events call chunk_fn and assemble content" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

      req_fn = fn _url, opts ->
        into_fn = opts[:into]
        events = [
          ~s|event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":5}}}\n\n|,
          ~s|event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}\n\n|,
          ~s|event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}\n\n|,
          ~s|event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":3}}\n\n|
        ]
        Enum.reduce(events, "", fn event, acc ->
          {:cont, new_acc} = into_fn.({:data, event}, acc)
          new_acc
        end)
        {:ok, %{status: 200}}
      end

      request = %Shem.LLM.Request{prompt: "hi", model: :default, tools: nil}
      opts = [api_key: "sk-test", req_fn: req_fn]

      assert {:ok, %{content: "Hello world", tokens_used: 8}} =
               AnthropicTransport.stream(request, opts, chunk_fn, fn _, _ -> {:error, :no_next} end)

      assert Agent.get(collector, & &1) == ["Hello ", "world"]
    end

    test "tool_use block accumulates args via input_json_delta" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

      req_fn = fn _url, opts ->
        into_fn = opts[:into]
        events = [
          ~s|event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":10}}}\n\n|,
          ~s|event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"shell"}}\n\n|,
          ~s|event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"cmd\\":"}}\n\n|,
          ~s|event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\"ls\\"}"}} \n\n|,
          ~s|event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":5}}\n\n|
        ]
        Enum.reduce(events, "", fn event, acc ->
          {:cont, new_acc} = into_fn.({:data, event}, acc)
          new_acc
        end)
        {:ok, %{status: 200}}
      end

      request = %Shem.LLM.Request{prompt: "ls", model: :default, tools: nil}
      opts = [api_key: "sk-test", req_fn: req_fn]

      assert {:ok, %{tool_calls: [%{id: "toolu_1", name: "shell", args: %{"cmd" => "ls"}}], tokens_used: 15}} =
               AnthropicTransport.stream(request, opts, chunk_fn, fn _, _ -> {:error, :no_next} end)

      assert Agent.get(collector, & &1) == []
    end
  end

  describe "call/3 — structured messages" do
    test "uses request.messages and top-level system field when present" do
      messages = [
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
        assert body["system"] == "Be concise."
        assert body["messages"] == [
          %{"role" => "user", "content" => "What is 2+2?"},
          %{"role" => "assistant", "content" => "Let me compute."}
        ]
        assert not Map.has_key?(hd(body["messages"]), "system")
        {:ok, %{status: 200, body: success_body("4", 5, 2)}}
      end

      opts = [api_key: "sk-ant-test", http_post_fn: mock]
      assert {:ok, %Response{content: "4"}} = AnthropicTransport.call(request, opts, nil)
    end

    test "falls back to prompt-wrap and no system field when request.messages is nil" do
      request = %Request{prompt: "hello", model: :default}

      mock = fn _url, opts ->
        body = opts[:json]
        assert body["messages"] == [%{"role" => "user", "content" => "hello"}]
        assert not Map.has_key?(body, "system")
        {:ok, %{status: 200, body: success_body("hi", 5, 2)}}
      end

      opts = [api_key: "sk-ant-test", http_post_fn: mock]
      assert {:ok, %Response{content: "hi"}} = AnthropicTransport.call(request, opts, nil)
    end
  end
end
