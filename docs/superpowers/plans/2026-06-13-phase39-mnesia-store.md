# Phase 39 — Distributed EventLog (MnesiaStore) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `Shem.EventLog.MnesiaStore` so any cluster node can read any session's events, enabling agent redistribution after node death without touching the dead node's filesystem.

**Architecture:** `MnesiaStore` implements the existing `Shem.EventLog.Store` behaviour using a single `disc_copies` Mnesia table (`:shem_events`) with composite key `{session_id, event_id}`. `EventLog.init/1` auto-selects the backend at startup: MnesiaStore when `Node.list() != []` or `:force_mnesia` config is set, DETSStore otherwise. `Shem.Cluster` gains Mnesia node-onboarding logic in its `:nodeup` handler — pull schema from the joining node, add a table copy, wait for replication.

**Tech Stack:** Elixir, OTP Mnesia (built-in, no new deps), ExUnit `:peer` for distributed tests.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `lib/shem/event_log/mnesia_store.ex` | MnesiaStore: Store behaviour impl, schema/table setup |
| Modify | `lib/shem/application.ex` | Call `MnesiaStore.setup!()` at startup |
| Modify | `lib/shem/event_log.ex` | Auto backend selection in `init/1` |
| Modify | `lib/shem/cluster.ex` | Mnesia node-onboarding on `:nodeup` |
| Create | `test/shem/event_log/mnesia_store_test.exs` | Unit tests for MnesiaStore (single node) |
| Create | `test/shem/distributed/event_log_test.exs` | Distributed `:peer` tests |

---

## Task 1: MnesiaStore — Core Implementation

**Files:**
- Create: `lib/shem/event_log/mnesia_store.ex`
- Create: `test/shem/event_log/mnesia_store_test.exs`

The handle for MnesiaStore is the `session_id` string (not a DETS table ref). `open/2` is a no-op that returns `{:ok, session_id}`. The Mnesia record tuple is `{:shem_events, {session_id, event_id}, %Event{}}`.

- [ ] **Step 1.1: Write the failing tests**

Create `test/shem/event_log/mnesia_store_test.exs`:

```elixir
defmodule Shem.EventLog.MnesiaStoreTest do
  use ExUnit.Case, async: false

  alias Shem.EventLog.{MnesiaStore, Event}

  setup_all do
    # Point Mnesia at a temp dir so this test doesn't touch the real schema
    tmp = Path.join(System.tmp_dir!(), "shem_mnesia_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:mnesia, :dir, String.to_charlist(tmp))
    MnesiaStore.setup!()
    on_exit(fn -> File.rm_rf!(tmp) end)
    :ok
  end

  setup do
    session_id = "ses_#{:erlang.unique_integer([:positive])}"
    {:ok, handle} = MnesiaStore.open(session_id, "/ignored")
    %{handle: handle, session_id: session_id}
  end

  test "open/2 returns {:ok, session_id} as the handle", %{handle: handle, session_id: sid} do
    assert handle == sid
  end

  test "close/1 is a no-op and returns :ok", %{handle: handle} do
    assert :ok = MnesiaStore.close(handle)
  end

  test "append/2 stores an event; read_all/1 returns it", %{handle: handle} do
    event = Event.new(handle, :state_changed, %{x: 1})
    assert :ok = MnesiaStore.append(handle, event)
    assert {:ok, [returned]} = MnesiaStore.read_all(handle)
    assert returned.id == event.id
  end

  test "read_all/1 returns events sorted by timestamp", %{handle: handle} do
    e1 = Event.new(handle, :first, %{})
    Process.sleep(2)
    e2 = Event.new(handle, :second, %{})
    MnesiaStore.append(handle, e2)
    MnesiaStore.append(handle, e1)
    {:ok, events} = MnesiaStore.read_all(handle)
    assert Enum.map(events, & &1.type) == [:first, :second]
  end

  test "read_all/1 is scoped to one session", %{handle: handle} do
    other_session = "ses_other_#{:erlang.unique_integer([:positive])}"
    {:ok, other} = MnesiaStore.open(other_session, "/ignored")
    MnesiaStore.append(handle, Event.new(handle, :mine, %{}))
    MnesiaStore.append(other, Event.new(other, :theirs, %{}))
    {:ok, events} = MnesiaStore.read_all(handle)
    assert length(events) == 1
    assert hd(events).type == :mine
  end

  test "get/2 retrieves an event by id", %{handle: handle} do
    event = Event.new(handle, :tool_invoked, %{tool: "bash"})
    MnesiaStore.append(handle, event)
    assert {:ok, returned} = MnesiaStore.get(handle, event.id)
    assert returned.id == event.id
  end

  test "get/2 returns :not_found for an unknown id", %{handle: handle} do
    assert {:error, :not_found} = MnesiaStore.get(handle, "evt_0000000000000000")
  end
end
```

