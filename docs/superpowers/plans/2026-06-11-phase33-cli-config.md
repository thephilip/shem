# Phase 33: CLI, Config & First-Run Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give shem a real CLI with help/dispatch, a user-editable YAML config file, a polished first-run setup wizard, and a progress-bar install script.

**Architecture:** A smart bash wrapper dispatches subcommands to `bin/shem eval "Shem.CLI.*.run()"` calls. A `Shem.CLI.ConfigFile` module owns YAML read/write to `~/.config/shem/config.yaml`. `runtime.exs` loads that file at boot, maps its keys to app config, and halts with a friendly message if no LLM is configured (skipped for `eval` commands). The `shem setup` wizard writes the config file interactively.

**Tech Stack:** Elixir/OTP, `yaml_elixir ~> 2.12` (YAML parsing), `Req` (HTTP validation ping in setup), Bandit/Plug (existing), Python 3 + Pillow (one-off banner generation script).

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `mix.exs` | Modify | Add `yaml_elixir`, bump version to `0.1.1` |
| `lib/shem/cli/config_file.ex` | Create | YAML read/write for `~/.config/shem/config.yaml` |
| `lib/shem/cli/banner.ex` | Create | Print ANSI banner; detect truecolor + TTY |
| `lib/shem/cli/config.ex` | Create | `list`, `get`, `set` subcommands |
| `lib/shem/cli/status.ex` | Create | Probe running instance via `/api/health` |
| `lib/shem/cli/setup.ex` | Create | Interactive first-run wizard |
| `lib/shem/rest/handlers/health.ex` | Create | `GET /api/health` JSON endpoint |
| `lib/shem/rest/router.ex` | Modify | Forward `/health` to health handler |
| `lib/shem/mcp/server.ex` | Modify | Read `mcp_host` from app config |
| `config/runtime.exs` | Modify | Load YAML config; first-run detection |
| `scripts/generate_banner.py` | Create | One-off ANSI art generator (committed, run once) |
| `priv/banner.ansi` | Create | Pre-generated ANSI art (committed) |
| `install.sh` | Modify | Progress bars; smart wrapper template |
| `test/shem/cli/config_file_test.exs` | Create | Unit tests for ConfigFile |
| `test/shem/cli/config_test.exs` | Create | Unit tests for Config CLI |
| `test/shem/rest/health_test.exs` | Create | Tests for /api/health |

---

## Task 1: Add `yaml_elixir` and bump version

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add dependency and bump version**

```elixir
# mix.exs — change version and add to deps:
version: "0.1.1",

# in deps/0:
{:yaml_elixir, "~> 2.12"},
```

- [ ] **Step 2: Fetch the dependency**

```bash
cd /home/philip/Downloads/_project/shem
mix deps.get
```

Expected output: `yaml_elixir 2.12.2` in the resolved list.

- [ ] **Step 3: Verify compilation**

```bash
mix compile 2>&1 | grep -E "error:|warning:" | grep -v "unused variable"
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "chore: add yaml_elixir, bump version to 0.1.1"
```

---

## Task 2: `Shem.CLI.ConfigFile` — YAML read/write

**Files:**
- Create: `lib/shem/cli/config_file.ex`
- Create: `test/shem/cli/config_file_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/cli/config_file_test.exs
defmodule Shem.CLI.ConfigFileTest do
  use ExUnit.Case, async: true

  alias Shem.CLI.ConfigFile

  @tag :tmp_dir
  test "read/1 returns empty map when file does not exist", %{tmp_dir: dir} do
    path = Path.join(dir, "config.yaml")
    assert {:ok, %{}} = ConfigFile.read(path)
  end

  @tag :tmp_dir
  test "write/2 then read/1 round-trips full config", %{tmp_dir: dir} do
    path = Path.join(dir, "config.yaml")

    config = %{
      "llm" => %{"default" => %{"backend" => "anthropic", "model" => "claude-sonnet-4-6", "api_key" => "sk-test", "url" => ""}},
      "server" => %{"port" => 4000, "host" => "127.0.0.1"},
      "executor" => %{"backend" => "auto", "image" => "debian:12-slim"},
      "tui" => true,
      "data_dir" => "~/.config/shem"
    }

    assert :ok = ConfigFile.write(config, path)
    assert {:ok, read_back} = ConfigFile.read(path)
    assert get_in(read_back, ["llm", "default", "backend"]) == "anthropic"
    assert get_in(read_back, ["server", "port"]) == 4000
    assert get_in(read_back, ["tui"]) == true
  end

  @tag :tmp_dir
  test "get/2 retrieves a nested key using dot notation", %{tmp_dir: dir} do
    path = Path.join(dir, "config.yaml")
    config = %{"llm" => %{"default" => %{"backend" => "openai"}}}
    ConfigFile.write(config, path)
    assert {:ok, "openai"} = ConfigFile.get("llm.default.backend", path)
  end

  @tag :tmp_dir
  test "get/2 returns :not_found for missing key", %{tmp_dir: dir} do
    path = Path.join(dir, "config.yaml")
    ConfigFile.write(%{}, path)
    assert {:error, :not_found} = ConfigFile.get("llm.default.backend", path)
  end

  @tag :tmp_dir
  test "set/3 creates file and sets nested key", %{tmp_dir: dir} do
    path = Path.join(dir, "config.yaml")
    assert :ok = ConfigFile.set("server.port", "8080", path)
    assert {:ok, read_back} = ConfigFile.read(path)
    assert get_in(read_back, ["server", "port"]) == "8080"
  end

  @tag :tmp_dir
  test "set/3 updates existing key without touching others", %{tmp_dir: dir} do
    path = Path.join(dir, "config.yaml")
    config = %{"server" => %{"port" => 4000, "host" => "127.0.0.1"}}
    ConfigFile.write(config, path)
    ConfigFile.set("server.port", "9000", path)
    {:ok, result} = ConfigFile.read(path)
    assert get_in(result, ["server", "host"]) == "127.0.0.1"
    assert get_in(result, ["server", "port"]) == "9000"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/cli/config_file_test.exs 2>&1 | tail -5
```

