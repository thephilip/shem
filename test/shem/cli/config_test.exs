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
