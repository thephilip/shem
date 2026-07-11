defmodule Shem.Lab.ElixirSandboxE2ETest do
  use ExUnit.Case, async: false

  alias Shem.Lab.{GraduationGate, PortPool}

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir, System.tmp_dir!())
    on_exit(fn -> File.rm_rf!(lab_dir) end)

    runtime = System.find_executable("podman") || System.find_executable("docker")
    Process.put(:shem_executor_backend, Shem.Lab.Executor.Backend.Container)
    Application.put_env(:shem, :container_runtime_bin, runtime)
    on_exit(fn -> Application.put_env(:shem, :container_runtime_bin, nil) end)

    prev = Application.get_env(:shem, :executor_timeout_ms)
    Application.put_env(:shem, :executor_timeout_ms, 180_000)
    on_exit(fn -> Application.put_env(:shem, :executor_timeout_ms, prev) end)

    start_supervised!(PortPool.Supervisor)
    :ok
  end

  @tag :elixir_integration
  test "graduate + invoke an Elixir tool fully containerized" do
    source = """
    defmodule E2E.Doubler do
      def run(args), do: %{"result" => (args["n"] || 0) * 2}
    end
    """

    test_source = """
    defmodule E2E.DoublerTest do
      def run do
        %{"result" => 10} = E2E.Doubler.run(%{"n" => 5})
        :ok
      end
    end
    """

    assert {:ok, tool} = GraduationGate.run(source, test_source, language: "elixir")
    {:port, runtime_path} = tool.runtime

    assert {:ok, pool} = PortPool.Supervisor.ensure_started(tool.id, runtime_path, "elixir")
    assert {:ok, %{"result" => 42}} = PortPool.call(pool, %{"n" => 21}, 60_000)
    # warm worker: second call is fast and correct
    assert {:ok, %{"result" => 0}} = PortPool.call(pool, %{}, 60_000)
  end

  # UNTAGGED: host-fallback parity — no container runtime, the PortPool worker
  # is a plain host `elixir` subprocess (spec §3). Runs in the default suite.
  test "host-fallback invocation round-trip without a container runtime" do
    Process.delete(:shem_executor_backend)
    Application.put_env(:shem, :container_runtime_bin, nil)

    source = """
    defmodule E2E.HostEcho do
      def run(args), do: %{"echo" => args["msg"]}
    end
    """

    test_source = """
    defmodule E2E.HostEchoTest do
      def run do
        %{"echo" => "hi"} = E2E.HostEcho.run(%{"msg" => "hi"})
        :ok
      end
    end
    """

    assert {:ok, tool} = GraduationGate.run(source, test_source, language: "elixir")
    {:port, runtime_path} = tool.runtime

    assert {:ok, pool} = PortPool.Supervisor.ensure_started(tool.id, runtime_path, "elixir")
    assert {:ok, %{"echo" => "shem"}} = PortPool.call(pool, %{"msg" => "shem"}, 30_000)
  end

  @tag :elixir_integration
  test "property-tested tool graduates via Mix.install([:stream_data]) and skips trust seeding" do
    source = """
    defmodule E2E.Abs do
      def run(args), do: %{"result" => abs(args["n"] || 0)}
    end
    """

    test_source = """
    defmodule E2E.AbsTest do
      def run do
        Enum.each(Enum.take(StreamData.integer(), 50), fn n ->
          true = E2E.Abs.run(%{"n" => n})["result"] >= 0
        end)

        :ok
      end
    end
    """

    assert {:ok, tool} = GraduationGate.run(source, test_source, language: "elixir")
    assert tool.metadata[:property_tested] == true
    assert Shem.Trust.Store.score(tool.id) == {:error, :unrated}
  end
end
