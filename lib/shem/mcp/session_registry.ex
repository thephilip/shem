defmodule Shem.MCP.SessionRegistry do
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def client_count(server \\ __MODULE__),
    do: GenServer.call(server, :client_count)

  def register_sse(session_id, pid, server \\ __MODULE__),
    do: GenServer.call(server, {:register, session_id, pid})

  def unregister_session(session_id, server \\ __MODULE__),
    do: GenServer.call(server, {:unregister, session_id})

  def send_to_session(session_id, data, server \\ __MODULE__),
    do: GenServer.call(server, {:send, session_id, data})

  @impl true
  def init(:ok), do: {:ok, %{sessions: %{}, monitors: %{}}}

  @impl true
  def handle_call({:register, session_id, pid}, _from, state) do
    ref = Process.monitor(pid)
    state = put_in(state, [:sessions, session_id], pid)
    state = put_in(state, [:monitors, ref], session_id)
    {:reply, :ok, state}
  end

  def handle_call({:unregister, session_id}, _from, state) do
    {:reply, :ok, drop_session(state, session_id)}
  end

  def handle_call({:send, session_id, data}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      pid ->
        send(pid, {:mcp_response, data})
        {:reply, :ok, state}
    end
  end

  def handle_call(:client_count, _from, state),
    do: {:reply, map_size(state.sessions), state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {session_id, monitors} ->
        {:noreply, drop_session(%{state | monitors: monitors}, session_id)}
    end
  end

  defp drop_session(state, session_id),
    do: update_in(state, [:sessions], &Map.delete(&1, session_id))
end
