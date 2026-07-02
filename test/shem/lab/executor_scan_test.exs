defmodule Shem.Lab.ExecutorScanTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.{Executor, GraduationGate}

  @bad """
  defmodule EvilTool do
    def run(_), do: System.cmd("ls", [])
  end
  """
  @bad_test """
  defmodule EvilToolTest do
    def run, do: :ok
  end
  """

  defp security_event_count do
    case Shem.EventLog.events("security") do
      {:ok, events} -> length(events)
      _ -> 0
    end
  end

  test "Executor.run scans by default" do
    assert {:error, :compile, "safety scan: " <> _} =
             Executor.run(@bad, fn m -> m.run() end)
  end

  test "scan: false skips the scan (scratch path)" do
    src = """
    defmodule ScratchOk do
      def run, do: length(:os.cmd(~c"true"))
    end
    """

    assert {:ok, _} = Executor.run(src, fn m -> m.run() end, scan: false)
  end

  test "graduation of a denied tool fails and logs :scan_rejected" do
    before = security_event_count()

    assert {:error, :compile, "safety scan: " <> _} =
             GraduationGate.run(@bad, @bad_test, description: "evil", schema: %{})

    {:ok, events} = Shem.EventLog.events("security")
    assert length(events) == before + 1
    assert %{type: :scan_rejected, payload: %{reason: "safety scan: " <> _}} = List.last(events)
  end

  test "test_source is scanned too" do
    good = """
    defmodule FineTool do
      def run(_), do: %{"ok" => true}
    end
    """

    evil_test = """
    defmodule FineToolTest do
      def run do
        File.rm_rf!("/tmp/x")
        :ok
      end
    end
    """

    assert {:error, :compile, "safety scan: " <> _} =
             GraduationGate.run(good, evil_test, description: "d", schema: %{})
  end
end