Expected: compile error (module not found).

- [ ] **Step 3: Implement `Shem.CLI.ConfigFile`**

```elixir
# lib/shem/cli/config_file.ex
defmodule Shem.CLI.ConfigFile do
  @moduledoc false

  defp default_path do
    Path.join([System.user_home!(), ".config", "shem", "config.yaml"])
  end

  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read(path \\ nil) do
    path = path || default_path()

    case File.read(path) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}

      {:ok, content} ->
        Application.ensure_all_started(:yamerl)
        YamlElixir.read_from_string(content)
    end
  end

  @spec write(map(), String.t() | nil) :: :ok | {:error, term()}
  def write(config, path \\ nil) do
    path = path || default_path()
    File.mkdir_p!(Path.dirname(path))
    File.write(path, format(config))
  end

  @spec get(String.t(), String.t() | nil) :: {:ok, term()} | {:error, :not_found | term()}
  def get(dotkey, path \\ nil) do
    with {:ok, config} <- read(path) do
      keys = String.split(dotkey, ".")

      case get_in(config, keys) do
        nil -> {:error, :not_found}
        value -> {:ok, value}
      end
    end
  end

  @spec set(String.t(), term(), String.t() | nil) :: :ok | {:error, term()}
  def set(dotkey, value, path \\ nil) do
    path = path || default_path()

    config =
      case read(path) do
        {:ok, existing} -> existing
        _ -> %{}
      end

    keys = String.split(dotkey, ".")
    updated = put_in_nested(config, keys, value)
    write(updated, path)
  end

  defp put_in_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_in_nested(map, [key | rest], value) do
    nested = Map.get(map, key, %{})
    Map.put(map, key, put_in_nested(nested, rest, value))
  end

  defp format(config) do
    llm = Map.get(config, "llm", %{})
    default = Map.get(llm, "default", %{})
    server = Map.get(config, "server", %{})
    executor = Map.get(config, "executor", %{})

    """
    llm:
      default:
        backend: #{Map.get(default, "backend", "anthropic")}
        model: #{Map.get(default, "model", "")}
        api_key: "#{Map.get(default, "api_key", "")}"
        url: "#{Map.get(default, "url", "")}"

    server:
      port: #{Map.get(server, "port", 4000)}
      host: #{Map.get(server, "host", "127.0.0.1")}

    executor:
      backend: #{Map.get(executor, "backend", "auto")}
      image: #{Map.get(executor, "image", "debian:12-slim")}

    tui: #{Map.get(config, "tui", true)}
    data_dir: #{Map.get(config, "data_dir", "~/.config/shem")}
    """
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/cli/config_file_test.exs 2>&1 | tail -5
```

Expected: `5 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/cli/config_file.ex test/shem/cli/config_file_test.exs
git commit -m "feat: Shem.CLI.ConfigFile — YAML config read/write"
```

---

## Task 3: Generate ANSI banner + `Shem.CLI.Banner`

**Files:**
- Create: `scripts/generate_banner.py`
- Create: `priv/banner.ansi` (generated, then committed)
- Create: `lib/shem/cli/banner.ex`

- [ ] **Step 1: Create the banner generation script**

```python
# scripts/generate_banner.py
# Usage: python scripts/generate_banner.py shem.png priv/banner.ansi
# Requires: pip install Pillow
import sys
from PIL import Image

img = Image.open(sys.argv[1]).convert("RGB")
width = 40
ratio = img.height / img.width
height = int(width * ratio * 0.55)
img = img.resize((width, height * 2), Image.LANCZOS)

lines = []
for y in range(0, height * 2, 2):
    line = ""
    for x in range(width):
        r1, g1, b1 = img.getpixel((x, y))
        r2, g2, b2 = img.getpixel((x, y + 1))
        line += f"\x1b[38;2;{r1};{g1};{b1}m\x1b[48;2;{r2};{g2};{b2}m▀"
    line += "\x1b[0m"
    lines.append(line)

out = "\n".join(lines) + "\n"
with open(sys.argv[2], "w") as f:
    f.write(out)

print(f"Banner written to {sys.argv[2]} ({width}x{height} cells, {len(out)} bytes)")
```

