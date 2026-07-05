defmodule Shem.REST.PacksGrantsTest do
  use ExUnit.Case, async: false
  alias Shem.Lab.Pack

  # Deviation from plan: the plan's acceptance-only test passed vacuously
  # (Schema.validate drops unknown keys instead of rejecting them), so it
  # could never catch grants being silently ignored. This version installs a
  # real elevated-profile pack through the MCP handler and asserts the grant
  # is forwarded — rejected as needs_consent iff forwarding is missing.
  @tool_source """
  # name: pg_echo
  def run(args):
      return {"echo": args.get("value")}
  """
  @test_source """
  from tool import run
  def test_echo():
      assert run({"value": "x"}) == {"echo": "x"}
  """

  defp make_pack_repo!(tmp) do
    tools_dir = Path.join(tmp, "tools")
    File.mkdir_p!(tools_dir)

    manifest = %{
      "description" => "echo",
      "schema" => %{},
      "language" => "python",
      "test_source" => @test_source,
      "sandbox" => %{"network" => true}
    }

    File.write!(
      Path.join(tmp, "pack.json"),
      Jason.encode!(%{"name" => "pg_test_pack", "version" => "1.0.0", "tools" => ["pg_echo"]})
    )

    File.write!(Path.join(tools_dir, "pg_echo.json"), Jason.encode!(manifest))
    File.write!(Path.join(tools_dir, "pg_echo.py"), @tool_source)

    {_, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
    {_, 0} = System.cmd("git", ["add", "-A"], cd: tmp)

    {_, 0} =
      System.cmd(
        "git",
        ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "pack"],
        cd: tmp
      )

    "file://" <> tmp
  end

  setup do
    # Mirrors pack_contract_test.exs: gating a real Python tool needs the
    # Container backend + runtime bin (test config defaults to Local).
    runtime = System.find_executable("podman") || System.find_executable("docker")
    Process.put(:shem_executor_backend, Shem.Lab.Executor.Backend.Container)
    prev_bin = Application.get_env(:shem, :container_runtime_bin)
    Application.put_env(:shem, :container_runtime_bin, runtime)

    prev_timeout = Application.get_env(:shem, :executor_timeout_ms)
    Application.put_env(:shem, :executor_timeout_ms, 180_000)

    tmp = Path.join(System.tmp_dir!(), "pg_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      Pack.uninstall("pg_test_pack")
      File.rm_rf(tmp)
      Application.put_env(:shem, :executor_timeout_ms, prev_timeout)

      if prev_bin,
        do: Application.put_env(:shem, :container_runtime_bin, prev_bin),
        else: Application.delete_env(:shem, :container_runtime_bin)
    end)

    {:ok, tmp: tmp}
  end

  test "MCP install_pack forwards grants to Pack.install", %{tmp: tmp} do
    repo = make_pack_repo!(tmp)

    {:ok, result} =
      Shem.MCP.Handlers.InstallPack.call(%{"repo" => repo, "grants" => ["pg_echo"]})

    assert result.rejected == []
    assert [_tool_id] = result.installed
  end

  test "MCP install_pack without grants still fail-closes elevated tools", %{tmp: tmp} do
    repo = make_pack_repo!(tmp)

    {:ok, result} = Shem.MCP.Handlers.InstallPack.call(%{"repo" => repo})

    assert result.installed == []
    assert [%{id: "pg_echo", reason: "needs_consent"}] =
             Enum.map(result.rejected, &Map.take(&1, [:id, :reason]))
  end
end