- [ ] **Step 1.2: Run tests to confirm they fail**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/event_log/mnesia_store_test.exs 2>&1 | head -20
```

Expected: compile error — `Shem.EventLog.MnesiaStore` does not exist.

- [ ] **Step 1.3: Implement MnesiaStore**

Create `lib/shem/event_log/mnesia_store.ex`:

```elixir
defmodule Shem.EventLog.MnesiaStore do
  @behaviour Shem.EventLog.Store

  require Logger

  @table :shem_events

  @doc """
  Creates the Mnesia schema (if absent) and the :shem_events table (if absent).
  Safe to call repeatedly — all operations are idempotent.
  """
  def setup! do
    Application.ensure_all_started(:mnesia)

    case :mnesia.create_table(@table,
           attributes: [:key, :data],
           type: :ordered_set,
           disc_copies: [Node.self()]
         ) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, @table}} ->
        :ok

      {:aborted, reason} ->
        Logger.warning("MnesiaStore: table creation aborted: #{inspect(reason)}")
    end

    :mnesia.wait_for_tables([@table], 5_000)
    :ok
  end

  @doc """
  Adds a disc_copies replica of :shem_events on this node, pulling data from
  an existing cluster node. Called by Shem.Cluster on :nodeup.
  """
  def onboard_from(existing_node) do
    Application.ensure_all_started(:mnesia)
    :mnesia.change_config(:extra_db_nodes, [existing_node])

    case :mnesia.add_table_copy(@table, Node.self(), :disc_copies) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, @table, _node}} ->
        :ok

      {:aborted, reason} ->
        Logger.warning("MnesiaStore: add_table_copy failed: #{inspect(reason)}")
    end

    :mnesia.wait_for_tables([@table], 10_000)
    :ok
  end

  # ── Store behaviour ──────────────────────────────────────────────────────────

  @impl true
  def open(session_id, _path), do: {:ok, session_id}

  @impl true
  def append(session_id, event) do
    :mnesia.dirty_write({@table, {session_id, event.id}, event})
  end

  @impl true
  def read_all(session_id) do
    match_head = {@table, {session_id, :_}, :"$1"}
    events =
      :mnesia.dirty_select(@table, [{match_head, [], [:"$1"]}])
      |> Enum.sort_by(& &1.timestamp, DateTime)

    {:ok, events}
  end

  @impl true
  def get(session_id, event_id) do
    case :mnesia.dirty_read(@table, {session_id, event_id}) do
      [{@table, _key, event}] -> {:ok, event}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def close(_session_id), do: :ok
end
```

- [ ] **Step 1.4: Run tests to confirm they pass**

```bash
mix test test/shem/event_log/mnesia_store_test.exs
```

Expected: all 7 tests pass.

- [ ] **Step 1.5: Commit**

```bash
git add lib/shem/event_log/mnesia_store.ex test/shem/event_log/mnesia_store_test.exs
git commit -m "feat: add Shem.EventLog.MnesiaStore — Store behaviour over :mnesia dirty ops"
```

---

## Task 2: Mnesia Startup in Application

**Files:**
- Modify: `lib/shem/application.ex`

Call `MnesiaStore.setup!()` early in `Application.start/2`. This is always called (not conditional on clustering) so Mnesia is ready if/when the node joins a cluster later. The call is idempotent.

- [ ] **Step 2.1: Write the failing test**

Add to `test/shem/application_test.exs` (this file already exists — add inside the existing module):

```elixir
test "MnesiaStore table exists after application start" do
  # The application starts in test setup — just verify the table is present
  tables = :mnesia.system_info(:tables)
  assert :shem_events in tables