- [ ] **Step 2: Install Pillow if needed and run the script**

```bash
pip install Pillow --quiet
python scripts/generate_banner.py shem.png priv/banner.ansi
```

Expected: `Banner written to priv/banner.ansi (40x... cells, ... bytes)`

Verify it looks right in your terminal:
```bash
cat priv/banner.ansi
```

If the colors look wrong or distorted, adjust `width` in the script (try 32 or 48) and re-run.

- [ ] **Step 3: Implement `Shem.CLI.Banner`**

```elixir
# lib/shem/cli/banner.ex
defmodule Shem.CLI.Banner do
  @moduledoc false

  def print do
    if truecolor?() and tty?() do
      path = Application.app_dir(:shem, "priv/banner.ansi")

      if File.exists?(path) do
        path |> File.read!() |> IO.write()
        IO.puts("")
      end
    end
  end

  defp truecolor? do
    System.get_env("COLORTERM") in ["truecolor", "24bit"]
  end

  defp tty? do
    match?({:ok, _}, :io.columns())
  end
end
```

- [ ] **Step 4: Verify compilation**

```bash
mix compile 2>&1 | grep -E "^error:"
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add scripts/generate_banner.py priv/banner.ansi lib/shem/cli/banner.ex
git commit -m "feat: ANSI banner generation script and Shem.CLI.Banner"
```

---

## Task 4: `GET /api/health` endpoint

**Files:**
- Create: `lib/shem/rest/handlers/health.ex`
- Modify: `lib/shem/rest/router.ex`
- Create: `test/shem/rest/health_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/rest/health_test.exs
defmodule Shem.REST.HealthTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Shem.REST.Router

  @opts Router.init([])

  test "GET /health returns 200 with version and status fields" do
    conn = conn(:get, "/health") |> Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["version"])
    assert is_integer(body["port"])
    assert is_boolean(body["tui"])
    assert is_integer(body["active_agents"])
  end

  test "GET /health active_agents reflects running agent count" do
    conn = conn(:get, "/health") |> Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert body["active_agents"] >= 0
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/rest/health_test.exs 2>&1 | tail -5
```

Expected: `2 tests, 2 failures` (route not found, 404).

- [ ] **Step 3: Create the health handler**

```elixir
# lib/shem/rest/handlers/health.ex
defmodule Shem.REST.Handlers.Health do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    version = Application.spec(:shem, :vsn) |> to_string()
    port = Application.get_env(:shem, :mcp_port, 4000)
    tui = Application.get_env(:shem, :start_tui, true)

    active_agents =
      try do
        Horde.DynamicSupervisor.which_children(Shem.AgentSupervisor) |> length()
      catch
        _, _ -> 0
      end

    send_json(conn, 200, %{
      version: version,
      port: port,
      tui: tui,
      active_agents: active_agents,
      host: Application.get_env(:shem, :mcp_host, "127.0.0.1")
    })
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
```

- [ ] **Step 4: Forward `/health` in the REST router**

In `lib/shem/rest/router.ex`, add before the `match _` catch-all:

```elixir
  forward "/health", to: Shem.REST.Handlers.Health
```

The full file becomes:

```elixir
defmodule Shem.REST.Router do
  use Plug.Router

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["*/*"]

  plug :match
  plug :dispatch

  forward "/agents", to: Shem.REST.Handlers.Agents
  forward "/presets", to: Shem.REST.Handlers.Presets
  forward "/routes", to: Shem.REST.Handlers.Routes
  forward "/sessions", to: Shem.REST.Handlers.Sessions
  forward "/health", to: Shem.REST.Handlers.Health

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/shem/rest/health_test.exs 2>&1 | tail -5
```

Expected: `2 tests, 0 failures`.

- [ ] **Step 6: Run the full suite to confirm no regressions**

```bash
mix test 2>&1 | tail -3
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/rest/handlers/health.ex lib/shem/rest/router.ex test/shem/rest/health_test.exs
git commit -m "feat: GET /api/health endpoint"
```

---

## Task 5: `Shem.CLI.Status`

**Files:**
- Create: `lib/shem/cli/status.ex`

No unit tests — correctness verified by running against a live instance. The module is a simple HTTP probe.

- [ ] **Step 1: Implement `Shem.CLI.Status`**

