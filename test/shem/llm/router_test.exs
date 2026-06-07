defmodule Shem.LLM.RouterTest do
  use ExUnit.Case, async: false

  alias Shem.LLM.Router

  setup do
    Router.flush()
    on_exit(fn -> Router.flush() end)
    :ok
  end

  describe "resolve/1" do
    test "returns LlamaCppTransport and model_string for :default route" do
      # test.exs sets: llm_routes: %{default: {:llama_cpp, "llama3:latest"}}
      assert {Shem.LLM.Middleware.LlamaCppTransport, opts} = Router.resolve(:default)
      assert Keyword.get(opts, :model_string) == "llama3:latest"
    end

    test "returns configured route after set_route/3" do
      :ok = Router.set_route(:reasoning, :llama_cpp, "phi4")
      assert {Shem.LLM.Middleware.LlamaCppTransport, opts} = Router.resolve(:reasoning)
      assert Keyword.get(opts, :model_string) == "phi4"
    end

    test "falls back to :default for unknown atom" do
      result = Router.resolve(:__totally_unknown__)
      assert {Shem.LLM.Middleware.LlamaCppTransport, opts} = result
      assert Keyword.get(opts, :model_string) == "llama3:latest"
    end

    test "returns OllamaTransport for :ollama backend" do
      :ok = Router.set_route(:local, :ollama, "mistral")
      assert {Shem.LLM.Middleware.OllamaTransport, opts} = Router.resolve(:local)
      assert Keyword.get(opts, :model_string) == "mistral"
    end

    test "returns OpenAITransport for :openai backend" do
      :ok = Router.set_route(:default, :openai, "gpt-4o")
      assert {Shem.LLM.Middleware.OpenAITransport, opts} = Router.resolve(:default)
      assert Keyword.get(opts, :model_string) == "gpt-4o"
    end

    test "returns AnthropicTransport for :anthropic backend" do
      :ok = Router.set_route(:reasoning, :anthropic, "claude-sonnet-4-6")
      assert {Shem.LLM.Middleware.AnthropicTransport, opts} = Router.resolve(:reasoning)
      assert Keyword.get(opts, :model_string) == "claude-sonnet-4-6"
    end
  end

  describe "set_route/3" do
    test "overwrites existing route" do
      :ok = Router.set_route(:default, :llama_cpp, "new-model")
      assert {_, opts} = Router.resolve(:default)
      assert Keyword.get(opts, :model_string) == "new-model"
    end

    test "adds new atom to route table" do
      :ok = Router.set_route(:tools, :llama_cpp, "qwen3")
      routes = Router.all()
      assert Map.has_key?(routes, :tools)
    end
  end

  describe "all/0" do
    test "returns full route table as a map" do
      :ok = Router.set_route(:reasoning, :llama_cpp, "phi4")
      routes = Router.all()
      assert is_map(routes)
      assert Map.has_key?(routes, :default)
      assert Map.has_key?(routes, :reasoning)
    end
  end

  describe "flush/0" do
    test "resets route table to config defaults" do
      :ok = Router.set_route(:reasoning, :llama_cpp, "phi4")
      :ok = Router.flush()
      routes = Router.all()
      refute Map.has_key?(routes, :reasoning)
      assert Map.has_key?(routes, :default)
    end
  end
end
