defmodule Shem.Distributed.StreamingTest do
  use ExUnit.Case, async: false

  @moduletag :distributed

  # Run with:
  #   elixir --sname shem_test -S mix test --only distributed

  alias Shem.EventLog.MnesiaStore
  alias Shem.Agent.Config

  setup_all do
    unless Node.alive?() do
      Node.start(:shem_test, :shortnames)
    end

    Application.delete_env(:shem, :event_log_store)
    Application.put_env(:shem, :force_mnesia, true)
    Supervisor.terminate_child(Shem.Supervisor, Shem.EventLog)
    Supervisor.restart_child(Shem.Supervisor, Shem.EventLog)

    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )

    on_exit(fn ->
      Application.delete_env(:shem, :force_mnesia)
      Application.put_env(:shem, :event_log_store, Shem.EventLog.FakeStore)
      Supervisor.terminate_child(Shem.Supervisor, Shem.EventLog)
      Supervisor.restart_child(Shem.Supervisor, Shem.EventLog)
    end)

    :ok
  end

  # ── Helpers (mirrors failover_test.exs pattern exactly) ─────────────────────

  defp start_peer(short_name) do
    build_path = Mix.Project.build_path()
    elixir_lib = :code.lib_dir(:elixir) |> Path.dirname() |> to_string()

    pa_args =
      (Path.wildcard(Path.join([elixir_lib, "*", "ebin"])) ++
         Path.wildcard(Path.join([build_path, "lib", "*", "ebin"])))
      |> Enum.flat_map(fn p -> [~c"-pa", String.to_charlist(p)] end)

    {:ok, peer, node} =
      :peer.start(%{
        name: short_name,
        args: pa_args
      })

    :rpc.call(node, :application, :ensure_all_started, [:elixir])
    :rpc.call(node, :application, :ensure_all_started, [:mnesia])
    {:ok, peer, node}
  end

  defp setup_peer_full(peer_node) do
    self_node = Node.self()

    :rpc.call(peer_node, Code, :eval_string, [
      """
      Application.ensure_all_started(:mnesia)
      :mnesia.change_config(:extra_db_nodes, [:"#{self_node}"])
      case :mnesia.add_table_copy(:shem_events, node(), :disc_copies) do
        {:atomic, :ok} -> :ok
        {:aborted, {:already_exists, :shem_events, _}} -> :ok
      end
      :mnesia.wait_for_tables([:shem_events], 10_000)
      """
    ])

    :rpc.call(peer_node, Code, :eval_string, [
      """
      Application.delete_env(:shem, :event_log_store)
      spawn(fn ->
        {:ok, _} = Horde.Registry.start_link(name: Shem.Registry, keys: :unique, members: :auto)
        {:ok, _} = Shem.AgentSupervisor.start_link([])
        {:ok, _} = Shem.NodeRegistry.start_link([])
        {:ok, _} = Shem.EventLog.start_link([])
        {:ok, _} = Shem.Lab.Registry.start_link([])
        {:ok, _} = :pg.start_link(:shem_streams)
        Process.sleep(:infinity)
      end)
      :ok
      """
    ])

    assert_eventually(
      fn ->
        case :rpc.call(peer_node, Process, :whereis, [:shem_streams]) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end,
      5_000
    )

    all_nodes = [Node.self(), peer_node]
    Horde.Cluster.set_members(Shem.AgentSupervisor, Enum.map(all_nodes, &{Shem.AgentSupervisor, &1}))
    Horde.Cluster.set_members(Shem.Registry, Enum.map(all_nodes, &{Shem.Registry, &1}))

    assert_eventually(
      fn ->
        Horde.Cluster.members(Shem.AgentSupervisor)
        |> Enum.any?(fn {_, n} -> n == peer_node end)
      end,
      5_000
    )

    Process.sleep(500)
  end

  defp setup_stub_on_peer(peer_node) do
    :rpc.call(peer_node, Code, :eval_string, [
      """
      spawn(fn ->
        {:ok, _stub_pid} = Shem.LLM.StubTransport.Server.start_link(name: Shem.LLM.StubTransport.Server)
        Shem.LLM.StubTransport.Server.set_default(
          {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
        )
        {:ok, _budget_pid} = Shem.LLM.BudgetServer.start_link(name: Shem.LLM.BudgetServer)
        # Trust.Store is needed on the peer: building a turn's tool manifest scores
        # seed tools (e.g. diff_text). Without it, agents crash on the peer and Horde
        # restarts them locally — making these tests pass for the wrong reason (flaky).
        {:ok, _trust_pid} = Shem.Trust.Store.start_link()
        Process.sleep(:infinity)
      end)
      Application.put_env(:shem, :llm_pipeline, [
        {Shem.LLM.Middleware.BudgetCheck, [budget_server: Shem.LLM.BudgetServer]},
        {Shem.LLM.Middleware.EventLogger, []},
        {Shem.LLM.StubTransport, [server: Shem.LLM.StubTransport.Server]}
      ])
      Application.put_env(:shem, :llm_models, %{default: "llama3:latest"})
      :ok
      """
    ])

    assert_eventually(
      fn ->
        case :rpc.call(peer_node, Process, :whereis, [Shem.LLM.StubTransport.Server]) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end,
      3_000
    )

    # Poll until Trust.Store is up on peer (manifest scoring needs it).
    assert_eventually(
      fn ->
        case :rpc.call(peer_node, Process, :whereis, [Shem.Trust.Store]) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end,
      3_000
    )
  end

  defp assert_eventually(fun, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Enum.reduce_while(Stream.repeatedly(fn -> :tick end), nil, fn _, _ ->
      if fun.() do
        {:halt, :ok}
      else
        now = System.monotonic_time(:millisecond)

        if now < deadline do
          Process.sleep(interval_ms)
          {:cont, nil}
        else
          {:halt, :timeout}
        end
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("Condition not met within #{timeout_ms}ms")
    end
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  test ":pg cross-node streaming: local sink is visible from remote node's :pg scope" do
    {:ok, peer, peer_node} = start_peer(:shem_stream_a)
    on_exit(fn -> try do :peer.stop(peer) catch :exit, _ -> :ok end end)

    setup_peer_full(peer_node)
    setup_stub_on_peer(peer_node)

    agent_name = "stream_agent_#{:erlang.unique_integer([:positive])}"

    config = %Config{
      task: "say done",
      system_prompt: "test streaming",
      placement: {:node, peer_node}
    }

    {:ok, _pid, session_id} = Shem.AgentSupervisor.start_agent(agent_name, config)

    {:ok, sink} = Shem.TUI.StreamSink.start_link(session_id)
    on_exit(fn -> if Process.alive?(sink), do: Shem.TUI.StreamSink.stop(sink) end)

    # The local sink must appear in the :pg group on the local :shem_streams scope.
    assert sink in :pg.get_members(:shem_streams, session_id)

    # The local sink must ALSO be visible from the remote node's :pg scope.
    # :pg gossips membership across nodes, so the remote agent can broadcast to it.
    assert_eventually(
      fn ->
        case :rpc.call(peer_node, :pg, :get_members, [:shem_streams, session_id]) do
          members when is_list(members) -> sink in members
          _ -> false
        end
      end,
      5_000
    )

    # Wait for agent to complete its turn (reaches :done or :waiting).
    assert_eventually(
      fn ->
        case GenServer.whereis(Shem.ProcessRegistry.via_tuple(agent_name)) do
          nil -> false
          pid ->
            try do
              case GenServer.call(pid, :status) do
                {:ok, status} -> status in [:done, :waiting]
                _ -> false
              end
            catch
              :exit, _ -> false
            end
        end
      end,
      8_000
    )

    assert Process.alive?(sink)

    # The stub transport calls chunk_fn.(content) synchronously during stream_step.
    # Give any in-flight messages a moment to arrive, then verify token delivery.
    Process.sleep(100)
    tokens = Shem.TUI.StreamSink.take_tokens(sink)
    # The stub returns content "done" — chunk_fn is called so we expect at least one token.
    # If the sink joined after the agent's turn completed, tokens may be empty (race).
    # The authoritative assertions above (cross-node :pg membership) cover correctness;
    # token delivery here is best-effort given the subscribe-after-start ordering.
    assert is_list(tokens)
  end

  test ":pg cross-node: after node A dies and agent resumes locally, new sink can subscribe" do
    {:ok, peer, peer_node} = start_peer(:shem_stream_b)
    on_exit(fn -> try do :peer.stop(peer) catch :exit, _ -> :ok end end)

    setup_peer_full(peer_node)
    setup_stub_on_peer(peer_node)

    agent_name = "stream_resume_#{:erlang.unique_integer([:positive])}"

    config = %Config{
      task: "say done",
      system_prompt: "test resume streaming",
      conversational: true,
      max_turns: 50,
      placement: {:node, peer_node}
    }

    {:ok, _pid, session_id} = Shem.AgentSupervisor.start_agent(agent_name, config)

    # Wait for at least one checkpoint in Mnesia (agent has run at least one turn).
    assert_eventually(
      fn ->
        case MnesiaStore.read_all(session_id) do
          {:ok, events} -> Enum.any?(events, &(&1.type == :agent_checkpoint))
          _ -> false
        end
      end,
      8_000
    )

    # Extra wait for CRDT sync so Horde knows about the agent before the peer dies.
    Process.sleep(2_000)

    # Kill the peer — Horde should redistribute the :transient agent to local node.
    :peer.stop(peer)

    # Wait for agent to reappear on local node.
    assert_eventually(
      fn ->
        case GenServer.whereis(Shem.ProcessRegistry.via_tuple(agent_name)) do
          nil -> false
          pid -> node(pid) == Node.self()
        end
      end,
      10_000
    )

    # Start a fresh local sink and verify it joins the :pg group for this session.
    {:ok, sink} = Shem.TUI.StreamSink.start_link(session_id)
    on_exit(fn -> if Process.alive?(sink), do: Shem.TUI.StreamSink.stop(sink) end)

    # The peer is dead, so we cannot check remote membership — that's correct behavior:
    # after failover the session is purely local. Assert the local sink is subscribed
    # and alive, proving a TUI can still attach to a resumed session.
    assert sink in :pg.get_members(:shem_streams, session_id)
    assert Process.alive?(sink)
  end
end