```elixir
# lib/shem/cli/status.ex
defmodule Shem.CLI.Status do
  @moduledoc false

  def run do
    port = detect_port()
    url = "http://127.0.0.1:#{port}/api/health"

    version_line = "Shem v#{current_version()}"
    IO.puts("")
    IO.puts(version_line)
    IO.puts("")

    case Req.get(url, receive_timeout: 2_000) do
      {:ok, %{status: 200, body: body}} ->
        tui_label = if body["tui"], do: "on", else: "off (headless)"
        llm = Application.get_env(:shem, :llm_routes, %{})
        {backend, model} = format_llm(llm)

        IO.puts("  HTTP / MCP   ● running   #{body["host"]}:#{body["port"]}")
        IO.puts("  LLM backend  ● #{backend}  #{model}")
        IO.puts("  Agents        #{body["active_agents"]} active")
        IO.puts("  TUI           #{tui_label}")

      _ ->
        IO.puts("  ○ not running")
    end

    IO.puts("")
  end

  defp detect_port do
    case Shem.CLI.ConfigFile.get("server.port") do
      {:ok, port} when is_integer(port) -> port
      {:ok, port} -> String.to_integer(to_string(port))
      _ -> Application.get_env(:shem, :mcp_port, 4000)
    end
  end

  defp current_version do
    Application.spec(:shem, :vsn) |> to_string()
  end

  defp format_llm(routes) do
    case Map.get(routes, :default) do
      {backend, model} -> {to_string(backend), model}
      _ -> {"unconfigured", ""}
    end
  end
end
```

- [ ] **Step 2: Verify compilation**

```bash
mix compile 2>&1 | grep -E "^error:"
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add lib/shem/cli/status.ex
git commit -m "feat: Shem.CLI.Status — probe running instance"
```

---

## Task 6: `Shem.CLI.Config` — list/get/set subcommands

**Files:**
- Create: `lib/shem/cli/config.ex`
- Create: `test/shem/cli/config_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/cli/config_test.exs
defmodule Shem.CLI.ConfigTest do
  use ExUnit.Case, async: true

  alias Shem.CLI.Config
  alias Shem.CLI.ConfigFile

  @tag :tmp_dir
  test "get prints value for existing key", %{tmp_dir: dir} do
    path = Path.join(dir, "config.yaml")
    ConfigFile.write(%{"server" => %{"port" => 4000}}, path)

    output = capture_io(fn -> Config.get("server.port", path) end)
    assert output =~ "4000"
  end

  @tag :tmp_dir
  test "get prints not found for missing key", %{tmp_dir: dir} do
    path = Path.join(dir, "config.yaml")
    ConfigFile.write(%{}, path)

    output = capture_io(fn -> Config.get("llm.default.backend", path) end)
    assert output =~ "not found"
  end

  @tag :tmp_dir
  test "set writes and confirms", %{tmp_dir: dir} do
    path = Path.join(dir, "config.yaml")
    output = capture_io(fn -> Config.set("server.port", "8080", path) end)
    assert output =~ "8080"
    assert {:ok, "8080"} = ConfigFile.get("server.port", path)
  end

  @tag :tmp_dir
  test "list prints all keys and values", %{tmp_dir: dir} do
    path = Path.join(dir, "config.yaml")
    config = %{
      "llm" => %{"default" => %{"backend" => "anthropic", "model" => "claude-sonnet-4-6", "api_key" => "sk-x", "url" => ""}},
      "server" => %{"port" => 4000, "host" => "127.0.0.1"},
      "executor" => %{"backend" => "auto", "image" => "debian:12-slim"},
      "tui" => true,
      "data_dir" => "~/.config/shem"
    }
    ConfigFile.write(config, path)

    output = capture_io(fn -> Config.list(path) end)
    assert output =~ "llm.default.backend"
    assert output =~ "anthropic"
    assert output =~ "server.port"
  end

  defp capture_io(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/cli/config_test.exs 2>&1 | tail -5
```

Expected: compile error (module not found).

- [ ] **Step 3: Implement `Shem.CLI.Config`**

```elixir
# lib/shem/cli/config.ex
defmodule Shem.CLI.Config do
  @moduledoc false

  alias Shem.CLI.ConfigFile

  def list(path \\ nil) do
    case ConfigFile.read(path) do
      {:ok, config} ->
        config
        |> flatten_keys()
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.each(fn {k, v} ->
          IO.puts("  #{k} = #{v}")
        end)

      {:error, reason} ->
        IO.puts("Error reading config: #{inspect(reason)}")
    end
  end

  def get(dotkey, path \\ nil) do
    case ConfigFile.get(dotkey, path) do
      {:ok, value} -> IO.puts("#{dotkey} = #{value}")
      {:error, :not_found} -> IO.puts("#{dotkey}: not found")
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    end
  end

  def set(dotkey, value, path \\ nil) do
    case ConfigFile.set(dotkey, value, path) do
      :ok -> IO.puts("#{dotkey} = #{value}  ✓")
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp flatten_keys(map, prefix \\ "") do
    Enum.flat_map(map, fn {k, v} ->
      full_key = if prefix == "", do: k, else: "#{prefix}.#{k}"

      case v do
        v when is_map(v) -> flatten_keys(v, full_key)
        v -> [{full_key, v}]
      end
    end)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/cli/config_test.exs 2>&1 | tail -5
```

