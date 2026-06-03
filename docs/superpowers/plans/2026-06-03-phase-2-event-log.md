# Phase 2: Event Log Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the append-only Event Log Engine — durable per-session event storage with causal linking, a swappable storage abstraction, fold-based state reconstruction, and live stats in the TUI dashboard.

**Architecture:** Six modules behind a single GenServer entry point. `Shem.EventLog` (GenServer) owns all sessions and serializes writes. `DETSStore` persists to `~/.config/shem/lab/events/<session_id>.dets`, one file per session. A `Store` behaviour makes the backend swappable — tests inject `FakeStore` (ETS-backed, no disk I/O). `Replay` is a pure module of fold functions. The TUI dashboard polls `EventLog.stats/0` via a Ratatouille subscription tick every 500 ms.

**Tech Stack:** Elixir 1.19.5, OTP 29, DETS (stdlib), ETS (stdlib), ExUnit, StreamData (future property tests)

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `lib/shem/event_log/event.ex` | Create | Event struct + ID generation |
| `lib/shem/event_log/session.ex` | Create | Session struct + ID generation |
| `lib/shem/event_log/store.ex` | Create | Store behaviour (swappable backend interface) |
| `lib/shem/event_log/fake_store.ex` | Create | ETS-backed Store for tests |
| `lib/shem/event_log/dets_store.ex` | Create | DETS implementation of Store |
| `lib/shem/event_log/replay.ex` | Create | Pure fold/state_at/causal_chain functions |
| `lib/shem/event_log.ex` | Create | GenServer — public API + session lifecycle |
| `lib/shem/application.ex` | Modify | Add `Shem.EventLog` to supervision tree |
| `config/test.exs` | Modify | Inject FakeStore for all tests |
| `lib/shem/tui/app.ex` | Modify | Add `subscribe/1` + tick handler + `event_log_stats` model field |
| `lib/shem/tui/views/dashboard.ex` | Modify | Replace hardcoded lab stats with live model data |
| `test/shem/event_log/event_test.exs` | Create | Event unit tests |
| `test/shem/event_log/session_test.exs` | Create | Session unit tests |
| `test/shem/event_log/fake_store_test.exs` | Create | FakeStore contract tests |
| `test/shem/event_log/dets_store_test.exs` | Create | DETSStore contract tests |
| `test/shem/event_log/replay_test.exs` | Create | Replay pure function tests |
| `test/shem/event_log_test.exs` | Create | EventLog GenServer integration tests |
| `test/shem/tui/app_test.exs` | Modify | Add tick/stats assertions |
| `test/shem/tui/views/dashboard_test.exs` | Modify | Update base_model, add stats display test |

---

### Task 1: Event Struct

**Files:**
- Create: `lib/shem/event_log/event.ex`
- Create: `test/shem/event_log/event_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/shem/event_log/event_test.exs`:

```elixir
defmodule Shem.EventLog.EventTest do
  use ExUnit.Case, async: true

  alias Shem.EventLog.Event

  test "new/3 creates an event with generated id, timestamp, and nil parent_id" do
    event = Event.new("ses_abc123", :state_changed, %{key: "value"})
    assert String.starts_with?(event.id, "evt_")
    assert byte_size(event.id) == 20
    assert event.session_id == "ses_abc123"
    assert event.type == :state_changed
    assert event.payload == %{key: "value"}
    assert event.parent_id == nil
    assert %DateTime{} = event.timestamp
  end

  test "new/4 sets parent_id when provided" do
    event = Event.new("ses_abc123", :tool_invoked, %{}, "evt_parent00000000")
    assert event.parent_id == "evt_parent00000000"
  end

  test "generate_id/0 returns unique ids across 100 calls" do
    ids = for _ <- 1..100, do: Event.generate_id()
    assert length(Enum.uniq(ids)) == 100
  end

  test "generate_id/0 returns ids prefixed with 'evt_'" do
    assert String.starts_with?(Event.generate_id(), "evt_")
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log/event_test.exs
```

Expected: compilation error — `Shem.EventLog.Event` does not exist.

- [ ] **Step 3: Implement Event**

Create `lib/shem/event_log/event.ex`:

```elixir
defmodule Shem.EventLog.Event do
  @enforce_keys [:id, :session_id, :type, :payload, :timestamp]
  defstruct [:id, :session_id, :parent_id, :type, :payload, :timestamp]

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          parent_id: String.t() | nil,
          type: atom(),
          payload: map(),
          timestamp: DateTime.t()
        }

  @spec new(String.t(), atom(), map(), String.t() | nil) :: t()
  def new(session_id, type, payload, parent_id \\ nil) do
    %__MODULE__{
      id: generate_id(),
      session_id: session_id,
      parent_id: parent_id,
      type: type,
      payload: payload,
      timestamp: DateTime.utc_now()
    }
  end

  @spec generate_id() :: String.t()
  def generate_id, do: "evt_" <> Base.encode16(:crypto.strong_rand_bytes(8))
end
```

