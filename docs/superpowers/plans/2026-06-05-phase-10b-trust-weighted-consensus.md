# Phase 10b: Trust-Weighted Consensus — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a DETS-backed trust scoring system fed by HardeningJob outcomes, and surface trust bands in the tool manifest so agents can reason about tool reliability.

**Architecture:** `Trust.Store` (GenServer + DETS) records per-tool scores from hardening outcomes using recency-weighted blending. `HardeningJob.finish/3` calls `Trust.Store.record/2` on completion. `ToolDispatch.build_manifest/1` enriches each tool entry with `trust: :high | :medium | :low | :unrated | :builtin | :external`.

**Tech Stack:** Elixir/OTP, DETS, ExUnit

---

## File Map

**Create:**
- `lib/shem/trust/store.ex` — GenServer + DETS, `record/2`, `score/1`, `all/0`, `flush/0`
- `test/shem/trust/store_test.exs`

**Modify:**
- `lib/shem/application.ex` — add `Shem.Trust.Store` child before `adversarial_children()`
- `lib/shem/adversarial/hardening_job.ex` — call `Trust.Store.record/2` in `finish/3`
- `lib/shem/agent/tool_dispatch.ex` — add `trust:` field to manifest entries; add `score_to_band/1`
- `test/shem/adversarial/hardening_job_test.exs` — assert trust score updated after clean/max_rounds
- `test/shem/agent/tool_dispatch_test.exs` — assert trust fields on manifest entries
- `config/test.exs` — add `trust_store_path: "tmp/test_trust.dets"`

---

### Task 1: `Shem.Trust.Store` GenServer

**Files:**
- Create: `lib/shem/trust/store.ex`
- Create: `test/shem/trust/store_test.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Add test config**

In `config/test.exs`, add:

```elixir
config :shem, trust_store_path: "tmp/test_trust.dets"
```

- [ ] **Step 2: Write failing tests**

Create `test/shem/trust/store_test.exs`:

```elixir
defmodule Shem.Trust.StoreTest do
  use ExUnit.Case, async: false

  alias Shem.Trust.Store

  setup do
    Store.flush()
    on_exit(fn -> Store.flush() end)
    :ok
  end

  describe "score/1" do
    test "returns {:error, :unrated} for unknown tool_id" do
      assert {:error, :unrated} = Store.score("no_such_tool")
    end
  end

  describe "record/2 and score/1" do
    test "clean first pass sets score to 1.0" do
      Store.record("tool_1", %{outcome: :clean, rounds: 1})
      assert {:ok, score} = Store.score("tool_1")
      assert_in_delta score, 1.0, 0.001
    end

    test "clean pass after 3 rounds decays score" do
      Store.record("tool_2", %{outcome: :clean, rounds: 3})
      assert {:ok, score} = Store.score("tool_2")
      # 1.0 - (3-1)*0.15 = 0.7
      assert_in_delta score, 0.7, 0.001
    end

    test "max_rounds_reached sets score to 0.2" do
      Store.record("tool_3", %{outcome: :max_rounds_reached, rounds: 3})
      assert {:ok, score} = Store.score("tool_3")
      assert_in_delta score, 0.2, 0.001
    end

    test "error sets score to 0.1" do
      Store.record("tool_4", %{outcome: :error, rounds: 0})
      assert {:ok, score} = Store.score("tool_4")
      assert_in_delta score, 0.1, 0.001
    end

    test "second record blends with recency weight 0.7" do
      Store.record("tool_5", %{outcome: :clean, rounds: 1})   # score = 1.0
      Store.record("tool_5", %{outcome: :max_rounds_reached, rounds: 3})  # new = 0.7 * 0.2 + 0.3 * 1.0 = 0.44
      assert {:ok, score} = Store.score("tool_5")
      assert_in_delta score, 0.44, 0.001
    end

    test "score clamped to [0.0, 1.0]" do
      Store.record("tool_6", %{outcome: :clean, rounds: 1})
      Store.record("tool_6", %{outcome: :clean, rounds: 1})
      assert {:ok, score} = Store.score("tool_6")
      assert score <= 1.0
      assert score >= 0.0
    end
  end

  describe "all/0" do
    test "returns map of all recorded tool_ids to scores" do
      Store.record("tool_a", %{outcome: :clean, rounds: 1})
      Store.record("tool_b", %{outcome: :error, rounds: 1})
      result = Store.all()
      assert Map.has_key?(result, "tool_a")
      assert Map.has_key?(result, "tool_b")
      assert result["tool_a"] >= 0.9
    end
  end

  describe "DETS persistence across restarts" do
    test "score survives GenServer restart at same path" do
      tmp_path = "tmp/trust_persist_#{System.unique_integer([:positive])}.dets"
      on_exit(fn -> File.rm_f(tmp_path) end)

      {:ok, pid1} = GenServer.start_link(Store, [path: tmp_path])
      GenServer.call(pid1, {:record, "persist_tool", :clean, 1})
      GenServer.stop(pid1)

      {:ok, pid2} = GenServer.start_link(Store, [path: tmp_path])
      assert {:ok, score} = GenServer.call(pid2, {:score, "persist_tool"})
      assert score >= 0.9
      GenServer.stop(pid2)
    end
  end