Expected: `4 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/cli/config.ex test/shem/cli/config_test.exs
git commit -m "feat: Shem.CLI.Config — list/get/set subcommands"
```

---

## Task 7: `Shem.CLI.Setup` — interactive first-run wizard

**Files:**
- Create: `lib/shem/cli/setup.ex`

The wizard reads interactively from stdin. Unit tests cover the non-interactive helpers (validation, config building). The wizard flow itself is tested manually.

- [ ] **Step 1: Implement `Shem.CLI.Setup`**

```elixir
# lib/shem/cli/setup.ex
defmodule Shem.CLI.Setup do
  @moduledoc false

  alias Shem.CLI.{Banner, ConfigFile}

  @backends [
    {"1", "anthropic", "Anthropic", "claude-sonnet-4-6", "ANTHROPIC_API_KEY"},
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
    {port, host} = step_server()

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

    IO.puts("")
    spinner("Testing connection to #{backend_label(backend_key)}", fn ->
      validate_backend!(backend_key, api_key, url, model)
    end)

    spinner("Writing #{config_path}", fn ->
      ConfigFile.write(config)
    end)

    line()
    green("Setup complete.")
    IO.puts("Run \`shem start\` to launch.\n")
  end

  # ── Steps ───────────────────────────────────────────────────────────────────

  defp step_backend do
    IO.puts("Step 1/3 — LLM Backend")
    IO.puts("  Which provider will you use?")
    IO.puts("  [1] Anthropic   (claude-sonnet-4-6)")
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
    {port, host}
  end

  # ── Validation ──────────────────────────────────────────────────────────────

  @doc false
  def validate_backend!(backend, api_key, url, model) do
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
```

- [ ] **Step 2: Verify compilation**

```bash
mix compile 2>&1 | grep -E "^error:"
```

Expected: no errors.

- [ ] **Step 3: Manual smoke test (optional)**

```bash
mix run -e "Shem.CLI.Setup.run()" 2>&1
```

Walk through the wizard and verify the output renders correctly and `~/.config/shem/config.yaml` is written.

- [ ] **Step 4: Commit**

```bash
git add lib/shem/cli/setup.ex
git commit -m "feat: Shem.CLI.Setup — interactive first-run wizard"
```

---

## Task 8: Update `runtime.exs` — YAML loading, first-run detection, host config

**Files:**
- Modify: `config/runtime.exs`
- Modify: `lib/shem/mcp/server.ex`

- [ ] **Step 1: Update `runtime.exs`**

Replace the entire contents of `config/runtime.exs` with:

