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
      "response" => content,
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
end
