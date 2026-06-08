defmodule Shem.TUI.StreamSink do
  use GenServer

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id)
  end

  def take_tokens(pid) do
    GenServer.call(pid, :take_tokens)
  end

  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  end

  def stop(nil), do: :ok

  @impl true
  def init(session_id) do
    Registry.register(Shem.StreamRegistry, session_id, nil)
    {:ok, %{session_id: session_id, buffer: []}}
  end

  @impl true
  def handle_info({:stream_chunk, _session_id, token}, state) do
    {:noreply, %{state | buffer: state.buffer ++ [token]}}
  end

  def handle_info({:stream_done, _session_id}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:take_tokens, _from, state) do
    {:reply, state.buffer, %{state | buffer: []}}
  end
end
