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
end