- [ ] **Step 4: Run tests**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log/event_test.exs
```

Expected: `4 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
cd /home/philip/Downloads/_project/shem
git add lib/shem/event_log/event.ex test/shem/event_log/event_test.exs
git commit -m "feat: EventLog.Event struct with ID generation"
```

---

### Task 2: Session Struct

**Files:**
- Create: `lib/shem/event_log/session.ex`
- Create: `test/shem/event_log/session_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/shem/event_log/session_test.exs`:

```elixir
defmodule Shem.EventLog.SessionTest do
  use ExUnit.Case, async: true

  alias Shem.EventLog.Session

  test "new/0 creates a session with generated id, started_at, zero event_count" do
    session = Session.new()
    assert String.starts_with?(session.id, "ses_")
    assert byte_size(session.id) == 20
    assert %DateTime{} = session.started_at
    assert session.ended_at == nil
    assert session.event_count == 0
  end

  test "generate_id/0 returns unique ids across 100 calls" do
    ids = for _ <- 1..100, do: Session.generate_id()
    assert length(Enum.uniq(ids)) == 100
  end

  test "increment/1 increases event_count by 1 each call" do
    s = Session.new()
    assert Session.increment(s).event_count == 1
    assert s |> Session.increment() |> Session.increment() |> Map.get(:event_count) == 2
  end

  test "close/1 sets ended_at to a DateTime" do
    session = Session.new()
    closed = Session.close(session)
    assert %DateTime{} = closed.ended_at
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log/session_test.exs
```

Expected: compilation error — `Shem.EventLog.Session` does not exist.

- [ ] **Step 3: Implement Session**

Create `lib/shem/event_log/session.ex`:

```elixir
defmodule Shem.EventLog.Session do
  @enforce_keys [:id, :started_at]
  defstruct [:id, :started_at, :ended_at, event_count: 0]

  @type t :: %__MODULE__{
          id: String.t(),
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          event_count: non_neg_integer()
        }

  @spec new() :: t()
  def new do
    %__MODULE__{
      id: generate_id(),
      started_at: DateTime.utc_now()
    }
  end

  @spec generate_id() :: String.t()
  def generate_id, do: "ses_" <> Base.encode16(:crypto.strong_rand_bytes(8))

  @spec increment(t()) :: t()
  def increment(%__MODULE__{} = session),
    do: %{session | event_count: session.event_count + 1}

  @spec close(t()) :: t()
  def close(%__MODULE__{} = session),
    do: %{session | ended_at: DateTime.utc_now()}
end
```

- [ ] **Step 4: Run tests**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log/session_test.exs
```

Expected: `4 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
cd /home/philip/Downloads/_project/shem
git add lib/shem/event_log/session.ex test/shem/event_log/session_test.exs
git commit -m "feat: EventLog.Session struct with ID generation"
```

---

### Task 3: Store Behaviour + FakeStore

**Files:**
- Create: `lib/shem/event_log/store.ex`
- Create: `lib/shem/event_log/fake_store.ex`
- Create: `test/shem/event_log/fake_store_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/shem/event_log/fake_store_test.exs`:

```elixir
defmodule Shem.EventLog.FakeStoreTest do
  use ExUnit.Case, async: true

  alias Shem.EventLog.{FakeStore, Event}

  setup do
    {:ok, handle} = FakeStore.open("ses_test", "/ignored/path")
    on_exit(fn -> catch_exit(FakeStore.close(handle)) end)
    %{handle: handle}
  end

  test "open/2 returns an ETS table reference", %{handle: handle} do
    assert is_atom(handle)
    assert :ets.info(handle) != :undefined
  end

  test "append/2 stores the event and read_all/1 returns it", %{handle: handle} do
    event = Event.new("ses_test", :state_changed, %{val: 1})
    assert :ok = FakeStore.append(handle, event)
    assert {:ok, [^event]} = FakeStore.read_all(handle)
  end

  test "read_all/1 returns events sorted by timestamp", %{handle: handle} do
    e1 = Event.new("ses_test", :first, %{})
    Process.sleep(2)
    e2 = Event.new("ses_test", :second, %{})
    FakeStore.append(handle, e2)
    FakeStore.append(handle, e1)
    {:ok, events} = FakeStore.read_all(handle)
    assert Enum.map(events, & &1.type) == [:first, :second]
  end

  test "get/2 retrieves a stored event by id", %{handle: handle} do
    event = Event.new("ses_test", :tool_invoked, %{tool: "bash"})
    FakeStore.append(handle, event)
    assert {:ok, ^event} = FakeStore.get(handle, event.id)
  end

  test "get/2 returns :not_found for an unknown id", %{handle: handle} do
    assert {:error, :not_found} = FakeStore.get(handle, "evt_0000000000000000")
  end

  test "close/1 deletes the ETS table", %{handle: handle} do
    assert :ok = FakeStore.close(handle)
    assert :ets.info(handle) == :undefined
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log/fake_store_test.exs
```

Expected: compilation error — modules do not exist.

- [ ] **Step 3: Create Store behaviour**

Create `lib/shem/event_log/store.ex`:

