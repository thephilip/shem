defmodule Shem.TUI.StreamSink do
  use GenServer

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id)
  end

  def take_tokens(pid) do
    GenServer.call(pid, :take_tokens)
  end

  def take_thinking(pid) do
    GenServer.call(pid, :take_thinking)
  end

  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  end

  def stop(nil), do: :ok

  @impl true
  def init(session_id) do
    :pg.join(:shem_streams, session_id, self())
    {:ok, %{session_id: session_id, buffer: [], thinking: nil}}
  end

  @impl true
  def handle_info({:stream_chunk, _session_id, token}, state) do
    {:noreply, %{state | buffer: [token | state.buffer]}}
  end

  def handle_info({:stream_thinking, _session_id, rc}, state) do
    {:noreply, %{state | thinking: rc}}
  end

  def handle_info({:stream_done, _session_id}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:take_tokens, _from, state) do
    {:reply, Enum.reverse(state.buffer), %{state | buffer: []}}
  end

  def handle_call(:take_thinking, _from, state) do
    {:reply, state.thinking, %{state | thinking: nil}}
  end
end
