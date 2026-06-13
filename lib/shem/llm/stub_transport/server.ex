defmodule Shem.LLM.StubTransport.Server do
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def push_response(server \\ __MODULE__, response),
    do: GenServer.call(server, {:push, response})

  def set_default(server \\ __MODULE__, response),
    do: GenServer.call(server, {:set_default, response})

  def calls(server \\ __MODULE__),
    do: GenServer.call(server, :calls)

  def pop(server \\ __MODULE__),
    do: GenServer.call(server, :pop)

  def reset(server \\ __MODULE__) do
    drain_agents()
    GenServer.call(server, :reset)
  end

  # Test isolation: an agent that outlives its test keeps consuming from this
  # global FIFO and can steal a response pushed by the NEXT test. Terminating
  # all live agents before clearing the queue guarantees a fresh queue is only
  # consumed by agents the current test starts itself. Runs client-side BEFORE
  # the :reset call — doing it inside the handler would deadlock with an agent
  # blocked in :pop.
  defp drain_agents do
    if Process.whereis(Shem.AgentSupervisor) do
      Shem.AgentSupervisor
      |> Horde.DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          Horde.DynamicSupervisor.terminate_child(Shem.AgentSupervisor, pid)

        _ ->
          :ok
      end)
    end

    :ok
  catch
    # supervisor races during app restarts must never fail a test setup
    :exit, _ -> :ok
  end

  @impl true
  def init(:ok), do: {:ok, %{queue: [], default: nil, calls: []}}

  @impl true
  def handle_call({:push, response}, _from, state),
    do: {:reply, :ok, %{state | queue: state.queue ++ [response]}}

  @impl true
  def handle_call({:set_default, response}, _from, state),
    do: {:reply, :ok, %{state | default: response}}

  @impl true
  def handle_call(:calls, _from, state),
    do: {:reply, state.calls, state}

  @impl true
  def handle_call(:pop, _from, %{queue: [head | rest]} = state),
    do: {:reply, {:ok, head}, %{state | queue: rest}}

  def handle_call(:pop, _from, %{queue: [], default: nil} = state),
    do: {:reply, :empty, state}

  def handle_call(:pop, _from, %{queue: [], default: default} = state),
    do: {:reply, {:ok, default}, state}

  def handle_call({:record_call, request}, _from, state),
    do: {:reply, :ok, %{state | calls: state.calls ++ [request]}}

  def handle_call(:reset, _from, _state),
    do: {:reply, :ok, %{queue: [], default: nil, calls: []}}
end