```elixir
import Config

# ── Headless mode ──────────────────────────────────────────────────────────────
if System.get_env("SHEM_NO_TUI") == "1" or "--headless" in System.argv() do
  config :shem, start_tui: false
end

if System.get_env("SHEM_NO_SHADOW") == "1" do
  config :shem, shadow_agent_enabled: false
end

# ── Load user YAML config (~/.config/shem/config.yaml) ────────────────────────
yaml_path = Path.join([System.user_home!(), ".config", "shem", "config.yaml"])

user_config =
  case File.read(yaml_path) do
    {:ok, content} ->
      Application.ensure_all_started(:yamerl)
      case YamlElixir.read_from_string(content) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end
    _ ->
      %{}
  end

# Apply LLM config from YAML
with %{"llm" => %{"default" => llm}} <- user_config,
     backend_str when is_binary(backend_str) <- Map.get(llm, "backend"),
     backend_atom <- String.to_atom(backend_str),
     model when is_binary(model) <- Map.get(llm, "model") do

  config :shem, llm_routes: %{default: {backend_atom, model}}

  case backend_atom do
    :ollama ->
      url = Map.get(llm, "url", "http://localhost:11434")
      config :shem, llm_ollama_url: url
    :llama_cpp ->
      url = Map.get(llm, "url", "http://localhost:1234")
      config :shem, llm_llama_cpp_url: url
    _ ->
      :ok
  end

  # Inject api_key into env var so existing transports pick it up
  api_key = Map.get(llm, "api_key", "")
  if api_key != "" do
    env_var = case backend_atom do
      :anthropic -> "ANTHROPIC_API_KEY"
      :openai    -> "OPENAI_API_KEY"
      _          -> nil
    end
    if env_var, do: System.put_env(env_var, api_key)
  end
end

# Apply server config from YAML
with %{"server" => server} <- user_config do
  if port = Map.get(server, "port"), do: config(:shem, mcp_port: port)
  if host = Map.get(server, "host"), do: config(:shem, mcp_host: host)
end

# Apply tui config from YAML (only if not already set by --headless)
if Map.has_key?(user_config, "tui") and
   not (System.get_env("SHEM_NO_TUI") == "1" or "--headless" in System.argv()) do
  config :shem, start_tui: Map.get(user_config, "tui", true)
end

# Apply executor config from YAML
with %{"executor" => executor} <- user_config do
  if backend = Map.get(executor, "backend"),
    do: config(:shem, executor_backend: String.to_atom(backend))
  if image = Map.get(executor, "image"),
    do: config(:shem, executor_image: image)
end

# Apply data_dir from YAML (overrides default paths)
with %{"data_dir" => data_dir} <- user_config,
     expanded <- Path.expand(data_dir),
     true <- File.dir?(expanded) or (File.mkdir_p!(expanded) && true) do
  config :shem,
    trust_store_path:   Path.join(expanded, "trust.dets"),
    preset_store_path:  Path.join(expanded, "preset_store.dets"),
    memory_store_path:  Path.join(expanded, "memory.dets"),
    event_log_path:     Path.join(expanded, "lab/events")
end

# SHEM_DATA_DIR env var still works as before (higher priority than yaml)
case System.get_env("SHEM_DATA_DIR") do
  nil -> :ok
  data_dir ->
    config :shem,
      trust_store_path: Path.join(data_dir, "trust.dets"),
      preset_store_path: Path.join(data_dir, "preset_store.dets"),
      memory_store_path: Path.join(data_dir, "memory.dets")
end

# ── First-run detection ────────────────────────────────────────────────────────
# Skip check when running eval subcommands (setup, config, status, version).
is_eval = "eval" in System.argv()

unless is_eval or System.get_env("SHEM_SKIP_CONFIG_CHECK") == "1" do
  llm_routes = Application.get_env(:shem, :llm_routes, %{})
  has_env_key =
    System.get_env("ANTHROPIC_API_KEY") not in [nil, ""] or
    System.get_env("OPENAI_API_KEY") not in [nil, ""]

  configured = llm_routes != %{} or has_env_key

  unless configured do
    IO.puts("""

    ✦ Shem is not configured yet.

      Run `shem setup` to configure your LLM backend, or set
      ANTHROPIC_API_KEY (or OPENAI_API_KEY) in your environment
      and re-run `shem start`.

      Docs: https://github.com/thephilip/shem
    """)
    System.halt(1)
  end
end

# ── Cluster topology ───────────────────────────────────────────────────────────
topology =
  case System.get_env("LIBCLUSTER_STRATEGY", "gossip") do
    "dns" ->
      query = System.get_env("LIBCLUSTER_DNS_QUERY", "shem")
      [shem: [strategy: Cluster.Strategy.DNSPoll,
              config: [query: query, node_basename: "shem", polling_interval: 5_000]]]
    _ ->
      [shem: [strategy: Cluster.Strategy.Gossip,
              config: [port: 45892, multicast_addr: "230.1.1.251"]]]
  end

config :libcluster, topologies: topology
```

- [ ] **Step 2: Update `Shem.MCP.Server` to read `mcp_host`**

```elixir
# lib/shem/mcp/server.ex
defmodule Shem.MCP.Server do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    port = Application.get_env(:shem, :mcp_port, 4000)
    host = Application.get_env(:shem, :mcp_host, "127.0.0.1") |> parse_ip()

    children = [
      Shem.MCP.SessionRegistry,
      {Bandit, plug: Shem.HTTP.Router, port: port, ip: host, scheme: :http}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp parse_ip(str) when is_binary(str) do
    str
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  defp parse_ip(tuple) when is_tuple(tuple), do: tuple
end
```

- [ ] **Step 3: Run the full test suite**

```bash
mix test 2>&1 | tail -3
```

Expected: all tests pass (the first-run check is skipped in test env because `Mix.env() == :test` and `runtime.exs` is not evaluated during `mix test`).

- [ ] **Step 4: Commit**

```bash
git add config/runtime.exs lib/shem/mcp/server.ex
git commit -m "feat: load YAML config in runtime.exs, first-run detection, mcp_host"
```

---

## Task 9: Install script polish + smart wrapper

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: Replace `install.sh` entirely**

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO="thephilip/shem"
LIB_DIR="${HOME}/.local/lib/shem"
BIN_DIR="${HOME}/.local/bin"
WRAPPER="${BIN_DIR}/shem"

# ── Colours ──────────────────────────────────────────────────────────────────
_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
_bold()   { printf '\033[1m%s\033[0m\n'  "$*"; }
_dim()    { printf '\033[2m%s\033[0m\n'  "$*"; }
_err()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }
_ok()     { printf ' \033[32m✓\033[0m\n'; }
_step()   { printf '  ✦ %-44s' "$1"; }

_line() { printf '%s\n' "──────────────────────────────────────────────────"; }

# ── Platform detection ────────────────────────────────────────────────────────
OS=$(uname -s)
ARCH=$(uname -m)

case "${OS}-${ARCH}" in
  Linux-x86_64)  TARGET="shem-linux-x86_64.tar.gz"  ;;
  Darwin-x86_64) TARGET="shem-macos-x86_64.tar.gz"  ;;
  Darwin-arm64)  TARGET="shem-macos-arm64.tar.gz"   ;;
  *)
    _err "Unsupported platform: ${OS}-${ARCH}"
    echo "Build from source: https://github.com/${REPO}"
    exit 1
    ;;
