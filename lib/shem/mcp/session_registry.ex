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

  def set_mrtr(session_id, flag, server \\ __MODULE__),
    do: GenServer.call(server, {:set_mrtr, session_id, flag})

  def mrtr?(session_id, server \\ __MODULE__)
  def mrtr?(nil, _server), do: false
  def mrtr?(session_id, server), do: GenServer.call(server, {:mrtr?, session_id})

  @impl true
  def init(:ok), do: {:ok, %{sessions: %{}, monitors: %{}, mrtr: %{}}}

  @impl true
  def handle_call({:register, session_id, pid}, _from, state) do
    ref = Process.monitor(pid)
    state = put_in(state, [:sessions, session_id], pid)
    state = put_in(state, [:monitors, ref], session_id)
    {:reply, :ok, state}
  end

  def handle_call({:unregister, session_id}, _from, state) do
    ref = Enum.find_value(state.monitors, fn {r, sid} -> if sid == session_id, do: r end)
    if ref, do: Process.demonitor(ref, [:flush])
    monitors = if ref, do: Map.delete(state.monitors, ref), else: state.monitors
    sessions = Map.delete(state.sessions, session_id)
    {:reply, :ok, %{state | sessions: sessions, monitors: monitors, mrtr: Map.delete(state.mrtr, session_id)}}
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

  def handle_call({:set_mrtr, session_id, flag}, _from, state),
    do: {:reply, :ok, put_in(state, [:mrtr, session_id], flag)}

  def handle_call({:mrtr?, session_id}, _from, state),
    do: {:reply, Map.get(state.mrtr, session_id, false), state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {session_id, monitors} ->
        {:noreply, drop_session(%{state | monitors: monitors}, session_id)}
    end
  end

  defp drop_session(state, session_id) do
    state
    |> update_in([:sessions], &Map.delete(&1, session_id))
    |> update_in([:mrtr], &Map.delete(&1, session_id))
  end
end