```elixir
defmodule Shem.EventLog.Store do
  alias Shem.EventLog.Event

  @callback open(session_id :: String.t(), path :: Path.t()) ::
              {:ok, handle :: term()} | {:error, term()}

  @callback append(handle :: term(), event :: Event.t()) ::
              :ok | {:error, term()}

  @callback read_all(handle :: term()) ::
              {:ok, [Event.t()]} | {:error, term()}

  @callback get(handle :: term(), event_id :: String.t()) ::
              {:ok, Event.t()} | {:error, :not_found}

  @callback close(handle :: term()) :: :ok
end
```

- [ ] **Step 4: Create FakeStore**

Create `lib/shem/event_log/fake_store.ex`:

```elixir
defmodule Shem.EventLog.FakeStore do
  @behaviour Shem.EventLog.Store

  @impl true
  def open(session_id, _path) do
    table =
      :ets.new(
        :"fake_store_#{session_id}_#{:erlang.unique_integer([:positive])}",
        [:set, :public]
      )
    {:ok, table}
  end

  @impl true
  def append(table, event) do
    :ets.insert(table, {event.id, event})
    :ok
  end

  @impl true
  def read_all(table) do
    events =
      table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, event} -> event end)
      |> Enum.sort_by(& &1.timestamp, DateTime)
    {:ok, events}
  end

  @impl true
  def get(table, event_id) do
    case :ets.lookup(table, event_id) do
      [{^event_id, event}] -> {:ok, event}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def close(table) do
    :ets.delete(table)
    :ok
  end
end
```

- [ ] **Step 5: Run tests**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log/fake_store_test.exs
```

Expected: `6 tests, 0 failures`

- [ ] **Step 6: Commit**

```bash
cd /home/philip/Downloads/_project/shem
git add lib/shem/event_log/store.ex lib/shem/event_log/fake_store.ex test/shem/event_log/fake_store_test.exs
git commit -m "feat: Store behaviour and FakeStore (ETS-backed) implementation"
```

---

### Task 4: DETSStore

**Files:**
- Create: `lib/shem/event_log/dets_store.ex`
- Create: `test/shem/event_log/dets_store_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/shem/event_log/dets_store_test.exs`:

```elixir
defmodule Shem.EventLog.DETSStoreTest do
  use ExUnit.Case, async: false

  alias Shem.EventLog.{DETSStore, Event}

  setup do
    dir = Path.join(System.tmp_dir!(), "shem_dets_#{:erlang.unique_integer([:positive])}")
    session_id = "ses_#{:erlang.unique_integer([:positive])}"
    {:ok, handle} = DETSStore.open(session_id, dir)

    on_exit(fn ->
      catch_exit(DETSStore.close(handle))
      File.rm_rf!(dir)
    end)

    %{handle: handle, dir: dir, session_id: session_id}
  end

  test "open/2 creates the directory if it does not exist" do
    dir = Path.join(System.tmp_dir!(), "shem_new_#{:erlang.unique_integer([:positive])}")
    refute File.exists?(dir)
    {:ok, handle} = DETSStore.open("ses_new", dir)
    assert File.exists?(dir)
    DETSStore.close(handle)
    File.rm_rf!(dir)
  end

  test "open/2 creates a .dets file in the given directory", %{dir: dir, session_id: sid} do
    assert File.exists?(Path.join(dir, "#{sid}.dets"))
  end

  test "append/2 stores an event and read_all/1 returns it", %{handle: handle} do
    event = Event.new("ses_test", :state_changed, %{x: 1})
    assert :ok = DETSStore.append(handle, event)
    assert {:ok, [^event]} = DETSStore.read_all(handle)
  end

  test "read_all/1 returns multiple events sorted by timestamp", %{handle: handle} do
    e1 = Event.new("ses_test", :first, %{})
    Process.sleep(2)
    e2 = Event.new("ses_test", :second, %{})
    DETSStore.append(handle, e2)
    DETSStore.append(handle, e1)
    {:ok, events} = DETSStore.read_all(handle)
    assert Enum.map(events, & &1.type) == [:first, :second]
  end

  test "get/2 retrieves an event by id", %{handle: handle} do
    event = Event.new("ses_test", :tool_invoked, %{tool: "bash"})
    DETSStore.append(handle, event)
    assert {:ok, ^event} = DETSStore.get(handle, event.id)
  end

  test "get/2 returns :not_found for an unknown id", %{handle: handle} do
    assert {:error, :not_found} = DETSStore.get(handle, "evt_0000000000000000")
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log/dets_store_test.exs
```

Expected: compilation error — `Shem.EventLog.DETSStore` does not exist.

- [ ] **Step 3: Implement DETSStore**

Create `lib/shem/event_log/dets_store.ex`:

```elixir
defmodule Shem.EventLog.DETSStore do
  @behaviour Shem.EventLog.Store

  @impl true
  def open(session_id, path) do
    File.mkdir_p!(path)
    file = Path.join(path, "#{session_id}.dets") |> String.to_charlist()
    table_name = :"shem_events_#{session_id}"

    case :dets.open_file(table_name, file: file, type: :set) do
      {:ok, table} -> {:ok, table}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def append(table, event) do
    case :dets.insert(table, {event.id, event}) do
      :ok -> :ok
      error -> error
    end
  end

  @impl true
  def read_all(table) do
    events =
      :dets.foldl(fn {_id, event}, acc -> [event | acc] end, [], table)
      |> Enum.sort_by(& &1.timestamp, DateTime)
    {:ok, events}
  end

  @impl true
  def get(table, event_id) do
    case :dets.lookup(table, event_id) do
      [{^event_id, event}] -> {:ok, event}
      [] -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def close(table) do
    :dets.close(table)
    :ok
  end