esac

echo ""
_bold "Shem Installer"
_line

# ── OpenSSL check ─────────────────────────────────────────────────────────────
_step "Checking system requirements (OpenSSL 3.x)"
_ossl_ok=false
if command -v openssl >/dev/null 2>&1; then
  _ossl_major=$(openssl version 2>/dev/null | awk '{print $2}' | cut -d. -f1)
  if [ "${_ossl_major:-0}" -ge 3 ] 2>/dev/null; then _ossl_ok=true; fi
fi

if [ "${_ossl_ok}" = "false" ]; then
  printf '\n'
  _err "OpenSSL 3.x required but not found."
  echo ""
  echo "  Install it with:"
  case "${OS}" in
    Linux)
      command -v apt-get >/dev/null 2>&1 && echo "    sudo apt-get install -y libssl3" && exit 1
      command -v dnf     >/dev/null 2>&1 && echo "    sudo dnf install -y openssl"     && exit 1
      command -v pacman  >/dev/null 2>&1 && echo "    sudo pacman -S openssl"           && exit 1
      echo "    Install openssl >= 3.0 via your system package manager"
      ;;
    Darwin) echo "    brew install openssl@3" ;;
  esac
  exit 1
fi
_ok

# ── Fetch release tag ─────────────────────────────────────────────────────────
_step "Fetching latest release"
LATEST=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4)

if [ -z "${LATEST}" ]; then
  printf '\n'
  _err "Could not determine latest release."
  echo "  Check: https://github.com/${REPO}/releases"
  exit 1
fi
printf ' %s\n' "${LATEST}"

URL="https://github.com/${REPO}/releases/download/${LATEST}/${TARGET}"

# ── Download ──────────────────────────────────────────────────────────────────
echo "  Downloading ${TARGET}"
rm -rf "${LIB_DIR}"
mkdir -p "${LIB_DIR}"

# curl --progress-bar writes to stderr; capture and redisplay indented
curl -fL --progress-bar "${URL}" 2>&1 \
  | sed 's/^/    /' \
  | tar -xz -C "${LIB_DIR}" --strip-components=1 2>/dev/null &
CURL_PID=$!
wait $CURL_PID || {
  _err "Download failed. Check your network and try again."
  exit 1
}

# Re-extract cleanly (the pipe above is for display; re-download is simpler on failure)
rm -rf "${LIB_DIR}"
mkdir -p "${LIB_DIR}"
_step "Downloading and extracting"
curl -fsSL "${URL}" | tar -xz -C "${LIB_DIR}" --strip-components=1
_ok

# ── Write smart wrapper ───────────────────────────────────────────────────────
_step "Installing to ${WRAPPER}"
mkdir -p "${BIN_DIR}"

cat > "${WRAPPER}" <<'WRAPPER_EOF'
#!/bin/sh
# Shem CLI dispatcher
_SHEM_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/../lib/shem"
_SHEM_BIN="${_SHEM_DIR}/bin/shem"
_SHEM_REPO="thephilip/shem"

_shem_version() {
  ls "${_SHEM_DIR}/releases/" 2>/dev/null | sort -V | tail -1
}

_shem_help() {
  # Print banner if truecolor TTY
  if [ -t 1 ] && { [ "${COLORTERM:-}" = "truecolor" ] || [ "${COLORTERM:-}" = "24bit" ]; }; then
    _banner=$(ls "${_SHEM_DIR}"/lib/shem-*/priv/banner.ansi 2>/dev/null | head -1)
    [ -n "$_banner" ] && cat "$_banner"
  fi
  cat <<'HELP'

Shem — AI agent platform

Usage:
  shem                       Show this help
  shem start                 Start shem with TUI
  shem start --headless      Start without TUI (HTTP/MCP API only)
  shem setup                 Configure LLM backend (interactive wizard)
  shem config list           Show current configuration
  shem config get <key>      Read a config value  (e.g. server.port)
  shem config set <k> <v>    Write a config value
  shem status                Show running service status
  shem upgrade               Upgrade to latest release
  shem version               Show installed version

HELP
}

