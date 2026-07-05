defmodule Shem.PackContractE2ETest do
  use ExUnit.Case, async: false
  alias Shem.Lab.{Pack, Workspace}

  # One linear pass through the whole contract: consent -> grant -> policy ->
  # handles -> redaction -> chain. Assertions are the committed shapes from
  # pack_contract_test / guardrails_action_test / secrets_test / redact_test,
  # sequenced through one shared fixture pack.

  @dispatch_tool """
  # name: pc_dispatch
  def run(args):
      a = args.get("action")
      if a == "greet":
          return "hello"
      if a == "shout":
          return "HELLO"
      return "unknown"
  """
  @test_source """
  from tool import run
  def test_greet():
      assert run({"action": "greet"}) == "hello"
  """

  defp make_pack_repo!(tmp) do
    tools_dir = Path.join(tmp, "tools")
    File.mkdir_p!(tools_dir)

    manifest = %{
      "description" => "action dispatcher",
      "schema" => %{},
      "language" => "python",
      "test_source" => @test_source,
      "sandbox" => %{"network" => true},
      "actions" => [
        %{"name" => "greet", "risk" => "read"},
        %{"name" => "shout", "risk" => "read"}
      ]
    }

    File.write!(
      Path.join(tmp, "pack.json"),
      Jason.encode!(%{"name" => "pc_e2e_pack", "version" => "1.0.0", "tools" => ["pc_dispatch"]})
    )

    File.write!(Path.join(tools_dir, "pc_dispatch.json"), Jason.encode!(manifest))
    File.write!(Path.join(tools_dir, "pc_dispatch.py"), @dispatch_tool)

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
    runtime = System.find_executable("podman") || System.find_executable("docker")
    Process.put(:shem_executor_backend, Shem.Lab.Executor.Backend.Container)
    prev_bin = Application.get_env(:shem, :container_runtime_bin)
    Application.put_env(:shem, :container_runtime_bin, runtime)

    prev_timeout = Application.get_env(:shem, :executor_timeout_ms)
    Application.put_env(:shem, :executor_timeout_ms, 180_000)

    tmp = Path.join(System.tmp_dir!(), "pc_e2e_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      Pack.uninstall("pc_e2e_pack")
      File.rm_rf(tmp)
      Application.delete_env(:shem, :tool_policy)
      Application.delete_env(:shem, :secret_provider)
      Application.delete_env(:shem, :secret_resolver_fn)
      Application.put_env(:shem, :executor_timeout_ms, prev_timeout)

      if prev_bin,
        do: Application.put_env(:shem, :container_runtime_bin, prev_bin),
        else: Application.delete_env(:shem, :container_runtime_bin)
    end)

    {:ok, tmp: tmp}
  end

  test "full contract loop: consent -> grant -> policy -> handles -> redaction -> chain", %{tmp: tmp} do
    repo = make_pack_repo!(tmp)

    # 1. elevated profile, no grant -> rejected with structured report
    {:ok, result} = Pack.install(repo)
    assert result.installed == []

    assert [%{id: "pc_dispatch", reason: "needs_consent", requested: %{"network" => true}}] =
             result.rejected

    # 2. reinstall with grant -> installed; tagged manifest carries granted+actions
    {:ok, %{installed: [tool_id]}} = Pack.install(repo, ".", grants: ["pc_dispatch"])
    manifest = Jason.decode!(File.read!(Workspace.manifest_path(tool_id)))
    assert manifest["granted"] == %{"network" => true}
    assert [%{"name" => "greet"}, %{"name" => "shout"}] = manifest["actions"]

    {:ok, tool} = Shem.Lab.Registry.lookup(tool_id)
    declared = Enum.map(tool.metadata["actions"], & &1["name"])

    # 3. host policy denies one action; the other stays allowed
    Application.put_env(:shem, :tool_policy, %{deny: ["pc_dispatch.shout"]})

    assert {:blocked, _} =
             Shem.Guardrails.check_action("pc_dispatch", %{"action" => "shout"},
               policy: nil, actions: declared)

    assert :ok =
             Shem.Guardrails.check_action("pc_dispatch", %{"action" => "greet"},
               policy: nil, actions: declared)

    # 4. undeclared action is blocked fail-closed
    assert {:blocked, _} =
             Shem.Guardrails.check_action("pc_dispatch", %{"action" => "smuggle"},
               policy: nil, actions: declared)

    # 5. secret handles resolve for execution, but the logged args keep the handle
    Application.put_env(:shem, :secret_provider, "secret_store")
    Application.put_env(:shem, :secret_resolver_fn, fn "api_key" -> {:ok, "PLAINTEXT-XYZ"} end)

    original_args = %{"action" => "greet", "token" => %{"$secret" => "api_key"}}
    assert {:ok, resolved} = Shem.Secrets.resolve(original_args)
    assert resolved["token"] == "PLAINTEXT-XYZ"

    {:ok, session_id} = Shem.EventLog.start_session()
    {:ok, called_ev} =
      Shem.EventLog.append(session_id, :agent_tool_called,
        %{tool: "pc_dispatch", args: original_args})

    assert called_ev.payload.args["token"] == %{"$secret" => "api_key"}
    refute inspect(called_ev) =~ "PLAINTEXT-XYZ"

    # 6. sensitive result is redacted before hashing; the chain still verifies
    {:ok, result_ev} =
      Shem.EventLog.append(session_id, :agent_tool_result,
        %{tool: "pc_dispatch", result: %{"$sensitive" => "PLAINTEXT-XYZ"}})

    assert %{"$redacted" => _} = result_ev.payload.result

    {:ok, events} = Shem.EventLog.events(session_id)
    assert {:ok, :verified, _} = Shem.EventLog.Chain.verify(events, session_id)
    refute inspect(events) =~ "PLAINTEXT-XYZ"
  end
end