end
```

- [ ] **Step 4: Run tests**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log/dets_store_test.exs
```

Expected: `6 tests, 0 failures`

- [ ] **Step 5: Run the full suite to confirm nothing broke**

```bash
cd /home/philip/Downloads/_project/shem && mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd /home/philip/Downloads/_project/shem
git add lib/shem/event_log/dets_store.ex test/shem/event_log/dets_store_test.exs
git commit -m "feat: DETSStore — DETS-backed event store with temp dir for tests"
```

---

### Task 5: EventLog GenServer — Session Lifecycle

**Files:**
- Create: `lib/shem/event_log.ex`
- Modify: `config/test.exs`
- Modify: `lib/shem/application.ex`
- Create: `test/shem/event_log_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/shem/event_log_test.exs`:

```elixir
defmodule Shem.EventLogTest do
  use ExUnit.Case, async: false

  alias Shem.EventLog

  describe "start_session/0" do
    test "returns {:ok, session_id} where session_id starts with 'ses_'" do
      {:ok, session_id} = EventLog.start_session()
      assert String.starts_with?(session_id, "ses_")
    end

    test "each call returns a unique session_id" do
      {:ok, id1} = EventLog.start_session()
      {:ok, id2} = EventLog.start_session()
      assert id1 != id2
    end
  end

  describe "end_session/1" do
    test "returns :ok for an active session" do
      {:ok, id} = EventLog.start_session()
      assert :ok = EventLog.end_session(id)
    end

    test "returns {:error, :session_not_found} for unknown session_id" do
      assert {:error, :session_not_found} = EventLog.end_session("ses_doesnotexist00")
    end
  end

  describe "list_sessions/0" do
    test "includes the session after start_session" do
      {:ok, id} = EventLog.start_session()
      {:ok, sessions} = EventLog.list_sessions()
      assert Enum.any?(sessions, &(&1.id == id))
    end
  end

  describe "stats/0" do
    test "returns a map with :sessions and :total_events integer keys" do
      stats = EventLog.stats()
      assert is_integer(stats.sessions)
      assert is_integer(stats.total_events)
    end

    test ":sessions count increases after start_session" do
      before = EventLog.stats().sessions
      {:ok, _id} = EventLog.start_session()
      after_ = EventLog.stats().sessions
      assert after_ > before
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log_test.exs
```

Expected: compilation error — `Shem.EventLog` does not exist.

- [ ] **Step 3: Add FakeStore config to test env**

Open `config/test.exs`. Add the event_log_store line so the file contains:

```elixir
import Config

config :shem, start_tui: false
config :shem, event_log_store: Shem.EventLog.FakeStore
```

- [ ] **Step 4: Create the EventLog GenServer**

Create `lib/shem/event_log.ex`:

```elixir
defmodule Shem.EventLog do
  use GenServer

  alias Shem.EventLog.{Event, Session}

  # ── Client API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_session() :: {:ok, String.t()}
  def start_session, do: GenServer.call(__MODULE__, :start_session)

  @spec end_session(String.t()) :: :ok | {:error, :session_not_found}
  def end_session(session_id), do: GenServer.call(__MODULE__, {:end_session, session_id})

  @spec list_sessions() :: {:ok, [Session.t()]}
  def list_sessions, do: GenServer.call(__MODULE__, :list_sessions)

  @spec stats() :: %{sessions: non_neg_integer(), total_events: non_neg_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

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
  def handle_call(:stats, _from, state) do
    total_events =
      state.sessions
      |> Map.values()
      |> Enum.map(fn {_h, s} -> s.event_count end)
      |> Enum.sum()

    {:reply, %{sessions: map_size(state.sessions), total_events: total_events}, state}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp event_log_path do
    Application.get_env(
      :shem,
      :event_log_path,
      Path.join([System.user_home!(), ".config", "shem", "lab", "events"])
    )
  end
end
```

- [ ] **Step 5: Add EventLog to the supervision tree**

Open `lib/shem/application.ex`. Add `Shem.EventLog` between `Shem.AgentSupervisor` and `tui_children()`:

```elixir
defmodule Shem.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Shem.Registry},
        Shem.AgentSupervisor,
        Shem.EventLog
      ] ++ tui_children()

    opts = [strategy: :one_for_one, name: Shem.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp tui_children do
    if Application.get_env(:shem, :start_tui, true) do
      [Shem.TUI.RuntimeSupervisor]
    else
      []
    end
  end
end
```

