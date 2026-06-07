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
