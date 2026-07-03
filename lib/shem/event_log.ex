defmodule Shem.EventLog do
  use GenServer

  alias Shem.EventLog.{Chain, Event, Session}

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

  @doc """
  Mark a session ended (sets `ended_at`, so it no longer reads as active/LIVE)
  WITHOUT closing its store handle — so it stays readable. For static snapshots
  like forks that are finalized on creation, not running agents. Appends are
  still rejected (gated on `ended_at`).
  """
  @spec finalize(String.t()) :: :ok | {:error, :session_not_found}
  def finalize(session_id), do: GenServer.call(__MODULE__, {:finalize, session_id})

  @spec list_sessions() :: {:ok, [Session.t()]}
  def list_sessions, do: GenServer.call(__MODULE__, :list_sessions)

  @spec stats() :: %{sessions: non_neg_integer(), total_events: non_neg_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @spec append(String.t(), atom(), map(), String.t() | nil) ::
          {:ok, Event.t()} | {:error, :session_not_found | :session_ended}
  def append(session_id, type, payload, parent_id \\ nil) do
    meta = %{type: type, node: node()}

    :telemetry.span([:shem, :event_log, :append], meta, fn ->
      {GenServer.call(__MODULE__, {:append, session_id, type, payload, parent_id}), meta}
    end)
  end

  @spec events(String.t()) :: {:ok, [Event.t()]} | {:error, :session_not_found | :session_ended}
  def events(session_id), do: GenServer.call(__MODULE__, {:events, session_id})

  @spec scrub(String.t(), String.t()) ::
          :ok | {:error, :session_not_found | :session_ended | :event_not_found}
  def scrub(session_id, after_event_id),
    do: GenServer.call(__MODULE__, {:scrub, session_id, after_event_id})

  @spec event(String.t(), String.t()) ::
          {:ok, Event.t()} | {:error, :session_not_found | :session_ended | :not_found}
  def event(session_id, event_id),
    do: GenServer.call(__MODULE__, {:event, session_id, event_id})

  @spec read_session_events(String.t()) :: {:ok, [Event.t()]} | {:error, :not_found}
  def read_session_events(session_id),
    do: GenServer.call(__MODULE__, {:read_session_events, session_id})

  @spec verify_chain(String.t()) ::
          {:ok, :verified | :legacy, non_neg_integer()}
          | {:error, {:broken_at, String.t()} | :not_found}
  def verify_chain(session_id) do
    case read_session_events(session_id) do
      {:ok, events} -> Chain.verify(events, session_id)
      {:error, _} -> {:error, :not_found}
    end
  end

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
    store = select_store()
    {:ok, %{sessions: %{}, store: store}}
  end

  defp select_store do
    explicit = Application.get_env(:shem, :event_log_store)
    force_mnesia = Application.get_env(:shem, :force_mnesia, false)

    cond do
      explicit != nil -> explicit
      force_mnesia || Node.list() != [] -> Shem.EventLog.MnesiaStore
      true -> Shem.EventLog.DETSStore
    end
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
        {:ok, handle} = state.store.open(session_id, event_log_path())

        {last_hash, count} =
          case state.store.read_all(handle) do
            {:ok, [_ | _] = events} -> {List.last(events).hash, length(events)}
            _ -> {nil, 0}
          end

        session = %Session{
          id: session_id,
          started_at: DateTime.utc_now(),
          last_hash: last_hash,
          # continue the append index after existing events so a resumed session
          # doesn't restart seq at 0 (which would collide on read-ordering).
          event_count: count
        }

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
  def handle_call({:finalize, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, session}} ->
        # keep the handle open (stays readable across all stores); ended_at marks
        # it non-active and the append guard rejects further writes.
        closed = Session.close(session)
        sessions = Map.put(state.sessions, session_id, {handle, closed})
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
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, session}} when handle != nil ->
        # A finalized session keeps its handle open but rejects appends.
        if is_nil(session.ended_at) do
          event = Event.new(session_id, type, payload, parent_id)
          prev = session.last_hash || Chain.genesis(session_id)
          # seq = this event's 0-based append index (monotonic per session) so the
          # store can read events back in append order, not timestamp order.
          event = %{event | hash: Chain.next(prev, event), seq: session.event_count}

          case state.store.append(handle, event) do
            :ok ->
              updated = %{Session.increment(session) | last_hash: event.hash}
              sessions = Map.put(state.sessions, session_id, {handle, updated})
              {:reply, {:ok, event}, %{state | sessions: sessions}}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          {:reply, {:error, :session_ended}, state}
        end

      {:ok, {nil, _session}} ->
        {:reply, {:error, :session_ended}, state}

      :error ->
        {:reply, {:error, :session_not_found}, state}
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
  def handle_call({:read_session_events, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, _}} when handle != nil ->
        {:reply, state.store.read_all(handle), state}

      _ ->
        # Session not in active state — try current store first (handles Mnesia cross-node reads),
        # then fall back to DETS file for historical sessions from before cluster join.
        case try_store_read(state.store, session_id) do
          {:ok, [_ | _]} = result ->
            {:reply, result, state}

          _ ->
            {:reply, read_dets_file(session_id), state}
        end
    end
  end

  @impl true
  def handle_call({:scrub, session_id, after_event_id}, _from, state) do
    case get_active_handle(state, session_id) do
      {:ok, handle} -> {:reply, state.store.scrub(handle, after_event_id), state}
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

  # Try reading from the current store using session_id as handle.
  # MnesiaStore accepts session_id directly; DETSStore needs a table handle (will return error).
  defp try_store_read(store, session_id) do
    try do
      store.read_all(session_id)
    catch
      _, _ -> {:error, :not_found}
    end
  end

  defp read_dets_file(session_id) do
    path = event_log_path()
    dets_path = Path.join(path, "#{session_id}.dets")

    if File.exists?(dets_path) do
      table = :"shem_history_#{session_id}_#{:erlang.unique_integer([:positive])}"
      file_charlist = String.to_charlist(dets_path)

      case :dets.open_file(table, file: file_charlist, type: :set) do
        {:ok, tab} ->
          # Sort by :seq (the hash chain's append order), matching
          # DETSStore.read_all — timestamp alone reorders same-microsecond
          # events and breaks chain verification. Legacy events (no :seq) fall
          # back to timestamp.
          events =
            :dets.foldl(fn {_id, event}, acc -> [event | acc] end, [], tab)
            |> Enum.sort_by(fn e -> {Map.get(e, :seq) || -1, DateTime.to_unix(e.timestamp, :microsecond)} end)

          :dets.close(tab)
          {:ok, events}

        {:error, _} ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end
end
