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
end