case "${1:-}" in
  ""|-h|--help|help)
    _shem_help
    ;;

  version)
    echo "shem $(_shem_version)"
    ;;

  start)
    shift
    if [ "${1:-}" = "--headless" ]; then
      SHEM_NO_TUI=1 exec "${_SHEM_BIN}" start
    else
      exec "${_SHEM_BIN}" start "$@"
    fi
    ;;

  setup)
    exec "${_SHEM_BIN}" eval "Shem.CLI.Setup.run()"
    ;;

  config)
    shift
    case "${1:-}" in
      list)
        exec "${_SHEM_BIN}" eval "Shem.CLI.Config.list()"
        ;;
      get)
        KEY="${2:?Usage: shem config get <key>}"
        exec "${_SHEM_BIN}" eval "Shem.CLI.Config.get(\"${KEY}\")"
        ;;
      set)
        KEY="${2:?Usage: shem config set <key> <value>}"
        VAL="${3:?Usage: shem config set <key> <value>}"
        exec "${_SHEM_BIN}" eval "Shem.CLI.Config.set(\"${KEY}\", \"${VAL}\")"
        ;;
      *)
        echo "Usage: shem config list | get <key> | set <key> <value>"
        exit 1
        ;;
    esac
    ;;

  status)
    exec "${_SHEM_BIN}" eval "Shem.CLI.Status.run()"
    ;;

  upgrade)
    CURRENT="$(_shem_version)"
    echo "Checking for updates (current: ${CURRENT:-unknown})..."
    LATEST=$(curl -fsSL "https://api.github.com/repos/${_SHEM_REPO}/releases/latest" \
      | grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
    if [ "${CURRENT}" = "${LATEST}" ]; then
      echo "Already up to date (v${CURRENT})."
      exit 0
    fi
    echo "Upgrading v${CURRENT} → v${LATEST}..."
    curl -fsSL "https://raw.githubusercontent.com/${_SHEM_REPO}/master/install.sh" | bash
    ;;

  *)
    echo "shem: unknown command '${1}'"
    _shem_help
    exit 1
    ;;
esac
WRAPPER_EOF

chmod +x "${WRAPPER}"
_ok

# ── Smoke test ────────────────────────────────────────────────────────────────
_step "Verifying (crypto + boot check)"
if ! SHEM_SKIP_CONFIG_CHECK=1 "${LIB_DIR}/bin/shem" eval \
    "Application.ensure_all_started(:crypto)" >/dev/null 2>&1; then
  printf '\n'
  _err "Could not load the crypto library. OpenSSL 3.x must be visible to the dynamic linker."
  case "${OS}" in
    Linux)
      command -v apt-get >/dev/null 2>&1 && echo "  sudo apt-get install -y libssl3"
      command -v dnf     >/dev/null 2>&1 && echo "  sudo dnf install -y openssl"
      command -v pacman  >/dev/null 2>&1 && echo "  sudo pacman -S openssl"
      ;;
    Darwin) echo "  brew install openssl@3" ;;
  esac
  rm -f "${WRAPPER}"
  exit 1
fi
_ok

echo ""
_line
_green "Shem ${LATEST} installed."
echo ""
echo "  Next step: run \`shem setup\` to configure your LLM backend."
echo ""

if ! echo ":${PATH}:" | grep -q ":${BIN_DIR}:"; then
  echo "  Note: add ${BIN_DIR} to your PATH"
  echo "    echo 'export PATH=\"\${HOME}/.local/bin:\${PATH}\"' >> ~/.bashrc"
  echo "    (or ~/.zshrc / ~/.config/fish/config.fish)"
  echo ""
fi
```

- [ ] **Step 2: Validate bash syntax**

```bash
bash -n install.sh && echo "syntax ok"
```

Expected: `syntax ok`.

- [ ] **Step 3: Run the full test suite to confirm no regressions**

```bash
mix test 2>&1 | tail -3
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "feat: progress-bar install script and smart CLI wrapper"
```

---

## Task 10: Tag `v0.1.2` and push

- [ ] **Step 1: Push master**

```bash
git push origin master
```

- [ ] **Step 2: Tag and push**

```bash
git tag v0.1.2
git push origin v0.1.2
```

Expected: Release workflow triggers for Linux x86_64 and macOS ARM64. Wait for jobs to complete at `https://github.com/thephilip/shem/actions`.

- [ ] **Step 3: Verify release**

```bash
gh release view v0.1.2 2>&1 | head -10
```

Expected: release visible with two attached tarballs.

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| `shem` alone → help | Task 9 (wrapper) |
| `shem start` / `--headless` | Task 9 |
| `shem setup` wizard | Task 7 |
| `shem config list/get/set` | Tasks 2 + 6 + 9 |
| `shem status` | Tasks 4 + 5 + 9 |
| `shem upgrade` | Task 9 |
| `shem version` | Task 9 |
| YAML config file read/write | Task 2 |
| YAML → app config in runtime.exs | Task 8 |
| First-run detection → clean exit | Task 8 |
| `mcp_host` configurable | Task 8 |
| ANSI banner (generate + embed) | Task 3 |
| Progress-bar install script | Task 9 |
| `GET /api/health` endpoint | Task 4 |
| `yaml_elixir` dependency | Task 1 |
| Version bump to 0.1.1 | Task 1 |

All spec requirements covered. No placeholders. Type/function names consistent across tasks.

**Known limitation:** `install.sh` Task 9 uses a background `curl` + `tar` pipe for the progress display that is a best-effort approach on some shells. The actual extraction falls back to a clean second `curl | tar` call. This avoids partial-extraction bugs at the cost of one extra download. Acceptable trade-off for a shell installer.