- [ ] **Step 6: Run the session tests**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log_test.exs
```

Expected: `6 tests, 0 failures`

- [ ] **Step 7: Run the full suite**

```bash
cd /home/philip/Downloads/_project/shem && mix test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
cd /home/philip/Downloads/_project/shem
git add lib/shem/event_log.ex lib/shem/application.ex config/test.exs test/shem/event_log_test.exs
git commit -m "feat: EventLog GenServer with session lifecycle, wired into supervision tree"
```

---

### Task 6: EventLog GenServer — Write API (append)

**Files:**
- Modify: `lib/shem/event_log.ex`
- Modify: `test/shem/event_log_test.exs`

- [ ] **Step 1: Write the failing tests**

Add these tests to the bottom of `test/shem/event_log_test.exs`:

```elixir
  describe "append/3" do
    test "returns {:ok, %Event{}} with the correct fields" do
      {:ok, sid} = EventLog.start_session()
      {:ok, event} = EventLog.append(sid, :state_changed, %{x: 1})
      assert String.starts_with?(event.id, "evt_")
      assert event.session_id == sid
      assert event.type == :state_changed
      assert event.payload == %{x: 1}
      assert event.parent_id == nil
    end

    test "append/4 sets parent_id when provided" do
      {:ok, sid} = EventLog.start_session()
      {:ok, e1} = EventLog.append(sid, :first, %{})
      {:ok, e2} = EventLog.append(sid, :second, %{}, e1.id)
      assert e2.parent_id == e1.id
    end

    test "increments the session event_count" do
      {:ok, sid} = EventLog.start_session()
      EventLog.append(sid, :a, %{})
      EventLog.append(sid, :b, %{})
      {:ok, sessions} = EventLog.list_sessions()
      session = Enum.find(sessions, &(&1.id == sid))
      assert session.event_count == 2
    end

    test "returns {:error, :session_not_found} for unknown session" do
      assert {:error, :session_not_found} =
               EventLog.append("ses_doesnotexist00", :type, %{})
    end

    test "returns {:error, :session_ended} for a closed session" do
      {:ok, sid} = EventLog.start_session()
      EventLog.end_session(sid)
      assert {:error, :session_ended} = EventLog.append(sid, :type, %{})
    end
  end
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log_test.exs
```

Expected: failures — `EventLog.append/3` is undefined.

- [ ] **Step 3: Add append to EventLog**

Add the client function and handle_call to `lib/shem/event_log.ex`.

Add after the `stats/0` client function:

```elixir
  @spec append(String.t(), atom(), map(), String.t() | nil) ::
          {:ok, Event.t()} | {:error, :session_not_found | :session_ended}
  def append(session_id, type, payload, parent_id \\ nil),
    do: GenServer.call(__MODULE__, {:append, session_id, type, payload, parent_id})
```

Add after the `handle_call(:stats, ...)` callback:

```elixir
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
```

Add the private helper at the bottom of the module (before the closing `end`):

```elixir
  defp get_active_handle(state, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, _session}} when handle != nil -> {:ok, handle}
      {:ok, {nil, _session}} -> {:error, :session_ended}
      :error -> {:error, :session_not_found}
    end
  end
```

- [ ] **Step 4: Run tests**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log_test.exs
```