end
```

- [ ] **Step 3: Run to verify they fail**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/trust/store_test.exs --seed 0 2>&1 | tail -10
```

Expected: compile errors — `Shem.Trust.Store` undefined.

- [ ] **Step 4: Create `lib/shem/trust/store.ex`**

```elixir
defmodule Shem.Trust.Store do
  use GenServer

  @default_path Path.join([System.user_home!(), ".config", "shem", "trust.dets"])
  @recency_weight 0.7

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record(String.t(), %{outcome: atom(), rounds: non_neg_integer()}) :: :ok
  def record(tool_id, %{outcome: outcome, rounds: rounds}) do
    GenServer.call(__MODULE__, {:record, tool_id, outcome, rounds})
  end

  @spec score(String.t()) :: {:ok, float()} | {:error, :unrated}
  def score(tool_id) do
    GenServer.call(__MODULE__, {:score, tool_id})
  end

  @spec all() :: %{String.t() => float()}
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl true
  def init(opts) do
    path =
      Keyword.get(
        opts,
        :path,
        Application.get_env(:shem, :trust_store_path, @default_path)
      )

    path_charlist = to_charlist(path)
    File.mkdir_p!(Path.dirname(path))
    {:ok, table} = :dets.open_file(path_charlist, type: :set, file: path_charlist)
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:record, tool_id, outcome, rounds}, _from, state) do
    prior =
      case :dets.lookup(state.table, tool_id) do
        [{^tool_id, entry}] -> entry
        [] -> nil
      end

    outcome_score = compute_outcome_score(outcome, rounds)
    new_score = blend(prior && prior.score, outcome_score)

    entry = %{
      tool_id: tool_id,
      score: new_score,
      last_updated: DateTime.utc_now(),
      hardening_count: if(prior, do: prior.hardening_count + 1, else: 1)
    }

    :dets.insert(state.table, {tool_id, entry})
    {:reply, :ok, state}
  end

  def handle_call({:score, tool_id}, _from, state) do
    result =
      case :dets.lookup(state.table, tool_id) do
        [{^tool_id, entry}] -> {:ok, entry.score}
        [] -> {:error, :unrated}
      end

    {:reply, result, state}
  end

  def handle_call(:all, _from, state) do
    result =
      :dets.foldl(
        fn {id, entry}, acc -> Map.put(acc, id, entry.score) end,
        %{},
        state.table
      )

    {:reply, result, state}
  end

  def handle_call(:flush, _from, state) do
    :dets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :dets.close(state.table)
  end

  defp compute_outcome_score(:clean, 1), do: 1.0
  defp compute_outcome_score(:clean, n), do: max(1.0 - (n - 1) * 0.15, 0.3)
  defp compute_outcome_score(:max_rounds_reached, _), do: 0.2
  defp compute_outcome_score(:error, _), do: 0.1

  defp blend(nil, outcome_score), do: outcome_score

  defp blend(prior, outcome_score) do
    (@recency_weight * outcome_score + (1 - @recency_weight) * prior)
    |> max(0.0)
    |> min(1.0)
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/shem/trust/store_test.exs --seed 0 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 6: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all pass (Trust.Store not yet wired into Application, but tests start it directly).

- [ ] **Step 7: Commit**

```bash
git add lib/shem/trust/store.ex test/shem/trust/store_test.exs config/test.exs
git commit -m "feat: Shem.Trust.Store — DETS-backed trust scoring with recency weighting"
```

---

### Task 2: Application wiring

**Files:**
- Modify: `lib/shem/application.ex`

- [ ] **Step 1: Add `Trust.Store` child**

In `lib/shem/application.ex`, add `Shem.Trust.Store` to the base children list, before `adversarial_children()`:

```elixir
children =
  [
    {Horde.Registry, [name: Shem.Registry, keys: :unique, members: :auto]},
    Shem.AgentSupervisor,
    Shem.EventLog,
    {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
    Shem.Lab.Registry,
    Shem.LLM.BudgetServer,
    Shem.Trust.Store
  ] ++
    adversarial_children() ++
    llm_stub_children() ++
    mcp_children() ++
    cluster_children() ++
    tui_children()
```

- [ ] **Step 2: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass. `Trust.Store` starts in test env and uses `"tmp/test_trust.dets"`.

- [ ] **Step 3: Commit**

```bash
git add lib/shem/application.ex
git commit -m "feat: add Trust.Store to Application supervision tree"
```

---

### Task 3: HardeningJob integration

**Files:**
- Modify: `lib/shem/adversarial/hardening_job.ex`
- Modify: `test/shem/adversarial/hardening_job_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/shem/adversarial/hardening_job_test.exs` inside the existing `setup` block — add `Trust.Store.flush()` call:

```elixir
setup do
  StubTransport.Server.reset()
  Shem.LLM.BudgetServer.reset()
  Shem.Trust.Store.flush()
  lab_dir = Application.get_env(:shem, :lab_dir)
  on_exit(fn ->
    File.rm_rf!(lab_dir)
    Lab.Registry.flush()
  end)

  {:ok, tool} = Lab.GraduationGate.run(@tool_source, @tool_test_src)
  {:ok, tool: tool}
end
```

Then add two new test cases at the end of the file:

```elixir
describe "trust score updated after hardening" do
  test "clean first pass records a high trust score", %{tool: tool} do
    stub("NO_FAILURES_FOUND")

    {:ok, pid} = HardeningJob.start_link({tool.id, []})
    wait_done(pid)

    assert {:ok, score} = Shem.Trust.Store.score(tool.id)
    assert score >= 0.8
  end

  test "max_rounds_reached records a low trust score", %{tool: tool} do
    stub("FAILURES_FOUND: error 1"); stub("Fixed 1.")
    stub("FAILURES_FOUND: error 2"); stub("Fixed 2.")
    stub("FAILURES_FOUND: error 3"); stub("Fixed 3.")

    {:ok, pid} = HardeningJob.start_link({tool.id, []})
    wait_done(pid, 10_000)

    assert {:ok, score} = Shem.Trust.Store.score(tool.id)
    assert score <= 0.3
  end
end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/adversarial/hardening_job_test.exs --seed 0 2>&1 | tail -10
```

Expected: 2 failures — `Trust.Store.score` returns `{:error, :unrated}` because `finish/3` doesn't record yet.

- [ ] **Step 3: Update `finish/3` in `hardening_job.ex`**

Find `defp finish(state, outcome, extra_round \\ 0)` and replace with:

```elixir
defp finish(state, outcome, extra_round \\ 0) do
  rounds = state.round + extra_round
  Shem.Trust.Store.record(state.tool_id, %{outcome: outcome, rounds: rounds})

  EventLog.append(state.session_id, :hardening_completed, %{
    tool: state.tool_name,
    rounds: rounds,
    outcome: outcome
  })

  %{state | status: :done}
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/adversarial/hardening_job_test.exs --seed 0 2>&1 | tail -10
```

Expected: all 6 tests pass.

- [ ] **Step 5: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/adversarial/hardening_job.ex test/shem/adversarial/hardening_job_test.exs
git commit -m "feat: HardeningJob records trust score on completion"
```

---

### Task 4: ToolDispatch manifest enrichment

**Files:**
- Modify: `lib/shem/agent/tool_dispatch.ex`
- Modify: `test/shem/agent/tool_dispatch_test.exs`

- [ ] **Step 1: Write failing tests**

Add to the existing `describe "build_manifest/1"` block in `test/shem/agent/tool_dispatch_test.exs`:

```elixir
test "builtin tools have trust: :builtin" do
  config = %Config{task: "t", system_prompt: "s", tools: []}
  manifest = ToolDispatch.build_manifest(config)
  builtin = Enum.find(manifest, &(&1.name == "read_file"))
  assert builtin.trust == :builtin
end

test "unrated Lab tool has trust: :unrated" do
  source = """
  defmodule TrustUnratedTool do
    def run(_args), do: :ok
  end
  """
  test_src = """
  defmodule TrustUnratedToolTest do
    def run, do: :ok
  end
  """
  {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
  Shem.Trust.Store.flush()

  config = %Config{task: "t", system_prompt: "s", tools: []}
  manifest = ToolDispatch.build_manifest(config)
  entry = Enum.find(manifest, &(&1.name == tool.name))
  assert entry.trust == :unrated
end

test "rated Lab tool has correct trust band" do
  source = """
  defmodule TrustRatedTool do
    def run(_args), do: :ok
  end
  """
  test_src = """
  defmodule TrustRatedToolTest do
    def run, do: :ok
  end
  """
  {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
  Shem.Trust.Store.record(tool.id, %{outcome: :clean, rounds: 1})

  config = %Config{task: "t", system_prompt: "s", tools: []}
  manifest = ToolDispatch.build_manifest(config)
  entry = Enum.find(manifest, &(&1.name == tool.name))
  assert entry.trust == :high
end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/agent/tool_dispatch_test.exs --seed 0 2>&1 | tail -10
```

Expected: 3 failures — manifest entries have no `trust` key.

- [ ] **Step 3: Update `@builtins` in `tool_dispatch.ex`**

Add `trust: :builtin` to every entry in `@builtins`. Example — the full updated list:

```elixir
@builtins [
  %{
    name: "write_tool",
    description:
      "Graduate a new Elixir tool into the Lab. Args: source (string), test_source (string).",
    source: :builtin,
    trust: :builtin
  },
  %{
    name: "run_code",
    description:
      "Run Elixir source defining a module with run/0. Returns the result. Args: source (string), timeout_ms (integer, optional).",
    source: :builtin,
    trust: :builtin
  },
  %{
    name: "list_tools",
    description: "List all tools currently available.",
    source: :builtin,
    trust: :builtin
  },
  %{
    name: "read_file",
    description: "Read a file and return its contents. Args: path (string).",
    source: :builtin,
    trust: :builtin
  },
  %{
    name: "write_file",
    description: "Write content to a file. Args: path (string), content (string).",
    source: :builtin,
    trust: :builtin
  },
  %{
    name: "list_dir",
    description: "List entries in a directory. Args: path (string).",
    source: :builtin,
    trust: :builtin
  },
  %{
    name: "shell",
    description:
      "Run a shell command and return stdout. Args: cmd (string), timeout_ms (integer, optional, default 10000). NOTE: runs locally until Phase 9b K8s executor.",
    source: :builtin,
    trust: :builtin
  }
]
```

- [ ] **Step 4: Add `score_to_band/1` helper and update lab tool mapping**

Add the private helper at the bottom of `tool_dispatch.ex` (before the last `end`):

```elixir
defp score_to_band(score) when score >= 0.8, do: :high
defp score_to_band(score) when score >= 0.5, do: :medium
defp score_to_band(_score), do: :low
```

Update the `lab_tools` mapping in `build_manifest/1`:

```elixir
lab_tools =
  Lab.Registry.all()
  |> then(fn tools ->
    if allowed_tools == [],
      do: tools,
      else: Enum.filter(tools, &(&1.name in allowed_tools))
  end)
  |> Enum.map(fn tool ->
    trust =
      case Shem.Trust.Store.score(tool.id) do
        {:ok, score} -> score_to_band(score)
        {:error, :unrated} -> :unrated
      end

    %{
      name: tool.name,
      description: Map.get(tool.metadata, "description", "graduated tool: #{tool.name}"),
      source: {:lab, tool.id},
      trust: trust
    }
  end)
```

Update the `mcp_tools` mapping — add `trust: :external` to each MCP entry:

```elixir
|> Enum.map(fn t ->
  %{name: t["name"], description: t["description"] || "", source: {:mcp, server}, trust: :external}
end)
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/shem/agent/tool_dispatch_test.exs --seed 0 2>&1 | tail -10
```

Expected: all pass.

- [ ] **Step 6: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex test/shem/agent/tool_dispatch_test.exs
git commit -m "feat: enrich tool manifest with trust bands from Trust.Store"
```

---

## Self-Review

**Spec coverage:**
- ✅ `Trust.Store` GenServer + DETS backend — Task 1
- ✅ `record/2`, `score/1`, `all/0` public API — Task 1
- ✅ Score formula with recency weighting (0.7/0.3 blend) — Task 1
- ✅ Trust bands `:high` / `:medium` / `:low` / `:unrated` — Task 4
- ✅ `Trust.Store` added to Application before `Adversarial.Supervisor` — Task 2
- ✅ `HardeningJob.finish/3` calls `Trust.Store.record/2` — Task 3
- ✅ Builtin tools → `trust: :builtin` — Task 4
- ✅ MCP tools → `trust: :external` — Task 4
- ✅ Lab tools enriched with scored band — Task 4
- ✅ DETS persistence test — Task 1
- ✅ HardeningJob trust assertions (clean → high, max_rounds → low) — Task 3
- ✅ ToolDispatch manifest trust assertions — Task 4

**Placeholder scan:** None found.

**Type consistency:**
- `Trust.Store.record/2` called with `%{outcome: atom(), rounds: non_neg_integer()}` in both spec and Tasks 1/3
- `score_to_band/1` defined in Task 4, used in same task
- `trust:` key added in Task 4 `@builtins`, lab mapping, and MCP mapping — consistent atom values throughout
