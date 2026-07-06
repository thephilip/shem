# lib/shem/cli/setup.ex
defmodule Shem.CLI.Setup do
  @moduledoc false

  alias Shem.CLI.{Banner, ConfigFile}

  @backends [
    {"1", "anthropic", "Anthropic", "claude-sonnet-5", "ANTHROPIC_API_KEY"},
    {"2", "openai",    "OpenAI",    "gpt-4o",            "OPENAI_API_KEY"},
    {"3", "ollama",    "Ollama",    "llama3.2",           nil},
    {"4", "llama_cpp", "llama.cpp", "local-model",       nil}
  ]

  def run do
    Banner.print()
    green("✦ Welcome to Shem")
    line()

    config_path = ConfigFile.default_path()

    if File.exists?(config_path) do
      answer = prompt("  Existing config found at #{config_path}\n  Overwrite? [y/N]")
      if String.downcase(answer) != "y" do
        IO.puts("\nSetup cancelled — existing config unchanged.")
        System.halt(0)
      end
    end

    IO.puts("")
    {backend_key, model, url} = step_backend()
    api_key = step_api_key(backend_key)
    {port, host, token} = step_server()

    config = %{
      "llm" => %{"default" => %{
        "backend" => backend_key,
        "model"   => model,
        "api_key" => api_key,
        "url"     => url
      }},
      "server"   => %{"port" => port, "host" => host},
      "executor" => %{"backend" => "auto", "image" => "debian:12-slim"},
      "tui"      => true,
      "data_dir" => "~/.config/shem"
    }

    config = if token, do: Map.put(config, "auth", %{"token" => token}), else: config

    IO.puts("")
    spinner("Testing connection to #{backend_label(backend_key)}", fn ->
      validate_backend!(backend_key, api_key, url, model)
    end)

    spinner("Writing #{config_path}", fn ->
      ConfigFile.write(config)
    end)

    line()
    green("Setup complete.")
    IO.puts("Run `shem start` to launch.")

    if token do
      IO.puts("")
      IO.puts("Point MCP clients at the server with the token, e.g.:")
      IO.puts(~s|  claude mcp add --transport sse shem http://#{host}:#{port}/mcp/sse --header "Authorization: Bearer #{token}"|)
    end

    IO.puts("")
  end

  # ── Steps ───────────────────────────────────────────────────────────────────

  defp step_backend do
    IO.puts("Step 1/3 — LLM Backend")
    IO.puts("  Which provider will you use?")
    IO.puts("  [1] Anthropic   (claude-sonnet-5)")
    IO.puts("  [2] OpenAI      (gpt-4o)")
    IO.puts("  [3] Ollama      (local — http://localhost:11434)")
    IO.puts("  [4] llama.cpp   (local — http://localhost:1234)")
    IO.puts("")

    choice = loop_prompt("  → ", ["1", "2", "3", "4"])
    {_num, key, _label, model, _env} = Enum.find(@backends, fn {n, _, _, _, _} -> n == choice end)

    url =
      if key in ["ollama", "llama_cpp"] do
        default_url = if key == "ollama", do: "http://localhost:11434", else: "http://localhost:1234"
        IO.puts("")
        ans = prompt("  URL [#{default_url}]")
        if ans == "", do: default_url, else: ans
      else
        ""
      end

    IO.puts("")
    {key, model, url}
  end

  defp step_api_key(backend) when backend in ["ollama", "llama_cpp"] do
    IO.puts("Step 2/3 — API Key")
    IO.puts("  No API key needed for #{backend_label(backend)}.")
    IO.puts("")
    ""
  end

  defp step_api_key(backend) do
    IO.puts("Step 2/3 — API Key")
    {_num, ^backend, _label, _model, env_var} =
      Enum.find(@backends, fn {_, k, _, _, _} -> k == backend end)

    existing = env_var && System.get_env(env_var)

    key =
      if existing && existing != "" do
        ans = prompt("  #{env_var} is set in your environment. Use it? [Y/n]")
        if String.downcase(ans) in ["", "y"], do: existing, else: prompt("  API key")
      else
        prompt("  API key")
      end

    IO.puts("")
    key
  end

  defp step_server do
    IO.puts("Step 3/3 — Server")
    port_str = prompt("  Port [4000]")
    host_str = prompt("  Host [127.0.0.1]")
    port = if port_str == "", do: 4000, else: String.to_integer(port_str)
    host = if host_str == "", do: "127.0.0.1", else: host_str

    token =
      if host in ["127.0.0.1", "localhost", "::1"] do
        nil
      else
        t = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        IO.puts("  Non-loopback bind — generated auth token (saved to config):")
        IO.puts("    #{t}")
        t
      end

    {port, host, token}
  end

  # ── Validation ──────────────────────────────────────────────────────────────

  @doc false
  def validate_backend!(backend, api_key, url, model) do
    Application.ensure_all_started(:req)
    case backend do
      "anthropic" ->
        key = if api_key == "", do: System.get_env("ANTHROPIC_API_KEY"), else: api_key
        result = Req.post("https://api.anthropic.com/v1/messages",
          headers: [
            {"x-api-key", key || ""},
            {"anthropic-version", "2023-06-01"},
            {"content-type", "application/json"}
          ],
          json: %{"model" => model, "max_tokens" => 1,
                  "messages" => [%{"role" => "user", "content" => "hi"}]},
          receive_timeout: 10_000)
        case result do
          {:ok, %{status: s}} when s in [200, 400] -> :ok
          {:ok, %{status: 401}} -> raise "Invalid API key"
          {:error, reason} -> raise "Connection failed: #{inspect(reason)}"
        end

      "openai" ->
        key = if api_key == "", do: System.get_env("OPENAI_API_KEY"), else: api_key
        result = Req.get("https://api.openai.com/v1/models",
          headers: [{"authorization", "Bearer #{key || ""}"}],
          receive_timeout: 10_000)
        case result do
          {:ok, %{status: 200}} -> :ok
          {:ok, %{status: 401}} -> raise "Invalid API key"
          {:error, reason} -> raise "Connection failed: #{inspect(reason)}"
        end

      "ollama" ->
        base = if url == "", do: "http://localhost:11434", else: url
        case Req.get("#{base}/api/tags", receive_timeout: 5_000) do
          {:ok, %{status: 200}} -> :ok
          {:error, reason} -> raise "Cannot reach Ollama at #{base}: #{inspect(reason)}"
        end

      "llama_cpp" ->
        base = if url == "", do: "http://localhost:1234", else: url
        case Req.get("#{base}/v1/models", receive_timeout: 5_000) do
          {:ok, %{status: 200}} -> :ok
          {:error, reason} -> raise "Cannot reach llama.cpp at #{base}: #{inspect(reason)}"
        end
    end
  end

  # ── UI helpers ──────────────────────────────────────────────────────────────

  defp prompt(label) do
    IO.write("#{label}: ")
    IO.read(:line) |> String.trim()
  end

  defp loop_prompt(label, valid) do
    answer = prompt(label)
    if answer in valid, do: answer, else: loop_prompt(label, valid)
  end

  defp spinner(label, fun) do
    IO.write("  ✦ #{label}...")
    try do
      fun.()
      IO.puts("  ✓")
    rescue
      e -> IO.puts("\n  ✗ #{Exception.message(e)}"); System.halt(1)
    end
  end

  defp green(text), do: IO.puts("\e[32m#{text}\e[0m")
  defp line, do: IO.puts(String.duplicate("─", 50))
  defp backend_label(b), do: Enum.find_value(@backends, b, fn {_, k, l, _, _} -> if k == b, do: l end)

  @doc false
  def default_path, do: ConfigFile.default_path()
end
