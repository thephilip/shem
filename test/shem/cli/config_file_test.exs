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
  test "write/2 then read/1 round-trips unknown top-level key", %{tmp_dir: dir} do
    path = Path.join(dir, "config.yaml")
    assert :ok = ConfigFile.write(%{"log_level" => "debug"}, path)
    assert {:ok, result} = ConfigFile.read(path)
    assert result["log_level"] == "debug"
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
