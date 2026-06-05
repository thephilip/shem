defmodule Shem.Adversarial.HardeningJobTest do
  use ExUnit.Case, async: false

  alias Shem.Adversarial.HardeningJob
  alias Shem.{EventLog, Lab}
  alias Shem.LLM.{Response, StubTransport}

  @tool_source """
  defmodule HardeningJobTestTool do
    def run(_args), do: :ok
  end
  """
  @tool_test_src """
  defmodule HardeningJobTestToolTest do
    def run, do: :ok
  end
  """

  setup do
    StubTransport.Server.reset()
    Shem.LLM.BudgetServer.reset()
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn ->
      File.rm_rf!(lab_dir)
      Lab.Registry.flush()
    end)

    {:ok, tool} = Lab.GraduationGate.run(@tool_source, @tool_test_src)
    {:ok, tool: tool}
  end

  defp stub(content, tokens \\ 5) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: tokens, model: :default, latency_ms: 1}}
    )
  end

  defp wait_done(pid, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(pid, deadline)
  end

  defp do_wait(pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("HardeningJob did not finish within timeout")
    else
      case GenServer.call(pid, :status) do
        %{status: :done} -> :ok
        _ ->
          Process.sleep(20)
          do_wait(pid, deadline)
      end
    end
  end

  defp events(session_id) do
    {:ok, evts} = EventLog.events(session_id)
    evts
  end

  describe "clean pass on round 1" do
    test "logs correct events and outcome :clean", %{tool: tool} do
      stub("NO_FAILURES_FOUND")

      {:ok, pid} = HardeningJob.start_link({tool.id, []})
      {:ok, session_id} = GenServer.call(pid, :session_id)
      wait_done(pid)

      evts = events(session_id)
      types = Enum.map(evts, & &1.type)
      assert :hardening_started in types
      assert :hardening_round_started in types
      assert :hardening_attack_complete in types
      assert :hardening_completed in types

      done = Enum.find(evts, &(&1.type == :hardening_completed))
      assert done.payload.outcome == :clean
      assert done.payload.rounds == 1
    end
  end

  describe "failure round 1, clean round 2" do
    test "runs 2 rounds and finishes :clean", %{tool: tool} do
      stub("FAILURES_FOUND: off-by-one on negative inputs")
      stub("I have fixed the tool.")
      stub("NO_FAILURES_FOUND")

      {:ok, pid} = HardeningJob.start_link({tool.id, []})
      {:ok, session_id} = GenServer.call(pid, :session_id)
      wait_done(pid)

      evts = events(session_id)
      done = Enum.find(evts, &(&1.type == :hardening_completed))
      assert done.payload.outcome == :clean
      assert done.payload.rounds == 2

      assert Enum.any?(evts, &(&1.type == :hardening_patch_complete))
    end
  end

  describe "max rounds reached" do
    test "stops with outcome :max_rounds_reached after max_rounds cycles", %{tool: tool} do
      # test config has adversarial_max_rounds: 3
      # Need 3 failure+patch pairs: round 0, 1, 2 → round becomes 3 → 3 >= 3 → stop
      stub("FAILURES_FOUND: error 1") ; stub("Fixed 1.")
      stub("FAILURES_FOUND: error 2") ; stub("Fixed 2.")
      stub("FAILURES_FOUND: error 3") ; stub("Fixed 3.")

      {:ok, pid} = HardeningJob.start_link({tool.id, []})
      {:ok, session_id} = GenServer.call(pid, :session_id)
      wait_done(pid, 15_000)

      evts = events(session_id)
      done = Enum.find(evts, &(&1.type == :hardening_completed))
      assert done.payload.outcome == :max_rounds_reached
      assert done.payload.rounds == 3
    end
  end

  describe "ambiguous red team response" do
    test "treats non-standard response as clean", %{tool: tool} do
      stub("I am not sure what happened here.")

      {:ok, pid} = HardeningJob.start_link({tool.id, []})
      {:ok, session_id} = GenServer.call(pid, :session_id)
      wait_done(pid)

      evts = events(session_id)
      done = Enum.find(evts, &(&1.type == :hardening_completed))
      assert done.payload.outcome == :clean
    end
  end
end
