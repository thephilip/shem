defmodule Shem.Lab.GraduationGate.ElixirTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.GraduationGate

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir, System.tmp_dir!())
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  # Test env backend is Local: the gate runs a real host `elixir` subprocess —
  # the same command line the container runs, minus the container.

  @source """
  defmodule Gate.Doubler do
    def run(args), do: %{"result" => (args["n"] || 0) * 2}
  end
  """

  @test_source """
  defmodule Gate.DoublerTest do
    def run do
      %{"result" => 10} = Gate.Doubler.run(%{"n" => 5})
      %{"result" => 0} = Gate.Doubler.run(%{})
      :ok
    end
  end
  """

  test "graduates a valid Elixir tool as a :port runtime" do
    assert {:ok, tool} =
             GraduationGate.run(@source, @test_source, language: "elixir", description: "doubles n")

    assert {:port, runtime_path} = tool.runtime
    assert tool.metadata["language"] == "elixir"
    assert tool.metadata["description"] == "doubles n"
    assert tool.metadata[:property_tested] == false
    assert String.ends_with?(runtime_path, "_runtime.exs")
    assert File.exists?(runtime_path)
    # runtime artifact is the wrapper: source + runner loop
    assert File.read!(runtime_path) =~ "ShemRunner.loop(Gate.Doubler)"
  end

  test "failing test source yields {:error, :gate, _}" do
    failing = """
    defmodule Gate.FailTest do
      def run, do: raise("intentional failure")
    end
    """

    assert {:error, :gate, reason} = GraduationGate.run(@source, failing, language: "elixir")
    assert inspect(reason) =~ "intentional failure"
  end

  test "invalid source yields {:error, :compile, _}" do
    assert {:error, :compile, _} =
             GraduationGate.run("not elixir at all", @test_source, language: "elixir")
  end

  test "scan-denied source is rejected before any execution, with security event" do
    evil = """
    defmodule Gate.Evil do
      def run(_), do: System.cmd("echo", ["pwned"])
    end
    """

    assert {:error, :compile, "safety scan: " <> _} =
             GraduationGate.run(evil, @test_source, language: "elixir")
  end
end
