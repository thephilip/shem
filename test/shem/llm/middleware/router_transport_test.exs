defmodule Shem.LLM.Middleware.RouterTransportTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.Middleware.RouterTransport
  alias Shem.LLM.{Request, Response}

  defmodule EchoBackend do
    @behaviour Shem.LLM.Middleware
    @impl true
    def call(request, opts, _next) do
      {:ok,
       %Response{
         content: "echo:#{Keyword.get(opts, :model_string, "none")}",
         tokens_used: 1,
         model: request.model,
         latency_ms: 0
       }}
    end
  end

  defmodule FailBackend do
    @behaviour Shem.LLM.Middleware
    @impl true
    def call(_req, _opts, _next), do: {:error, {:transport, :timeout}}
  end

  defp req(model \\ :default), do: %Request{prompt: "hello", model: model}

  describe "call/3" do
    test "delegates to resolved transport with model_string in opts" do
      resolve_fn = fn _atom -> {EchoBackend, [model_string: "phi4"]} end
      {:ok, resp} = RouterTransport.call(req(:reasoning), [resolve_fn: resolve_fn], nil)
      assert resp.content == "echo:phi4"
    end

    test "passes transport errors back unchanged" do
      resolve_fn = fn _atom -> {FailBackend, []} end
      assert {:error, {:transport, :timeout}} = RouterTransport.call(req(), [resolve_fn: resolve_fn], nil)
    end

    test "returns {:error, {:router, reason}} when resolver returns error" do
      resolve_fn = fn _atom -> {:error, :no_default} end
      assert {:error, {:router, :no_default}} = RouterTransport.call(req(), [resolve_fn: resolve_fn], nil)
    end
  end
end
