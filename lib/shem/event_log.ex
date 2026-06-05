defmodule Shem.EventLog do
  use GenServer

  alias Shem.EventLog.Session
  alias Shem.EventLog.Event

  # ── Client API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_session() :: {:ok, String.t()}
  def start_session, do: GenServer.call(__MODULE__, :start_session)

  @spec start_session(String.t()) :: {:ok, String.t()}
  def start_session(session_id), do: GenServer.call(__MODULE__, {:start_session, session_id})

  @spec end_session(String.t()) :: :ok | {:error, :session_not_found}
  def end_session(session_id), do: GenServer.call(__MODULE__, {:end_session, session_id})

  @spec list_sessions() :: {:ok, [Session.t()]}
  def list_sessions, do: GenServer.call(__MODULE__, :list_sessions)

  @spec stats() :: %{sessions: non_neg_integer(), total_events: non_neg_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @spec append(String.t(), atom(), map(), String.t() | nil) ::
          {:ok, Event.t()} | {:error, :session_not_found | :session_ended}
  def append(session_id, type, payload, parent_id \\ nil),
    do: GenServer.call(__MODULE__, {:append, session_id, type, payload, parent_id})

  @spec events(String.t()) :: {:ok, [Event.t()]} | {:error, :session_not_found | :session_ended}
  def events(session_id), do: GenServer.call(__MODULE__, {:events, session_id})

  @spec event(String.t(), String.t()) ::
          {:ok, Event.t()} | {:error, :session_not_found | :session_ended | :not_found}
  def event(session_id, event_id),
    do: GenServer.call(__MODULE__, {:event, session_id, event_id})

  @spec reconstruct(String.t(), (term(), Event.t() -> term()), term()) ::
          {:ok, term()} | {:error, :session_not_found | :session_ended}
  def reconstruct(session_id, reducer, initial),
    do: GenServer.call(__MODULE__, {:reconstruct, session_id, reducer, initial})

  @spec reconstruct_at(String.t(), String.t(), (term(), Event.t() -> term()), term()) ::
          {:ok, term()} | {:error, :session_not_found | :session_ended | :event_not_found}
  def reconstruct_at(session_id, event_id, reducer, initial),
    do: GenServer.call(__MODULE__, {:reconstruct_at, session_id, event_id, reducer, initial})

  # ── Server callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    store = Application.get_env(:shem, :event_log_store, Shem.EventLog.DETSStore)
    {:ok, %{sessions: %{}, store: store}}
  end

  @impl true
  def handle_call(:start_session, _from, state) do
    session = Session.new()
    {:ok, handle} = state.store.open(session.id, event_log_path())
    sessions = Map.put(state.sessions, session.id, {handle, session})
    {:reply, {:ok, session.id}, %{state | sessions: sessions}}
  end

  @impl true
  def handle_call({:start_session, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, _} ->
        {:reply, {:ok, session_id}, state}

      :error ->
        session = %Session{id: session_id, started_at: DateTime.utc_now()}
        {:ok, handle} = state.store.open(session_id, event_log_path())
        sessions = Map.put(state.sessions, session_id, {handle, session})
        {:reply, {:ok, session_id}, %{state | sessions: sessions}}
    end
  end

  @impl true
  def handle_call({:end_session, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, session}} ->
        if handle, do: state.store.close(handle)
        closed = Session.close(session)
        sessions = Map.put(state.sessions, session_id, {nil, closed})
        {:reply, :ok, %{state | sessions: sessions}}

      :error ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    sessions = state.sessions |> Map.values() |> Enum.map(fn {_h, s} -> s end)
    {:reply, {:ok, sessions}, state}
  end

  @impl true
  def handle_call({:append, session_id, type, payload, parent_id}, _from, state) do
    case get_active_handle(state, session_id) do
      {:ok, handle} ->
        event = Event.new(session_id, type, payload, parent_id)

        case state.store.append(handle, event) do
          :ok ->
            sessions =
              Map.update!(state.sessions, session_id, fn {h, s} -> {h, Session.increment(s)} end)

            {:reply, {:ok, event}, %{state | sessions: sessions}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:events, session_id}, _from, state) do
    case get_active_handle(state, session_id) do
      {:ok, handle} -> {:reply, state.store.read_all(handle), state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:event, session_id, event_id}, _from, state) do
    case get_active_handle(state, session_id) do
      {:ok, handle} -> {:reply, state.store.get(handle, event_id), state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:reconstruct, session_id, reducer, initial}, _from, state) do
    case get_active_handle(state, session_id) do
      {:ok, handle} ->
        with {:ok, events} <- state.store.read_all(handle) do
          {:reply, {:ok, Shem.EventLog.Replay.fold(events, initial, reducer)}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:reconstruct_at, session_id, event_id, reducer, initial}, _from, state) do
    case get_active_handle(state, session_id) do
      {:ok, handle} ->
        with {:ok, events} <- state.store.read_all(handle) do
          {:reply, Shem.EventLog.Replay.state_at(events, event_id, initial, reducer), state}
        end

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    total_events =
      state.sessions
      |> Map.values()
      |> Enum.map(fn {_h, s} -> s.event_count end)
      |> Enum.sum()

    {:reply, %{sessions: map_size(state.sessions), total_events: total_events}, state}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp get_active_handle(state, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, _session}} when handle != nil -> {:ok, handle}
      {:ok, {nil, _session}} -> {:error, :session_ended}
      :error -> {:error, :session_not_found}
    end
  end

  defp event_log_path do
    Application.get_env(
      :shem,
      :event_log_path,
      Path.join([System.user_home!(), ".config", "shem", "lab", "events"])
    )
  end
end