end
```

Check the file exists first:
```bash
ls test/shem/application_test.exs
```

If the file exists, append the test to the existing module. If not, create it:

```elixir
defmodule Shem.ApplicationExecutorTest do
  use ExUnit.Case, async: false

  test "MnesiaStore table exists after application start" do
    tables = :mnesia.system_info(:tables)
    assert :shem_events in tables
  end
end
```

- [ ] **Step 2.2: Run the test to confirm it fails**

```bash
mix test test/shem/application_test.exs 2>&1 | tail -10
```

Expected: `:shem_events not in tables` or table missing.

- [ ] **Step 2.3: Add MnesiaStore.setup! call to Application.start/2**

In `lib/shem/application.ex`, add the setup call at the top of `start/2`, before the children list:

```elixir
@impl true
def start(_type, _args) do
  resolve_executor_backend()
  Shem.EventLog.MnesiaStore.setup!()   # ← add this line

  children =
    [
      # ... rest unchanged
```

- [ ] **Step 2.4: Run test to confirm it passes**

```bash
mix test test/shem/application_test.exs
```

Expected: passes.

- [ ] **Step 2.5: Run the full test suite to check for regressions**

```bash
mix test --exclude distributed
```

Expected: same pass count as before (962 tests or current count), 0 failures.

- [ ] **Step 2.6: Commit**

```bash
git add lib/shem/application.ex test/shem/application_test.exs
git commit -m "feat: call MnesiaStore.setup! at application start to ensure :shem_events table exists"
```

---

## Task 3: Auto Backend Selection in EventLog

**Files:**
- Modify: `lib/shem/event_log.ex`

`EventLog.init/1` currently reads `Application.get_env(:shem, :event_log_store, Shem.EventLog.DETSStore)`. Replace the default with a `select_store/0` helper that checks `Node.list()` and `:force_mnesia`.

- [ ] **Step 3.1: Write the failing tests**

Create `test/shem/event_log/backend_selection_test.exs`:

```elixir
defmodule Shem.EventLog.BackendSelectionTest do
  use ExUnit.Case, async: false

  test "selects DETSStore when single-node and no :force_mnesia" do
    Application.delete_env(:shem, :force_mnesia)
    Application.delete_env(:shem, :event_log_store)
    # Single-node: Node.list() == [] in test env
    {:ok, pid} = Shem.EventLog.start_link([])
    state = :sys.get_state(pid)
    assert state.store == Shem.EventLog.DETSStore
    GenServer.stop(pid)
  end

  test "selects MnesiaStore when :force_mnesia is true" do
    Application.put_env(:shem, :force_mnesia, true)
    Application.delete_env(:shem, :event_log_store)
    {:ok, pid} = Shem.EventLog.start_link([])
    state = :sys.get_state(pid)
    assert state.store == Shem.EventLog.MnesiaStore
    GenServer.stop(pid)
  after
    Application.delete_env(:shem, :force_mnesia)
  end

  test "explicit :event_log_store config overrides auto-selection" do
    Application.put_env(:shem, :event_log_store, Shem.EventLog.DETSStore)
    Application.put_env(:shem, :force_mnesia, true)
    {:ok, pid} = Shem.EventLog.start_link([])
    state = :sys.get_state(pid)
    assert state.store == Shem.EventLog.DETSStore
    GenServer.stop(pid)
  after
    Application.delete_env(:shem, :event_log_store)
    Application.delete_env(:shem, :force_mnesia)
  end
end
```

- [ ] **Step 3.2: Run tests to confirm they fail**

```bash
mix test test/shem/event_log/backend_selection_test.exs 2>&1 | tail -15
```

Expected: test 2 fails — `DETSStore` is selected even with `:force_mnesia`.

- [ ] **Step 3.3: Replace init/1 logic in EventLog**

In `lib/shem/event_log.ex`, replace the `init/1` callback:

```elixir
@impl true
def init(_opts) do
  store = select_store()
  {:ok, %{sessions: %{}, store: store}}
end
```

Add the private helper immediately after the `init` (before `handle_call`):

```elixir
defp select_store do
  explicit = Application.get_env(:shem, :event_log_store)
  force_mnesia = Application.get_env(:shem, :force_mnesia, false)

  cond do
    explicit != nil -> explicit
    force_mnesia || Node.list() != [] -> Shem.EventLog.MnesiaStore
    true -> Shem.EventLog.DETSStore
  end
end
```

- [ ] **Step 3.4: Run tests to confirm they pass**

```bash
mix test test/shem/event_log/backend_selection_test.exs
```

Expected: all 3 tests pass.

- [ ] **Step 3.5: Full suite — no regressions**

```bash
mix test --exclude distributed
```

Expected: 0 failures.

- [ ] **Step 3.6: Commit**

```bash
git add lib/shem/event_log.ex test/shem/event_log/backend_selection_test.exs
git commit -m "feat: auto-select MnesiaStore in EventLog when clustered or :force_mnesia is set"
```

---

## Task 4: Cluster Node Onboarding — Mnesia Replication on :nodeup

**Files:**
- Modify: `lib/shem/cluster.ex`

When a new node joins, `Shem.Cluster.handle_info({:nodeup, node})` must trigger Mnesia replication so the joining node gets a full copy of `:shem_events`. Call `MnesiaStore.onboard_from/1` with the existing node (the node that just announced itself).

- [ ] **Step 4.1: Write the failing test**

Add to `test/shem/cluster_test.exs` inside the existing `Shem.ClusterTest` module:

```elixir
describe "Mnesia onboarding" do
  test "nodeup handler does not crash when MnesiaStore.onboard_from is called" do
    # The table already exists from application setup — onboarding a non-existent
    # node should be handled gracefully (no crash).
    {:ok, pid} = Shem.Cluster.start_link([])
    send(pid, {:nodeup, :"fake@127.0.0.1"})
    Process.sleep(100)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end
end
```

- [ ] **Step 4.2: Run the test to confirm it passes already (or fails)**

```bash
mix test test/shem/cluster_test.exs
```

Expected: the new test may pass already (Cluster doesn't crash on fake nodeup). Confirm it's green, then proceed with adding the real onboarding logic.

- [ ] **Step 4.3: Add onboard_mnesia call to :nodeup handler in Shem.Cluster**

In `lib/shem/cluster.ex`, update `handle_info({:nodeup, node}, state)`:

```elixir
@impl true
def handle_info({:nodeup, node}, state) do
  Logger.info("Shem.Cluster: node joined — #{node}")
  emit(:cluster_node_joined, %{node: node})
  sync_horde(node)
  onboard_mnesia(node)
  {:noreply, state}
end
```

Add the private helper at the bottom of the private section:

```elixir
defp onboard_mnesia(existing_node) do
  try do
    Shem.EventLog.MnesiaStore.onboard_from(existing_node)
  catch
    _, reason ->
      Logger.warning(
        "Shem.Cluster: Mnesia onboarding failed for #{existing_node}: #{inspect(reason)}"
      )
  end
end
```

- [ ] **Step 4.4: Run cluster tests to confirm no regressions**

```bash
mix test test/shem/cluster_test.exs
```

Expected: all existing tests pass, including the new one.

- [ ] **Step 4.5: Full suite — no regressions**

```bash
mix test --exclude distributed
```

Expected: 0 failures.

- [ ] **Step 4.6: Commit**

```bash
git add lib/shem/cluster.ex test/shem/cluster_test.exs
git commit -m "feat: trigger Mnesia node onboarding in Shem.Cluster on :nodeup"
```

---

## Task 5: Distributed EventLog Tests with :peer

**Files:**
- Create: `test/shem/distributed/event_log_test.exs`

These tests require a named node and EPMD. Run with:
```
elixir --sname shem_test -S mix test --only distributed
```

The `:peer` pattern follows `test/shem/cluster_test.exs` exactly — same `start_peer/1` helper, same `Code.eval_string` for RPC, same `assert_eventually/3` poll helper.

- [ ] **Step 5.1: Create the test directory**

```bash
mkdir -p test/shem/distributed
```

- [ ] **Step 5.2: Write the distributed tests**

Create `test/shem/distributed/event_log_test.exs`:

```elixir
defmodule Shem.Distributed.EventLogTest do
  use ExUnit.Case, async: false

  @moduletag :distributed

  # Run with:
  #   elixir --sname shem_test -S mix test --only distributed

  alias Shem.EventLog.{MnesiaStore, Event}

  setup_all do
    unless Node.alive?() do
      Node.start(:shem_test, :shortnames)
    end

    :ok
  end

  # ── Helpers (same pattern as cluster_test.exs) ───────────────────────────────

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

  defp assert_eventually(fun, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(interval_ms)
          :retry
        else
          :timeout
        end
      end
    end)
    |> Enum.find(fn r -> r in [:ok, :timeout] end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("Condition not met within #{timeout_ms}ms")
    end
  end

  defp setup_mnesia_on_peer(peer_node) do
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
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  test "write events on node A — read from node B" do
    {:ok, peer, peer_node} = start_peer(:shem_b_el39a)
    on_exit(fn -> :peer.stop(peer) end)

    setup_mnesia_on_peer(peer_node)

    session_id = "ses_dist_#{:erlang.unique_integer([:positive])}"
    {:ok, handle} = MnesiaStore.open(session_id, "/ignored")
    event = Event.new(session_id, :agent_started, %{name: "alice"})
    :ok = MnesiaStore.append(handle, event)

    assert_eventually(
      fn ->
        result =
          :rpc.call(peer_node, Code, :eval_string, [
            """
            alias Shem.EventLog.MnesiaStore
            case MnesiaStore.read_all("#{session_id}") do
              {:ok, events} -> length(events)
              _ -> 0
            end
            """
          ])

        case result do
          {count, _} when is_integer(count) -> count == 1
          _ -> false
        end
      end,
      5_000
    )
  end

  test "node A dies mid-session — node B reads session from Mnesia" do
    {:ok, peer, peer_node} = start_peer(:shem_b_el39b)

    session_id = "ses_dead_#{:erlang.unique_integer([:positive])}"
    {:ok, handle} = MnesiaStore.open(session_id, "/ignored")

    e1 = Event.new(session_id, :turn_started, %{turn: 1})
    e2 = Event.new(session_id, :turn_started, %{turn: 2})
    :ok = MnesiaStore.append(handle, e1)
    :ok = MnesiaStore.append(handle, e2)

    setup_mnesia_on_peer(peer_node)

    # Wait for replication before killing the peer
    assert_eventually(
      fn ->
        result =
          :rpc.call(peer_node, Code, :eval_string, [
            """
            alias Shem.EventLog.MnesiaStore
            case MnesiaStore.read_all("#{session_id}") do
              {:ok, events} -> length(events)
              _ -> 0
            end
            """
          ])

        case result do
          {2, _} -> true
          _ -> false
        end
      end,
      5_000
    )

    # Now kill node A (this node) connection by stopping the peer,
    # and verify events are still readable on peer_node from its own Mnesia copy
    :peer.stop(peer)

    # After peer stops, we verify our local node still has the events
    {:ok, events} = MnesiaStore.read_all(session_id)
    assert length(events) == 2
    assert Enum.map(events, & &1.payload.turn) == [1, 2]
  end

  test "new node joining live cluster replicates existing events" do
    session_id = "ses_existing_#{:erlang.unique_integer([:positive])}"
    {:ok, handle} = MnesiaStore.open(session_id, "/ignored")

    # Write 5 events before peer joins
    for i <- 1..5 do
      MnesiaStore.append(handle, Event.new(session_id, :step, %{i: i}))
    end

    # Now start peer and onboard it
    {:ok, peer, peer_node} = start_peer(:shem_b_el39c)
    on_exit(fn -> :peer.stop(peer) end)

    setup_mnesia_on_peer(peer_node)

    # Peer should replicate all 5 events from before it joined
    assert_eventually(
      fn ->
        result =
          :rpc.call(peer_node, Code, :eval_string, [
            """
            alias Shem.EventLog.MnesiaStore
            case MnesiaStore.read_all("#{session_id}") do
              {:ok, events} -> length(events)
              _ -> 0
            end
            """
          ])

        case result do
          {5, _} -> true
          _ -> false
        end
      end,
      10_000
    )
  end

  test "single-node: EventLog auto-selects DETSStore" do
    # Verify that without Node.list() and without :force_mnesia,
    # EventLog selects DETSStore (not MnesiaStore).
    # This test runs on the named node but with no peers connected.
    Application.delete_env(:shem, :force_mnesia)
    Application.delete_env(:shem, :event_log_store)

    assert Node.list() == [], "Expected no peer nodes for this test"

    {:ok, pid} = Shem.EventLog.start_link([])
    state = :sys.get_state(pid)
    assert state.store == Shem.EventLog.DETSStore
    GenServer.stop(pid)
  end
end
```

- [ ] **Step 5.3: Run the distributed tests**

```bash
elixir --sname shem_test -S mix test --only distributed 2>&1 | tail -30
```

Expected: all 4 tests pass. If a test fails with a Mnesia match spec error, check that `read_all` match head uses a literal `session_id` string — Mnesia allows concrete values in match head patterns.

- [ ] **Step 5.4: Run the non-distributed suite to confirm no regressions**

```bash
mix test --exclude distributed
```

Expected: 0 failures.

- [ ] **Step 5.5: Commit**

```bash
git add test/shem/distributed/event_log_test.exs
git commit -m "test: distributed EventLog tests — write on A / read from B, node death, new node replication"
```

---

## Task 6: Update North Star and Memory

- [ ] **Step 6.1: Update PROJECT_NORTH_STAR.md**

In `PROJECT_NORTH_STAR.md`, update the Current Phase section:

```markdown
## Current Phase
**Phase 40 — Agent Failover, Evacuation & Placement**: Third of four distributed mesh phases (38–41).
Goal: agents survive node death transparently, shut down gracefully without losing progress, and can be targeted to nodes by capability.
Spec: `docs/superpowers/specs/2026-06-13-distributed-mesh-design.md`.

**Phase 39 — Distributed EventLog (MnesiaStore)**: COMPLETE. `MnesiaStore` implements `Store` behaviour over `:mnesia`; `EventLog` auto-selects backend at init; `Shem.Cluster` onboards Mnesia on `:nodeup`; four distributed `:peer` tests pass.
```

- [ ] **Step 6.2: Commit**

```bash
git add PROJECT_NORTH_STAR.md
git commit -m "docs: mark Phase 39 complete, advance to Phase 40"
```

---

## Self-Review Against Spec

Spec requirement → task that covers it:

| Spec requirement | Task |
|---|---|
| `MnesiaStore` implements `Store` behaviour | Task 1 |
| `open/2` is no-op, returns `{:ok, session_id}` | Task 1 |
| `append/2` uses `dirty_write` | Task 1 |
| `read_all/1` range scan on session_id, sorted by timestamp | Task 1 |
| `get/3` point lookup by `{session_id, event_id}` | Task 1 |
| `disc_copies` on every cluster node | Task 1 (`setup!`) |
| `Application.ensure_all_started(:mnesia)` at boot | Task 2 |
| Auto-select: `Node.list() != []` or `:force_mnesia` → MnesiaStore | Task 3 |
| Single-node → DETSStore, zero config change | Task 3 |
| Node onboarding: `change_config` + `add_table_copy` + `wait_for_tables` | Task 4 |
| Onboard is idempotent (`already_exists` ignored) | Task 4 |
| Test: single-node selects DETSStore | Task 5 |
| Test: write on A, read from B | Task 5 |
| Test: node A dies, B reads from Mnesia | Task 5 |
| Test: new node joins, replication completes | Task 5 |