Expected: all tests pass (11 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
cd /home/philip/Downloads/_project/shem
git add lib/shem/event_log.ex test/shem/event_log_test.exs
git commit -m "feat: EventLog append/3,4 with session event_count tracking"
```

---

### Task 7: EventLog GenServer — Read + Replay API

**Files:**
- Modify: `lib/shem/event_log.ex`
- Modify: `test/shem/event_log_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to the bottom of `test/shem/event_log_test.exs`:

```elixir
  describe "events/1" do
    test "returns all appended events in timestamp order" do
      {:ok, sid} = EventLog.start_session()
      {:ok, e1} = EventLog.append(sid, :first, %{})
      {:ok, e2} = EventLog.append(sid, :second, %{})
      {:ok, events} = EventLog.events(sid)
      assert Enum.map(events, & &1.id) == [e1.id, e2.id]
    end

    test "returns {:error, :session_not_found} for unknown session" do
      assert {:error, :session_not_found} = EventLog.events("ses_doesnotexist00")
    end
  end

  describe "event/2" do
    test "retrieves a specific event by id" do
      {:ok, sid} = EventLog.start_session()
      {:ok, e} = EventLog.append(sid, :state_changed, %{val: 42})
      assert {:ok, ^e} = EventLog.event(sid, e.id)
    end

    test "returns {:error, :not_found} for unknown event_id" do
      {:ok, sid} = EventLog.start_session()
      assert {:error, :not_found} = EventLog.event(sid, "evt_0000000000000000")
    end
  end

  describe "reconstruct/3" do
    test "folds all events to produce final state" do
      {:ok, sid} = EventLog.start_session()
      EventLog.append(sid, :inc, %{})
      EventLog.append(sid, :inc, %{})
      EventLog.append(sid, :inc, %{})
      reducer = fn count, _event -> count + 1 end
      assert {:ok, 3} = EventLog.reconstruct(sid, reducer, 0)
    end

    test "returns {:ok, initial} for a session with no events" do
      {:ok, sid} = EventLog.start_session()
      assert {:ok, :empty} = EventLog.reconstruct(sid, fn s, _ -> s end, :empty)
    end
  end

  describe "reconstruct_at/4" do
    test "folds only up to and including the given event_id" do
      {:ok, sid} = EventLog.start_session()
      {:ok, e1} = EventLog.append(sid, :inc, %{})
      {:ok, e2} = EventLog.append(sid, :inc, %{})
      {:ok, _e3} = EventLog.append(sid, :inc, %{})
      reducer = fn count, _event -> count + 1 end
      assert {:ok, 2} = EventLog.reconstruct_at(sid, e2.id, reducer, 0)
    end

    test "returns {:error, :event_not_found} for unknown event_id" do
      {:ok, sid} = EventLog.start_session()
      EventLog.append(sid, :inc, %{})
      assert {:error, :event_not_found} =
               EventLog.reconstruct_at(sid, "evt_0000000000000000", fn s, _ -> s end, 0)
    end
  end
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log_test.exs
```

Expected: failures — `events/1`, `event/2`, `reconstruct/3`, `reconstruct_at/4` undefined.

- [ ] **Step 3: Add read + replay API to EventLog**

Add client functions after `append/4` in `lib/shem/event_log.ex`:

```elixir
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
```

Add handle_call callbacks after the `handle_call({:append, ...})` callback:

```elixir
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
```

- [ ] **Step 4: Run tests**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log_test.exs
```

Expected: compilation error — `Shem.EventLog.Replay` does not exist yet. That's fine — move to Task 8.

- [ ] **Step 5: Commit what we have**

```bash
cd /home/philip/Downloads/_project/shem
git add lib/shem/event_log.ex test/shem/event_log_test.exs
git commit -m "feat: EventLog read and replay API (Replay module stub pending)"
```

---

### Task 8: Replay Module

**Files:**
- Create: `lib/shem/event_log/replay.ex`
- Create: `test/shem/event_log/replay_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/shem/event_log/replay_test.exs`:

```elixir
defmodule Shem.EventLog.ReplayTest do
  use ExUnit.Case, async: true

  alias Shem.EventLog.{Replay, Event}

  defp make_event(id, type, parent_id \\ nil) do
    %Event{
      id: id,
      session_id: "ses_test00000000",
      parent_id: parent_id,
      type: type,
      payload: %{},
      timestamp: DateTime.utc_now()
    }
  end

  describe "fold/3" do
    test "reduces events with the given reducer" do
      events = [make_event("evt_1", :a), make_event("evt_2", :b), make_event("evt_3", :c)]
      reducer = fn count, _e -> count + 1 end
      assert Replay.fold(events, 0, reducer) == 3
    end

    test "returns initial state for an empty list" do
      assert Replay.fold([], :initial, fn s, _ -> s end) == :initial
    end

    test "passes each event to the reducer in order" do
      events = [make_event("evt_1", :x), make_event("evt_2", :y)]
      reducer = fn acc, event -> acc ++ [event.type] end
      assert Replay.fold(events, [], reducer) == [:x, :y]
    end
  end

  describe "state_at/4" do
    test "folds up to and including the target event" do
      events = [
        make_event("evt_1", :a),
        make_event("evt_2", :b),
        make_event("evt_3", :c)
      ]
      reducer = fn acc, e -> acc ++ [e.type] end
      assert {:ok, [:a, :b]} = Replay.state_at(events, "evt_2", [], reducer)
    end

    test "includes the target event in the fold" do
      events = [make_event("evt_1", :only)]
      reducer = fn acc, e -> acc ++ [e.type] end
      assert {:ok, [:only]} = Replay.state_at(events, "evt_1", [], reducer)
    end

    test "returns {:error, :event_not_found} for unknown event_id" do
      events = [make_event("evt_1", :a)]
      assert {:error, :event_not_found} =
               Replay.state_at(events, "evt_missing0000000", [], fn s, _ -> s end)
    end

    test "does not fold events after the target" do
      events = [
        make_event("evt_1", :a),
        make_event("evt_2", :b),
        make_event("evt_3", :c)
      ]
      reducer = fn acc, e -> acc ++ [e.type] end
      {:ok, result} = Replay.state_at(events, "evt_1", [], reducer)
      refute :b in result
      refute :c in result
    end
  end

  describe "causal_chain/2" do
    test "returns events from root to target in causal order" do
      events = [
        make_event("evt_1", :root, nil),
        make_event("evt_2", :child, "evt_1"),
        make_event("evt_3", :grandchild, "evt_2"),
        make_event("evt_4", :unrelated, nil)
      ]
      chain = Replay.causal_chain(events, "evt_3")
      assert Enum.map(chain, & &1.id) == ["evt_1", "evt_2", "evt_3"]
    end

    test "returns just the event when parent_id is nil" do
      events = [make_event("evt_1", :root, nil)]
      assert [%Event{id: "evt_1"}] = Replay.causal_chain(events, "evt_1")
    end

    test "returns empty list for an event_id not in the list" do
      events = [make_event("evt_1", :root, nil)]
      assert [] = Replay.causal_chain(events, "evt_missing0000000")
    end

    test "excludes unrelated events from the chain" do
      events = [
        make_event("evt_1", :root, nil),
        make_event("evt_2", :child, "evt_1"),
        make_event("evt_3", :sibling, "evt_1")
      ]
      chain = Replay.causal_chain(events, "evt_2")
      ids = Enum.map(chain, & &1.id)
      assert "evt_3" not in ids
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log/replay_test.exs
```

Expected: compilation error — `Shem.EventLog.Replay` does not exist.

- [ ] **Step 3: Implement Replay**

Create `lib/shem/event_log/replay.ex`:

```elixir
defmodule Shem.EventLog.Replay do
  alias Shem.EventLog.Event

  @spec fold([Event.t()], state, (state, Event.t() -> state)) :: state when state: term()
  def fold(events, initial, reducer) do
    Enum.reduce(events, initial, reducer)
  end

  @spec state_at([Event.t()], String.t(), state, (state, Event.t() -> state)) ::
          {:ok, state} | {:error, :event_not_found}
        when state: term()
  def state_at(events, event_id, initial, reducer) do
    case Enum.find(events, &(&1.id == event_id)) do
      nil ->
        {:error, :event_not_found}

      _ ->
        state =
          Enum.reduce_while(events, initial, fn event, acc ->
            new_acc = reducer.(acc, event)
            if event.id == event_id, do: {:halt, new_acc}, else: {:cont, new_acc}
          end)

        {:ok, state}
    end
  end

  @spec causal_chain([Event.t()], String.t()) :: [Event.t()]
  def causal_chain(events, event_id) do
    index = Map.new(events, &{&1.id, &1})
    build_chain(index, event_id, [])
  end

  defp build_chain(_index, nil, acc), do: acc

  defp build_chain(index, event_id, acc) do
    case Map.fetch(index, event_id) do
      {:ok, event} -> build_chain(index, event.parent_id, [event | acc])
      :error -> acc
    end
  end
end
```

- [ ] **Step 4: Run Replay tests**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/event_log/replay_test.exs
```

Expected: `10 tests, 0 failures`

- [ ] **Step 5: Run the full suite**

```bash
cd /home/philip/Downloads/_project/shem && mix test
```

Expected: all tests pass (the EventLog reconstruct tests from Task 7 now pass too).

- [ ] **Step 6: Commit**

```bash
cd /home/philip/Downloads/_project/shem
git add lib/shem/event_log/replay.ex test/shem/event_log/replay_test.exs
git commit -m "feat: Replay module — fold, state_at, causal_chain"
```

---

### Task 9: TUI Stats Integration

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Modify: `lib/shem/tui/views/dashboard.ex`
- Modify: `test/shem/tui/app_test.exs`
- Modify: `test/shem/tui/views/dashboard_test.exs`

The TUI App subscribes to a 500 ms interval tick. On each tick it fetches `EventLog.stats()` and stores the result in the model. The Dashboard renders live stats from the model.

- [ ] **Step 1: Update the App init model assertion in app_test.exs**

Open `test/shem/tui/app_test.exs`. Find the `init/1` test and add the `event_log_stats` assertion:

```elixir
  describe "init/1" do
    test "default model starts in dashboard mode, unpaused, with empty buffer" do
      model = App.init(%{})
      assert model.mode == :dashboard
      assert model.command_buffer == ""
      assert model.paused == false
      assert model.event_log_stats == %{sessions: 0, total_events: 0}
    end
  end
```

- [ ] **Step 2: Add a tick test to app_test.exs**

Add the following describe block at the bottom of `test/shem/tui/app_test.exs`:

```elixir
  describe "update/2 — tick subscription" do
    test ":tick message updates event_log_stats from EventLog.stats()" do
      model = App.init(%{})
      updated = App.update(model, :tick)
      assert is_integer(updated.event_log_stats.sessions)
      assert is_integer(updated.event_log_stats.total_events)
    end
  end
```

- [ ] **Step 3: Run to confirm the new init test fails**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/tui/app_test.exs
```

Expected: failure — `event_log_stats` not in model, `:tick` not handled.

- [ ] **Step 4: Update Shem.TUI.App**

Replace the full contents of `lib/shem/tui/app.ex`:

```elixir
defmodule Shem.TUI.App do
  @behaviour Ratatouille.App

  alias Shem.TUI.Views.{Dashboard, Interactive}
  alias Ratatouille.Runtime.Subscription

  @esc 27
  @backspace 127
  @space ?\s

  @impl true
  def init(_context) do
    %{
      mode: :dashboard,
      command_buffer: "",
      paused: false,
      event_log_stats: %{sessions: 0, total_events: 0}
    }
  end

  @impl true
  def subscribe(_model) do
    Subscription.interval(500, :tick)
  end

  @impl true
  def update(model, msg) do
    case msg do
      {:event, %{ch: ?d, key: 0}} when model.command_buffer == "" ->
        %{model | mode: :dashboard}

      {:event, %{ch: ?i, key: 0}} when model.command_buffer == "" ->
        %{model | mode: :interactive}

      {:event, %{key: @space}} when model.command_buffer == "" ->
        %{model | paused: !model.paused}

      {:event, %{key: @esc}} when model.command_buffer == "" ->
        %{model | paused: true}

      {:event, %{ch: ?/}} when model.command_buffer == "" ->
        %{model | command_buffer: "/"}

      {:event, %{key: @backspace}} ->
        buf = model.command_buffer
        %{model | command_buffer: if(buf == "", do: "", else: String.slice(buf, 0..-2//1))}

      {:event, %{ch: ch}} when model.command_buffer != "" and ch > 0 ->
        %{model | command_buffer: model.command_buffer <> <<ch::utf8>>}

      :tick ->
        %{model | event_log_stats: safe_stats()}

      _ ->
        model
    end
  end

  @impl true
  def render(model) do
    case model.mode do
      :dashboard -> Dashboard.render(model)
      :interactive -> Interactive.render(model)
    end
  end

  defp safe_stats do
    try do
      Shem.EventLog.stats()
    catch
      :exit, _ -> %{sessions: 0, total_events: 0}
    end
  end
end
```

- [ ] **Step 5: Run the App tests**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/tui/app_test.exs
```

Expected: all pass.

- [ ] **Step 6: Update base_model in dashboard_test.exs**

Open `test/shem/tui/views/dashboard_test.exs`. Update `base_model/0` to include `event_log_stats`:

```elixir
  defp base_model do
    %{mode: :dashboard, command_buffer: "", paused: false,
      event_log_stats: %{sessions: 0, total_events: 0}}
  end
```

Also add a new test for the stats display:

```elixir
  test "render/1 shows live session and event counts from event_log_stats" do
    model = %{base_model() | event_log_stats: %{sessions: 3, total_events: 17}}
    rendered = Dashboard.render(model) |> inspect()
    assert rendered =~ "3"
    assert rendered =~ "17"
  end
```

- [ ] **Step 7: Run to confirm the stats display test fails**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/tui/views/dashboard_test.exs
```

Expected: the new stats display test fails (dashboard still shows hardcoded "Active loops: 0").

- [ ] **Step 8: Update Dashboard.render/1**

Open `lib/shem/tui/views/dashboard.ex`. Replace the Lab Status panel body:

```elixir
        column(size: 4) do
          panel(title: "Lab Status", color: color(:magenta)) do
            label(content: "Tools graduated: 0", color: color(:white))
            label(
              content: "Sessions: #{model.event_log_stats.sessions}   Events: #{model.event_log_stats.total_events}",
              color: color(:white)
            )
            label(content: "")
            label(
              content: "Lab: idle",
              attributes: [attribute(:bold)],
              color: color(:magenta)
            )
          end
        end
```

- [ ] **Step 9: Run the dashboard tests**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/tui/views/dashboard_test.exs
```

Expected: `5 tests, 0 failures`

- [ ] **Step 10: Run the full suite**

```bash
cd /home/philip/Downloads/_project/shem && mix test
```

Expected: all tests pass.

- [ ] **Step 11: Commit**

```bash
cd /home/philip/Downloads/_project/shem
git add lib/shem/tui/app.ex lib/shem/tui/views/dashboard.ex \
        test/shem/tui/app_test.exs test/shem/tui/views/dashboard_test.exs
git commit -m "feat: TUI dashboard shows live EventLog stats via subscription tick"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Event struct with `parent_id`, `session_id`, `type`, `payload`, `timestamp` | Task 1 |
| Session struct with `id`, `started_at`, `ended_at`, `event_count` | Task 2 |
| `Store` behaviour for swappable backends | Task 3 |
| `DETSStore` — `~/.config/shem/lab/events/<session_id>.dets` | Task 4 |
| `Shem.EventLog` GenServer — `start_session`, `end_session`, `list_sessions`, `stats` | Task 5 |
| `append/3,4` with `parent_id` and `event_count` tracking | Task 6 |
| `events/1`, `event/2`, `reconstruct/3`, `reconstruct_at/4` | Task 7 |
| `Replay.fold/3`, `state_at/4`, `causal_chain/2` | Task 8 |
| Lab directory scaffolding (`~/.config/shem/lab/events/`) | Task 4 (DETSStore.open) |
| FakeStore for test injection | Task 3 |
| Dashboard TUI update: live session/event count | Task 9 |
| `event_log_store` configurable via `Application.get_env` | Task 5 (init) |

**Placeholder scan:** None found.

**Type consistency:** `Event.t()`, `Session.t()`, `store :: module()`, `handle :: term()` used consistently across all tasks. `get_active_handle/2` private helper used in Tasks 6 and 7 with the same signature.
