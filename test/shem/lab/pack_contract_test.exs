defmodule Shem.Lab.PackContractTest do
  use ExUnit.Case, async: false
  alias Shem.Lab.{Pack, Workspace}

  # NOTE: deviates from the brief's literal fixture — Shem's Python wrapper
  # (lib/shem/lab/languages.ex `wrapper/2`) already appends the
  # `if __name__ == "__main__": for line in sys.stdin: ...` stdio loop around
  # the graduated source. The brief's fixture included its own unguarded
  # `for line in sys.stdin` loop, which runs at *import* time when pytest
  # does `from tool import run`, and collides with pytest's own stdin capture
  # (`OSError: pytest: reading from stdin while output is captured!`). The
  # tool source only needs to define `run`.
  @tool_source """
  # name: pc_echo
  def run(args):
      return {"echo": args.get("value")}
  """
  @test_source """
  from tool import run
  def test_echo():
      assert run({"value": "x"}) == {"echo": "x"}
  """

  defp make_pack_repo!(tmp, manifest_extra) do
    tools_dir = Path.join(tmp, "tools")
    File.mkdir_p!(tools_dir)

    manifest =
      Map.merge(
        %{"description" => "echo", "schema" => %{}, "language" => "python",
          "test_source" => @test_source},
        manifest_extra
      )

    File.write!(Path.join(tmp, "pack.json"),
      Jason.encode!(%{"name" => "pc_test_pack", "version" => "1.0.0", "tools" => ["pc_echo"]}))
    File.write!(Path.join(tools_dir, "pc_echo.json"), Jason.encode!(manifest))
    File.write!(Path.join(tools_dir, "pc_echo.py"), @tool_source)

    {_, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
    {_, 0} = System.cmd("git", ["add", "-A"], cd: tmp)
    {_, 0} = System.cmd("git", ["-c", "user.email=t@t", "-c", "user.name=t",
                                "commit", "-qm", "pack"], cd: tmp)
    "file://" <> tmp
  end

  setup do
    # These fixtures gate a real Python tool, which needs a container runtime
    # (test config defaults to the Local backend, which can't `cd /workspace`).
    # Mirrors the fixture arrangement in graduation_gate/python_test.exs's
    # :python_integration setup.
    runtime = System.find_executable("podman") || System.find_executable("docker")
    Process.put(:shem_executor_backend, Shem.Lab.Executor.Backend.Container)
    prev_bin = Application.get_env(:shem, :container_runtime_bin)
    Application.put_env(:shem, :container_runtime_bin, runtime)

    prev_timeout = Application.get_env(:shem, :executor_timeout_ms)
    Application.put_env(:shem, :executor_timeout_ms, 180_000)

    tmp = Path.join(System.tmp_dir!(), "pc_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn ->
      Pack.uninstall("pc_test_pack")
      File.rm_rf(tmp)
      Application.put_env(:shem, :executor_timeout_ms, prev_timeout)

      if prev_bin,
        do: Application.put_env(:shem, :container_runtime_bin, prev_bin),
        else: Application.delete_env(:shem, :container_runtime_bin)
    end)
    {:ok, tmp: tmp}
  end

  test "elevated profile without grant is rejected with structured report", %{tmp: tmp} do
    repo = make_pack_repo!(tmp, %{"sandbox" => %{"network" => true}})
    {:ok, result} = Pack.install(repo)
    assert result.installed == []
    assert [%{id: "pc_echo", reason: "needs_consent", requested: %{"network" => true}}] =
             result.rejected
  end

  test "elevated profile with grant installs and tags granted", %{tmp: tmp} do
    repo = make_pack_repo!(tmp, %{"sandbox" => %{"network" => true},
                                  "actions" => [%{"name" => "echo", "risk" => "read"}]})
    {:ok, result} = Pack.install(repo, ".", grants: ["pc_echo"])
    assert [tool_id] = result.installed

    {:ok, json} = File.read(Workspace.manifest_path(tool_id))
    manifest = Jason.decode!(json)
    assert manifest["granted"] == %{"network" => true}
    assert manifest["actions"] == [%{"name" => "echo", "risk" => "read"}]
  end

  test "default profile installs without grant, no granted key", %{tmp: tmp} do
    repo = make_pack_repo!(tmp, %{})
    {:ok, result} = Pack.install(repo)
    assert [tool_id] = result.installed
    manifest = Jason.decode!(File.read!(Workspace.manifest_path(tool_id)))
    refute Map.has_key?(manifest, "granted")
  end

  test "invalid sandbox block rejects the tool", %{tmp: tmp} do
    repo = make_pack_repo!(tmp, %{"sandbox" => %{"network" => "yes"}})
    {:ok, result} = Pack.install(repo)
    assert result.installed == []
    assert [%{id: "pc_echo"}] = result.rejected
  end

  test "invalid actions risk rejects the tool", %{tmp: tmp} do
    repo = make_pack_repo!(tmp, %{"actions" => [%{"name" => "x", "risk" => "sudo"}]})
    {:ok, result} = Pack.install(repo)
    assert result.installed == []
  end

  test "rw mount elevation is reported in requested", %{tmp: tmp} do
    repo = make_pack_repo!(tmp, %{"sandbox" =>
      %{"mounts" => [%{"host" => "~/.cache/x", "container" => "/cache", "mode" => "rw"}]}})
    {:ok, result} = Pack.install(repo)
    assert [%{reason: "needs_consent",
              requested: %{"mounts" => [%{"mode" => "rw"}]}}] =
             result.rejected |> Enum.map(fn r ->
               update_in(r.requested["mounts"], fn ms ->
                 Enum.map(ms, &Map.take(&1, ["mode"]))
               end)
             end)
  end

  test "registry exposes actions and granted after install", %{tmp: tmp} do
    repo = make_pack_repo!(tmp, %{"sandbox" => %{"network" => true},
                                  "actions" => [%{"name" => "echo", "risk" => "read"}]})
    {:ok, %{installed: [tool_id]}} = Pack.install(repo, ".", grants: ["pc_echo"])

    {:ok, tool} = Shem.Lab.Registry.lookup(tool_id)
    assert tool.metadata["actions"] == [%{"name" => "echo", "risk" => "read"}]
    assert tool.metadata["granted"] == %{"network" => true}
  end
end
