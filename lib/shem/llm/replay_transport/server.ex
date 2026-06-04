defmodule Shem.LLM.ReplayTransport.Server do
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @spec load(GenServer.server(), [map()]) :: :ok
  def load(server \\ __MODULE__, queue),
    do: GenServer.call(server, {:load, queue})

  @spec pop(GenServer.server()) ::
          {:ok, map(), non_neg_integer()} | {:exhausted, non_neg_integer()}
  def pop(server \\ __MODULE__),
    do: GenServer.call(server, :pop)

  @impl true
  def init(:ok), do: {:ok, %{queue: [], call_index: 0}}

  @impl true
  def handle_call({:load, queue}, _from, state),
    do: {:reply, :ok, %{state | queue: queue, call_index: 0}}

  @impl true
  def handle_call(:pop, _from, %{queue: [entry | rest]} = state) do
    idx = state.call_index
    {:reply, {:ok, entry, idx}, %{state | queue: rest, call_index: idx + 1}}
  end

  def handle_call(:pop, _from, %{queue: []} = state),
    do: {:reply, {:exhausted, state.call_index}, state}
end
