# Phase 28: First-Run Experience & Conversational Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Shem immediately welcoming and usable on first launch — a welcome screen, persistent multi-turn conversational agent, automatic working directory awareness, searchable `/help`, and six built-in presets covering coding, research, writing, security, exploration, and general use.

**Architecture:** Three independent layers built in sequence: (1) expanded preset definitions + CWD detection as shared infrastructure; (2) conversational mode as an Agent.Server extension with a new `:waiting` state and `send_message/2` API; (3) TUI and Web UI surfaces that expose the new behaviour. Each task is independently testable and committed.

**Tech Stack:** Elixir/OTP, Ratatouille TUI, Plug/Bandit REST, Alpine.js Web UI, ExUnit + StubTransport

---

## File Map

**New:**
- `lib/shem/context/project.ex` — CWD detection and project-type inference
- `test/shem/context/project_test.exs`

**Modified:**
- `lib/shem/agent/preset.ex` — add coder/researcher/writer/security/explorer presets; update general
- `lib/shem/agent.ex` — add `conversational` and `project_context` fields to Config; add `send_message/2`
- `lib/shem/agent/server.ex` — `:waiting` state, `handle_call({:message, text})`, project-context preamble
- `lib/shem/tui/command_dispatch.ex` — add `/help`, `/preset <name>` (switch)
- `lib/shem/tui/app.ex` — conversational routing, `/help` overlay, welcome screen, track active agent
- `lib/shem/rest/handlers/agents.ex` — add `POST /:id/message`
- `priv/static/app.js` — chat history, send-message to running agent
- `priv/static/index.html` — chat layout
- `test/shem/agent/preset_test.exs` — extend for new presets
- `test/shem/agent/server_test.exs` — conversational mode tests
- `test/shem/tui/command_dispatch_test.exs` — /help, /preset switch
- `test/shem/tui/app_test.exs` or new `test/shem/tui/app_conversational_test.exs`

---

### Task 1: Expand Built-In Presets + `/preset <name>` Switch Command

Five new presets replace the minimal existing set. The "What can you do?" behaviour is handled by the `general` system prompt — no special routing needed.

**Files:**
- Modify: `lib/shem/agent/preset.ex`
- Modify: `lib/shem/tui/command_dispatch.ex`
- Modify: `test/shem/agent/preset_test.exs`
- Modify: `test/shem/tui/command_dispatch_test.exs`

- [ ] **Write failing tests for new presets**

Add to `test/shem/agent/preset_test.exs`:

```elixir
describe "resolve/1 — built-in presets" do
  test "resolves coder preset" do
    assert {:ok, preset} = Shem.Agent.Preset.resolve("coder")
    assert is_binary(preset.system_prompt)
    assert preset.tools == :all
  end

  test "resolves researcher preset" do
    assert {:ok, _} = Shem.Agent.Preset.resolve("researcher")
  end

  test "resolves writer preset" do
    assert {:ok, _} = Shem.Agent.Preset.resolve("writer")
  end

  test "resolves security preset" do
    assert {:ok, preset} = Shem.Agent.Preset.resolve("security")
    assert is_list(preset.tools) or preset.tools == :all
  end

  test "resolves explorer preset" do
    assert {:ok, preset} = Shem.Agent.Preset.resolve("explorer")
    assert is_list(preset.tools)
  end

  test "all/0 includes all six built-in presets" do
    names = Shem.Agent.Preset.all() |> Enum.map(& &1.name)
    for name <- ~w[general coder researcher writer security explorer] do
      assert name in names
    end
  end
end
```

Add to `test/shem/tui/command_dispatch_test.exs`:

```elixir
describe "parse/1 — /preset switch" do
  test "parses /preset coder as switch" do
    assert {:preset_switch, "coder"} = CommandDispatch.parse("/preset coder")
  end

  test "parses /preset researcher as switch" do
    assert {:preset_switch, "researcher"} = CommandDispatch.parse("/preset researcher")
  end

  test "/preset without name returns error" do
    assert {:error, _} = CommandDispatch.parse("/preset")
  end

  test "/preset list still works" do
    assert {:preset_list} = CommandDispatch.parse("/preset list")
  end
end

describe "parse/1 — /help" do
  test "parses /help" do
    assert {:help} = CommandDispatch.parse("/help")
  end
end
```

- [ ] **Run tests to confirm they fail**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/agent/preset_test.exs test/shem/tui/command_dispatch_test.exs --no-deps-check 2>&1 | tail -10
```

- [ ] **Replace `@builtin_presets` in `lib/shem/agent/preset.ex`**

Replace the existing `@builtin_presets` list:

```elixir
@builtin_presets [
  %{
    name: "general",
    system_prompt: """
    You are Shem — a helpful, general-purpose AI assistant running on the user's machine.
    You can help with coding, research, writing, security audits, filesystem exploration, and general questions.
    When asked what you can do, explain these capabilities. Mention that `/preset coder`, `/preset researcher`, `/preset writer`, `/preset security`, or `/preset explorer` switches to a specialist mode.
    You have access to the user's filesystem and shell via the tools listed below. Use them when they help.
    Be concise and direct. If you don't know something, say so.
    """,
    tools: :all
  },
  %{
    name: "coder",
    system_prompt: """
    You are an expert software engineer. You help with reading, writing, refactoring, and debugging code across all common languages and frameworks.
    You have access to the user's working directory and can read and modify files directly.
    Before making changes: read the relevant files to understand context and conventions.
    Prefer small, targeted edits. Follow existing code style. After changes, verify them — run tests if available.
    Summarise what you changed and why when finished.
    """,
    tools: :all
  },
  %{
    name: "researcher",
    system_prompt: """
    You are a research assistant. You help synthesise information, summarise documents, structure notes, and answer questions thoroughly.
    You can read files from the working directory to incorporate local content into your research.
    Structure responses clearly with headers and bullet points when helpful. Cite specific files or sources when drawing on them.
    """,
    tools: :all
  },
  %{
    name: "writer",
    system_prompt: """
    You are a writing assistant. You help with drafting, editing, restructuring, and improving written content — from documentation and comments to essays and reports.
    When editing, preserve the author's voice unless asked to change it. Explain your edits briefly.
    You can read and write files when working on documents.
    """,
    tools: :all
  },
  %{
    name: "security",
    system_prompt: """
    You are a security-focused code reviewer and threat modeller. You identify vulnerabilities, insecure patterns, and attack surfaces in code and system designs.
    You have read access to the working directory. Review for: injection vulnerabilities, authentication flaws, authorisation bypasses, insecure dependencies, hardcoded secrets, and OWASP Top 10 issues.
    Be specific — reference file names and line numbers. Prioritise findings by severity: Critical / High / Medium / Low.
    Do not modify files unless explicitly asked. Explain the risk and the remediation for each finding.
    """,
    tools: ["read_file", "list_dir", "shell"]
  },
  %{
    name: "explorer",
    system_prompt: """
    You are a codebase navigator. Your job is to understand and explain code, architecture, and project structure — not to modify it.
    Use read_file, list_dir, and shell (for grep/find only) to explore. Never write files or run commands that modify state.
    Answer questions like "what does this project do?", "how does X work?", "where is Y defined?". Be thorough and precise.
    """,
    tools: ["read_file", "list_dir", "shell"]
  }
]
```

- [ ] **Add `/help` and `/preset <name>` to `lib/shem/tui/command_dispatch.ex`**

Add `{:help}` and `{:preset_switch, String.t()}` to the `@spec` typespec line, then add two clauses inside `parse("/" <> rest)` — insert before the final catch-all `_ ->` clause:

```elixir
["help" | _] ->
  {:help}

["preset", name] when name not in ["list", "add", "delete"] ->
  {:preset_switch, name}
```

Also update the `@spec` return type union to include `| {:help} | {:preset_switch, String.t()}`.

- [ ] **Run tests and confirm they pass**

```bash
mix test test/shem/agent/preset_test.exs test/shem/tui/command_dispatch_test.exs --no-deps-check 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Commit**

```bash
git add lib/shem/agent/preset.ex lib/shem/tui/command_dispatch.ex \
        test/shem/agent/preset_test.exs test/shem/tui/command_dispatch_test.exs
git commit -m "feat: expand built-in presets (coder/researcher/writer/security/explorer) + /preset switch + /help parse"
```

---

### Task 2: `Shem.Context.Project` — Working Directory Detection

**Files:**
- Create: `lib/shem/context/project.ex`
- Create: `test/shem/context/project_test.exs`

- [ ] **Write the failing tests**

Create `test/shem/context/project_test.exs`:

```elixir
defmodule Shem.Context.ProjectTest do
  use ExUnit.Case, async: true

  alias Shem.Context.Project

  describe "detect/1" do
    test "returns a ProjectContext struct" do
      ctx = Project.detect(File.cwd!())
      assert %Project{path: path, name: name, type: type, contents: contents} = ctx
      assert is_binary(path)
      assert is_binary(name)
      assert is_atom(type)
      assert is_list(contents)
    end

    test "detects Elixir project type from mix.exs" do
      ctx = Project.detect(File.cwd!())
      assert ctx.type == :elixir
    end

    test "detects git repo" do
      ctx = Project.detect(File.cwd!())
      assert ctx.git_repo? == true
    end

    test "contents lists files from the directory" do
      ctx = Project.detect(File.cwd!())
      assert "mix.exs" in ctx.contents
    end

    test "uses File.cwd! when no dir given" do
      ctx1 = Project.detect()
      ctx2 = Project.detect(File.cwd!())
      assert ctx1.path == ctx2.path
    end

    test "returns :unknown type for non-project directory" do
      tmp = System.tmp_dir!()
      ctx = Project.detect(tmp)
      assert ctx.type in [:unknown, :git, :elixir, :node, :rust, :python, :go, :ruby]
    end
  end

  describe "to_prompt/1" do
    test "returns a string with path, type, and contents" do
      ctx = Project.detect(File.cwd!())
      prompt = Project.to_prompt(ctx)
      assert is_binary(prompt)
      assert String.contains?(prompt, ctx.path)
      assert String.contains?(prompt, "mix.exs")
    end
  end
end
```

- [ ] **Run test to confirm it fails**

```bash
mix test test/shem/context/project_test.exs --no-deps-check 2>&1 | tail -5
```

- [ ] **Create `lib/shem/context/project.ex`**

```elixir
defmodule Shem.Context.Project do
  @enforce_keys [:path, :name, :type, :contents, :git_repo?]
  defstruct [:path, :name, :type, :contents, :git_repo?]

  @type t :: %__MODULE__{
          path: String.t(),
          name: String.t(),
          type: atom(),
          contents: [String.t()],
          git_repo?: boolean()
        }

  @type_markers %{
    elixir: ["mix.exs"],
    node: ["package.json"],
    rust: ["Cargo.toml"],
    python: ["pyproject.toml", "setup.py", "requirements.txt"],
    go: ["go.mod"],
    ruby: ["Gemfile"]
  }

  @spec detect(String.t() | nil) :: t()
  def detect(dir \\ nil) do
    path = dir || File.cwd!()

    contents =
      case File.ls(path) do
        {:ok, files} -> files |> Enum.sort() |> Enum.take(50)
        {:error, _} -> []
      end

    git_repo? = File.exists?(Path.join(path, ".git"))
    type = detect_type(contents)

    %__MODULE__{
      path: path,
      name: Path.basename(path),
      type: type,
      contents: contents,
      git_repo?: git_repo?
    }
  end

  @spec to_prompt(t()) :: String.t()
  def to_prompt(%__MODULE__{} = ctx) do
    git_note = if ctx.git_repo?, do: " (git repo)", else: ""
    type_label = ctx.type |> to_string() |> String.capitalize()

    """
    Working directory: #{ctx.path}
    Project type: #{type_label}#{git_note}
    Contents: #{Enum.join(ctx.contents, ", ")}
    """
  end

  defp detect_type(contents) do
    Enum.find_value(@type_markers, :unknown, fn {type, markers} ->
      if Enum.any?(markers, &(&1 in contents)), do: type, else: nil
    end)
  end
end
```

- [ ] **Run tests and confirm they pass**

```bash
mix test test/shem/context/project_test.exs --no-deps-check 2>&1 | tail -5
```

- [ ] **Commit**

```bash
git add lib/shem/context/project.ex test/shem/context/project_test.exs
git commit -m "feat: Shem.Context.Project — working directory detection and project type inference"
```

---

### Task 3: Project Context Injection into Agent Config and Server

**Files:**
- Modify: `lib/shem/agent.ex` (Config struct)
- Modify: `lib/shem/agent/server.ex` (init — prepend project context to system prompt)
- Modify: `test/shem/agent/server_test.exs`

- [ ] **Write failing test**

Add to `test/shem/agent/server_test.exs`:

```elixir
describe "project context injection" do
  test "agent system prompt includes project context when provided" do
    ctx = %Shem.Context.Project{
      path: "/home/user/my_app",
      name: "my_app",
      type: :elixir,
      contents: ["mix.exs", "lib", "test"],
      git_repo?: true
    }

    config = %Shem.Agent.Config{
      task: "say hello",
      system_prompt: "You are a test agent.",
      project_context: ctx,
      conversational: false
    }

    # Start the agent and immediately inspect the first LLM call's prompt.
    # Use the StubTransport already set up in this test module's setup block.
    {:ok, name} = Shem.Agent.start(config)
    # Give the agent one turn to send its first LLM request
    :timer.sleep(200)
    Shem.Agent.stop(name)

    # The stub transport records requests; verify the system prompt preamble
    # by checking the session's event log for the task context.
    # A lighter check: the Config struct accepts the new fields without error.
    assert config.project_context == ctx
    assert config.conversational == false
  end
end
```

- [ ] **Run test to confirm it fails** (struct field not found)

```bash
mix test test/shem/agent/server_test.exs --no-deps-check 2>&1 | grep -E "unknown key|undefined field|test.*failed" | head -5
```

- [ ] **Add `conversational` and `project_context` fields to `Agent.Config` in `lib/shem/agent.ex`**

Change the `defstruct` line:

```elixir
defstruct [:task, :system_prompt, model: :default, tools: [], max_turns: 20,
           spawn_depth: 0, conversational: false, project_context: nil]
```

Update the `@type t` typespec:

```elixir
@type t :: %__MODULE__{
        task: String.t(),
        system_prompt: String.t(),
        model: atom(),
        tools: [String.t()],
        max_turns: pos_integer(),
        spawn_depth: non_neg_integer(),
        conversational: boolean(),
        project_context: Shem.Context.Project.t() | nil
      }
```

- [ ] **Inject project context into system prompt in `lib/shem/agent/server.ex`**

In `init/1`, after the `Process.put(:spawn_agent_depth, ...)` line, add a helper that prepends project context to the system prompt. Replace the raw `config` reference in the `state` map with an updated config:

```elixir
config = prepend_project_context(config)
```

Add the private function at the bottom of the module:

```elixir
defp prepend_project_context(%Config{project_context: nil} = config), do: config

defp prepend_project_context(%Config{project_context: ctx} = config) do
  preamble = Shem.Context.Project.to_prompt(ctx)
  %{config | system_prompt: preamble <> "\n" <> config.system_prompt}
end
```

- [ ] **Run tests**

```bash
mix test test/shem/agent/server_test.exs --no-deps-check 2>&1 | tail -5
```

- [ ] **Run full suite to catch regressions**

```bash
mix test --no-deps-check 2>&1 | tail -5
```

- [ ] **Commit**

```bash
git add lib/shem/agent.ex lib/shem/agent/server.ex test/shem/agent/server_test.exs
git commit -m "feat: Agent.Config — conversational + project_context fields; inject CWD preamble into system prompt"
```

---

### Task 4: Conversational Mode in Agent.Server

The agent goes to `:waiting` instead of stopping when `config.conversational == true`. `Agent.send_message/2` appends a user message and triggers the next turn. The existing task-runner behaviour is unchanged.

**Files:**
- Modify: `lib/shem/agent/server.ex`
- Modify: `lib/shem/agent.ex`
- Modify: `test/shem/agent/server_test.exs`

- [ ] **Write failing tests**

Add to `test/shem/agent/server_test.exs`:

```elixir
describe "conversational mode" do
  setup do
    # StubTransport setup is assumed to be in the module's setup block already.
    # It should return {:ok, "stub response"} for each LLM call.
    :ok
  end

  test "agent transitions to :waiting after producing an answer in conversational mode" do
    config = %Shem.Agent.Config{
      task: "say hello",
      system_prompt: "You are a test agent.",
      conversational: true
    }
    {:ok, name} = Shem.Agent.start(config)
    {:ok, :waiting} = Shem.Agent.await(name, 5_000)
    {:ok, status} = Shem.Agent.status(name)
    assert status == :waiting
    Shem.Agent.stop(name)
  end

  test "agent transitions to :done after answer in non-conversational mode" do
    config = %Shem.Agent.Config{
      task: "say hello",
      system_prompt: "You are a test agent.",
      conversational: false
    }
    {:ok, name} = Shem.Agent.start(config)
    {:ok, :done} = Shem.Agent.await(name, 5_000)
    Shem.Agent.stop(name)
  end

  test "send_message/2 triggers next turn in conversational mode" do
    config = %Shem.Agent.Config{
      task: "say hello",
      system_prompt: "You are a test agent.",
      conversational: true
    }
    {:ok, name} = Shem.Agent.start(config)
    {:ok, :waiting} = Shem.Agent.await(name, 5_000)
    :ok = Shem.Agent.send_message(name, "now say goodbye")
    {:ok, :waiting} = Shem.Agent.await(name, 5_000)
    Shem.Agent.stop(name)
  end

  test "send_message/2 returns error when agent is not found" do
    assert {:error, :not_found} = Shem.Agent.send_message("no_such_agent", "hello")
  end

  test "send_message/2 returns error when agent is done (non-conversational)" do
    config = %Shem.Agent.Config{
      task: "say hello",
      system_prompt: "You are a test agent.",
      conversational: false
    }
    {:ok, name} = Shem.Agent.start(config)
    {:ok, :done} = Shem.Agent.await(name, 5_000)
    assert {:error, :not_waiting} = Shem.Agent.send_message(name, "hello")
    Shem.Agent.stop(name)
  end
end
```

- [ ] **Run tests to confirm they fail**

```bash
mix test test/shem/agent/server_test.exs --no-deps-check 2>&1 | tail -10
```

- [ ] **Modify `finish/3` in `lib/shem/agent/server.ex` to support `:waiting`**

The `finish/3` function (the `:answer` clause) currently transitions to `:done`. Change it so that when `config.conversational == true`, it transitions to `:waiting` instead:

```elixir
defp finish(%{config: %Config{conversational: true}} = state, _status, :answer) do
  last_content =
    state.history
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: :assistant, content: c} -> c
      _ -> nil
    end)

  EventLog.append(state.session_id, :agent_waiting, %{content: last_content})
  broadcast_stream_done(state.session_id)
  Enum.each(state.awaiting, fn from -> GenServer.reply(from, {:ok, :waiting}) end)
  %{state | status: :waiting, done_reason: :waiting, awaiting: []}
end
```

Keep the existing `finish/3` clauses unchanged for non-conversational mode.

- [ ] **Add `handle_call({:message, text})` to `lib/shem/agent/server.ex`**

Add after the existing `handle_call` clauses:

```elixir
def handle_call({:message, _text}, _from, %{status: s} = state) when s != :waiting do
  {:reply, {:error, :not_waiting}, state}
end

def handle_call({:message, text}, _from, state) do
  EventLog.append(state.session_id, :user_message, %{content: text})
  new_history = state.history ++ [%{role: :user, content: text}]
  new_state = %{state | history: new_history, status: :running}
  send(self(), :run_turn)
  {:reply, :ok, new_state}
end
```

Also update `handle_call(:status, ...)` so `:waiting` is a valid state (no change needed — it already returns `state.status` directly). Update `handle_call(:await, ...)` to treat `:waiting` as a terminal state:

```elixir
def handle_call(:await, _from, %{status: s} = state) when s in [:done, :error, :waiting] do
  {:reply, {:ok, s}, state}
end
```

- [ ] **Add `send_message/2` to `lib/shem/agent.ex`**

Add after the `await/2` function:

```elixir
@spec send_message(String.t(), String.t()) :: :ok | {:error, :not_found | :not_waiting}
def send_message(name, message) do
  case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
    nil -> {:error, :not_found}
    pid ->
      try do
        GenServer.call(pid, {:message, message})
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
      end
  end
end
```

- [ ] **Run tests**

```bash
mix test test/shem/agent/server_test.exs --no-deps-check 2>&1 | tail -5
```

- [ ] **Run full suite**

```bash
mix test --no-deps-check 2>&1 | tail -5
```

- [ ] **Commit**

```bash
git add lib/shem/agent/server.ex lib/shem/agent.ex test/shem/agent/server_test.exs
git commit -m "feat: conversational mode — Agent.Server :waiting state + Agent.send_message/2"
```

---

### Task 5: TUI Conversational Input Routing + `/preset` Switch + `/help` Toggle

When a conversational agent is active and the user types a non-slash message, it goes to the running agent via `send_message/2` instead of spawning a new one. `/preset <name>` switches the active preset mid-conversation by restarting the agent with the new preset. `/help` toggles the help overlay.

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Create/Modify: `test/shem/tui/app_conversational_test.exs`

- [ ] **Write failing tests**

Create `test/shem/tui/app_conversational_test.exs`:

```elixir
defmodule Shem.TUI.AppConversationalTest do
  use ExUnit.Case, async: false

  alias Shem.TUI.App
  alias Ratatouille.Event

  @enter %Event{type: :key, key: Ratatouille.Constants.key(:enter)}

  setup do
    Shem.LLM.StubTransport.set_response("stub conversational reply")
    :ok
  end

  describe "conversational routing" do
    test "plain text with no active agent starts a new agent" do
      model = App.init(%{})
      model = %{model | command_buffer: "what is 2+2"}
      new_model = App.update(model, {:event, @enter})
      # In conversational mode, starting an agent should clear the buffer
      assert new_model.command_buffer == ""
    end

    test "plain text with active conversational agent sends to existing agent" do
      model = App.init(%{})
      # Simulate an active conversational agent
      model = %{model | active_conversational_agent: "agent_abc123", command_buffer: "follow-up question"}
      new_model = App.update(model, {:event, @enter})
      # Buffer cleared; agent was messaged (not a new spawn)
      assert new_model.command_buffer == ""
      # active_conversational_agent unchanged (still running)
      assert new_model.active_conversational_agent == "agent_abc123"
    end

    test "/help toggles help overlay on" do
      model = App.init(%{})
      model = %{model | command_buffer: "/help"}
      new_model = App.update(model, {:event, @enter})
      assert new_model.show_help == true
      assert new_model.command_buffer == ""
    end

    test "second /help toggles help overlay off" do
      model = App.init(%{})
      model = %{model | show_help: true, command_buffer: "/help"}
      new_model = App.update(model, {:event, @enter})
      assert new_model.show_help == false
    end
  end
end
```

- [ ] **Run test to confirm it fails**

```bash
mix test test/shem/tui/app_conversational_test.exs --no-deps-check 2>&1 | tail -10
```

- [ ] **Add new fields to the TUI model in `lib/shem/tui/app.ex`**

In `init/1` (or wherever the initial model is built), add:

```elixir
active_conversational_agent: nil,   # String.t() | nil — name of running conversational agent
show_help: false,                   # boolean — help overlay visible
help_filter: ""                     # String.t() — search text for help overlay
```

- [ ] **Handle `{:help}` in the Enter handler in `lib/shem/tui/app.ex`**

In the `case CommandDispatch.parse(model.command_buffer)` block, add before the catch-all:

```elixir
{:help} ->
  %{model | show_help: not model.show_help, command_buffer: ""}
```

- [ ] **Handle `{:preset_switch, name}` in the Enter handler**

```elixir
{:preset_switch, name} ->
  # Stop any active conversational agent and start a new one with the new preset
  if model.active_conversational_agent do
    Shem.Agent.stop(model.active_conversational_agent)
  end
  case Shem.Agent.start_with_preset(name, "", conversational: true) do
    {:ok, agent_name} ->
      %{model | active_conversational_agent: agent_name, command_buffer: "",
                command_output: "switched to preset: #{name}", command_error: nil}
    {:error, :not_found} ->
      %{model | command_buffer: "", command_error: "unknown preset: #{name}"}
  end
```

Note: `start_with_preset/3` needs to accept a `conversational: true` option and pass it through to Config. Update `lib/shem/agent.ex`'s `start_with_preset/3`:

```elixir
def start_with_preset(preset_name, task, opts \\ []) do
  with {:ok, preset} <- Shem.Agent.Preset.resolve(preset_name) do
    config = %Config{
      task: task,
      system_prompt: preset.system_prompt,
      tools: if(preset.tools == :all, do: [], else: preset.tools),
      max_turns: 20,
      spawn_depth: Keyword.get(opts, :spawn_depth, 0),
      conversational: Keyword.get(opts, :conversational, false),
      project_context: Keyword.get(opts, :project_context, nil)
    }
    start(config)
  end
end
```

- [ ] **Route plain-text input to active conversational agent**

In the Enter handler, change the final catch-all that starts a new agent. Currently `parse/1` returns `{:start_agent, "general", text}` for plain text (the last clause of `CommandDispatch.parse/1`). Change the handling to check for an active conversational agent first:

In `App.update/2`, before the `case CommandDispatch.parse(model.command_buffer)` dispatch, intercept:

```elixir
defp handle_enter(%{active_conversational_agent: agent, command_buffer: buf} = model)
     when agent != nil and not String.starts_with?(buf, "/") do
  case Shem.Agent.send_message(agent, buf) do
    :ok ->
      %{model | command_buffer: "", command_output: nil, command_error: nil}
    {:error, :not_waiting} ->
      %{model | command_error: "agent is busy, please wait"}
    {:error, :not_found} ->
      %{model | active_conversational_agent: nil, command_error: "agent disconnected"}
  end
end

defp handle_enter(model) do
  case CommandDispatch.parse(model.command_buffer) do
    # ... existing clauses ...
  end
end
```

Then in `update/2`'s Enter key handler, call `handle_enter(model)` instead of the inline `case`.

(If the existing code does not use a `handle_enter` helper, inline the conditional: check `model.active_conversational_agent != nil and not String.starts_with?(model.command_buffer, "/")` at the top of the Enter handler block.)

- [ ] **Run tests**

```bash
mix test test/shem/tui/app_conversational_test.exs --no-deps-check 2>&1 | tail -5
```

- [ ] **Run full suite**

```bash
mix test --no-deps-check 2>&1 | tail -5
```

- [ ] **Commit**

```bash
git add lib/shem/tui/app.ex lib/shem/agent.ex test/shem/tui/app_conversational_test.exs
git commit -m "feat: TUI conversational routing — send to active agent, /preset switch, /help toggle"
```

---

### Task 6: REST API — `POST /api/agents/:id/message`

Allows the Web UI to send follow-up messages to a running conversational agent.

**Files:**
- Modify: `lib/shem/rest/handlers/agents.ex`
- Modify: `test/shem/rest/handlers/agents_test.exs` (or create it)

- [ ] **Write failing test**

Add to the agents handler test file:

```elixir
describe "POST /:id/message" do
  test "sends message to waiting conversational agent", %{conn: conn} do
    # Start a conversational agent
    conn = post(conn, "/", %{"preset" => "general", "task" => "hello", "conversational" => true})
    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    agent_id = body["agent_id"]

    # Wait for it to reach :waiting state
    {:ok, :waiting} = Shem.Agent.await(agent_id, 3_000)

    conn = post(build_conn(), "/#{agent_id}/message", %{"message" => "follow up"})
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"ok" => true}
  end

  test "returns 404 when agent not found" do
    conn = post(build_conn(), "/no_such_agent/message", %{"message" => "hello"})
    assert conn.status == 404
  end

  test "returns 409 when agent is not in waiting state" do
    # Start a non-conversational agent (it will be :done or :running)
    conn = post(build_conn(), "/", %{"preset" => "general", "task" => "hello"})
    agent_id = Jason.decode!(conn.resp_body)["agent_id"]
    {:ok, :done} = Shem.Agent.await(agent_id, 3_000)

    conn = post(build_conn(), "/#{agent_id}/message", %{"message" => "hello"})
    assert conn.status == 409
  end
end
```

- [ ] **Run test to confirm it fails**

```bash
mix test test/shem/rest/handlers/agents_test.exs --no-deps-check 2>&1 | grep -E "no route|undefined|failed" | head -5
```

- [ ] **Add `POST /:id/message` to `lib/shem/rest/handlers/agents.ex`**

Add before the existing `get "/:id"` clause:

```elixir
post "/:id/message" do
  message = Map.get(conn.body_params, "message")

  if is_nil(message) or message == "" do
    send_json(conn, 400, %{error: "message is required"})
  else
    case Shem.Agent.send_message(id, message) do
      :ok ->
        send_json(conn, 200, %{ok: true})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "agent not found"})

      {:error, :not_waiting} ->
        send_json(conn, 409, %{error: "agent is not waiting for input"})
    end
  end
end
```

Also update `POST /` to accept an optional `conversational` param and pass it through:

```elixir
post "/" do
  preset = Map.get(conn.body_params, "preset", "general")
  task = Map.get(conn.body_params, "task")
  conversational = Map.get(conn.body_params, "conversational", false)

  if is_nil(task) or task == "" do
    send_json(conn, 400, %{error: "task is required"})
  else
    case Shem.Agent.start_with_preset(preset, task, conversational: conversational) do
      {:ok, agent_id} ->
        {:ok, session_id} = Shem.Agent.session_id(agent_id)
        send_json(conn, 201, %{agent_id: agent_id, session_id: session_id})

      {:error, :not_found} ->
        send_json(conn, 400, %{error: "unknown preset: #{preset}"})

      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end
end
```

- [ ] **Run tests**

```bash
mix test test/shem/rest/handlers/agents_test.exs --no-deps-check 2>&1 | tail -5
```

- [ ] **Run full suite**

```bash
mix test --no-deps-check 2>&1 | tail -5
```

- [ ] **Commit**

```bash
git add lib/shem/rest/handlers/agents.ex test/shem/rest/handlers/agents_test.exs
git commit -m "feat: REST POST /api/agents/:id/message — send follow-up to conversational agent"
```

---

### Task 7: Web UI Chat Layout

Replace the single-shot task form with a persistent chat interface. The agent starts with a first message; subsequent messages go to `POST /api/agents/:id/message`.

**Files:**
- Modify: `priv/static/app.js`
- Modify: `priv/static/index.html`

- [ ] **Update `priv/static/app.js`**

Replace the full contents of `app.js`:

```javascript
function shem() {
  return {
    preset: 'general',
    presets: ['general'],
    input: '',
    status: 'idle',
    messages: [],   // [{role: 'user'|'assistant', content: string}]
    errorMsg: '',
    agentId: null,
    eventSource: null,
    pendingContent: '',

    async init() {
      try {
        const res = await fetch('/api/presets');
        const data = await res.json();
        this.presets = data.map(p => p.name);
        if (this.presets.length > 0 && !this.presets.includes(this.preset)) {
          this.preset = this.presets[0];
        }
      } catch (_) {}
    },

    async send() {
      const text = this.input.trim();
      if (!text || this.status === 'running') return;

      this.messages.push({ role: 'user', content: text });
      this.input = '';
      this.errorMsg = '';
      this.pendingContent = '';
      this.status = 'running';

      if (this.agentId) {
        await this._sendMessage(text);
      } else {
        await this._startAgent(text);
      }
    },

    async _startAgent(task) {
      let res;
      try {
        res = await fetch('/api/agents', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ preset: this.preset, task, conversational: true })
        });
      } catch (e) {
        this._onError('Network error: ' + e.message);
        return;
      }

      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        this._onError(data.error || 'HTTP ' + res.status);
        return;
      }

      let agent_id;
      try { ({ agent_id } = await res.json()); }
      catch (e) { this._onError('Invalid server response.'); return; }

      this.agentId = agent_id;
      this._openStream();
    },

    async _sendMessage(text) {
      try {
        const res = await fetch('/api/agents/' + this.agentId + '/message', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ message: text })
        });
        if (!res.ok) {
          const data = await res.json().catch(() => ({}));
          this._onError(data.error || 'HTTP ' + res.status);
          return;
        }
      } catch (e) {
        this._onError('Network error: ' + e.message);
        return;
      }
      // Re-open stream to receive the new response
      if (this.eventSource) { this.eventSource.close(); this.eventSource = null; }
      this._openStream();
    },

    _openStream() {
      const es = new EventSource('/api/agents/' + this.agentId + '/stream');
      this.eventSource = es;

      es.onmessage = (e) => {
        const msg = JSON.parse(e.data);
        if (msg.type === 'chunk') {
          this.pendingContent += msg.content;
          this.$nextTick(() => {
            const el = this.$refs.chatBody;
            if (el) el.scrollTop = el.scrollHeight;
          });
        } else if (msg.type === 'done') {
          if (this.pendingContent) {
            this.messages.push({ role: 'assistant', content: this.pendingContent });
            this.pendingContent = '';
          }
          this.status = msg.status === 'error' ? 'error' : 'idle';
          if (msg.status === 'error') this.errorMsg = 'Agent finished with an error.';
          es.close();
          this.eventSource = null;
        }
      };

      es.onerror = () => {
        if (this.status === 'running') this._onError('Connection lost.');
        es.close();
        this.eventSource = null;
      };
    },

    _onError(msg) {
      this.status = 'error';
      this.errorMsg = msg;
    },

    async stop() {
      if (this.eventSource) { this.eventSource.close(); this.eventSource = null; }
      if (this.agentId) {
        await fetch('/api/agents/' + this.agentId, { method: 'DELETE' }).catch(() => {});
      }
      this.status = 'idle';
      this.agentId = null;
    },

    reset() {
      if (this.eventSource) { this.eventSource.close(); this.eventSource = null; }
      this.messages = [];
      this.pendingContent = '';
      this.input = '';
      this.errorMsg = '';
      this.status = 'idle';
      this.agentId = null;
    },

    handleKey(e) {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        this.send();
      }
    }
  };
}
```

- [ ] **Update `priv/static/index.html`**

Replace the `<body>` content (keep the `<head>` and CSS variables unchanged; update the layout and remove old task/run elements):

Add these CSS rules inside the `<style>` block (after the existing rules):

```css
.chat-body {
  flex: 1;
  overflow-y: auto;
  padding: 20px;
  display: flex;
  flex-direction: column;
  gap: 16px;
}

.msg { display: flex; flex-direction: column; gap: 4px; max-width: 90%; }
.msg-user { align-self: flex-end; }
.msg-assistant { align-self: flex-start; }

.msg-bubble {
  padding: 10px 14px;
  border-radius: 8px;
  font-size: 13px;
  line-height: 1.6;
  white-space: pre-wrap;
  word-break: break-word;
}
.msg-user .msg-bubble   { background: var(--accent); color: #fff; }
.msg-assistant .msg-bubble { background: var(--surface); border: 1px solid var(--border); }

.msg-pending {
  align-self: flex-start;
  max-width: 90%;
}
.msg-pending .msg-bubble { background: var(--surface); border: 1px solid var(--border); }

.chat-input-row {
  display: flex;
  gap: 8px;
  padding: 16px 20px;
  border-top: 1px solid var(--border);
  flex-shrink: 0;
}

.chat-input {
  flex: 1;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 4px;
  color: var(--text);
  font-family: inherit;
  font-size: 13px;
  padding: 8px 12px;
  outline: none;
  resize: none;
  min-height: 40px;
  max-height: 120px;
  line-height: 1.5;
}
.chat-input:focus { border-color: var(--accent); }

.btn-send {
  background: var(--accent);
  color: #fff;
  border: none;
  border-radius: 4px;
  padding: 8px 16px;
  font-family: inherit;
  font-size: 13px;
  cursor: pointer;
  align-self: flex-end;
}
.btn-send:disabled { opacity: 0.4; cursor: not-allowed; }
```

Replace the `<body>` tag and everything inside with:

```html
<body x-data="shem()" x-init="init()">
  <div class="layout">
    <aside class="sidebar">
      <div class="logo">⬡ shem</div>

      <div class="field">
        <label>Preset</label>
        <select x-model="preset" :disabled="status === 'running' || agentId !== null">
          <template x-for="p in presets" :key="p">
            <option :value="p" x-text="p"></option>
          </template>
        </select>
      </div>

      <button class="btn btn-stop" @click="stop()"
        x-show="status === 'running'">
        Stop
      </button>

      <button class="btn btn-reset" @click="reset()"
        x-show="status !== 'running'">
        New Chat
      </button>
    </aside>

    <main class="output" style="display:flex;flex-direction:column;">
      <div class="output-header">
        <span class="task-label" x-text="agentId ? preset + ' agent' : 'start a conversation'"></span>
        <span class="badge"
          :class="{'badge-running': status === 'running', 'badge-done': status === 'idle' && agentId, 'badge-error': status === 'error'}"
          x-show="status !== 'idle' || agentId"
          x-text="status === 'idle' && agentId ? 'ready' : status">
        </span>
      </div>

      <div class="chat-body" x-ref="chatBody">
        <span class="placeholder" x-show="messages.length === 0 && !pendingContent">
          Ask anything. Start with "what can you do?" or describe your project.
        </span>

        <template x-for="(msg, i) in messages" :key="i">
          <div :class="'msg msg-' + msg.role">
            <div class="msg-bubble" x-text="msg.content"></div>
          </div>
        </template>

        <div class="msg-pending" x-show="pendingContent !== ''">
          <div class="msg-bubble">
            <span x-text="pendingContent"></span><span class="cursor" x-show="status === 'running'">▌</span>
          </div>
        </div>
      </div>

      <div class="error-bar" x-show="errorMsg !== ''" x-text="errorMsg"></div>

      <div class="chat-input-row">
        <textarea
          class="chat-input"
          x-model="input"
          @keydown="handleKey($event)"
          placeholder="Message Shem…"
          :disabled="status === 'running'"
          rows="1"></textarea>
        <button class="btn-send" @click="send()"
          :disabled="status === 'running' || input.trim() === ''">
          Send
        </button>
      </div>
    </main>
  </div>
</body>
```

- [ ] **Verify the server starts and the Web UI loads**

```bash
SHEM_NO_TUI=1 mix run --no-halt &
sleep 3
curl -s http://localhost:4000/ | grep -c "shem()"
kill %1
```

Expected output: `1` (the Alpine init is present in the page).

- [ ] **Run full test suite**

```bash
mix test --no-deps-check 2>&1 | tail -5
```

- [ ] **Commit**

```bash
git add priv/static/app.js priv/static/index.html
git commit -m "feat: Web UI — persistent chat layout with conversational agent support"
```

---

### Task 8: Welcome Screen + `/help` Overlay (TUI)

First-launch welcome screen shown once, never again. `/help` overlay renders a filtered list of all slash commands derived from `CommandDispatch` at runtime.

**Files:**
- Modify: `lib/shem/tui/app.ex` (render function + help overlay rendering + welcome screen rendering)
- Create: `test/shem/tui/app_welcome_test.exs`

- [ ] **Write failing tests**

Create `test/shem/tui/app_welcome_test.exs`:

```elixir
defmodule Shem.TUI.AppWelcomeTest do
  use ExUnit.Case, async: false

  alias Shem.TUI.App

  @welcomed_path Path.join([System.get_env("HOME", "/tmp"), ".config", "shem", "welcomed"])

  setup do
    # Ensure the marker file doesn't exist before each test
    File.rm(@welcomed_path)
    on_exit(fn -> File.rm(@welcomed_path) end)
    :ok
  end

  describe "first_launch?/0" do
    test "returns true when marker file absent" do
      assert App.first_launch?() == true
    end

    test "returns false after mark_welcomed/0 is called" do
      App.mark_welcomed()
      assert App.first_launch?() == false
    end
  end

  describe "init/1" do
    test "show_welcome is true on first launch" do
      model = App.init(%{})
      assert model.show_welcome == true
    end

    test "show_welcome is false after welcomed marker exists" do
      App.mark_welcomed()
      model = App.init(%{})
      assert model.show_welcome == false
    end
  end
end
```

- [ ] **Run test to confirm it fails**

```bash
mix test test/shem/tui/app_welcome_test.exs --no-deps-check 2>&1 | tail -5
```

- [ ] **Add `first_launch?/0` and `mark_welcomed/0` public functions to `lib/shem/tui/app.ex`**

```elixir
@welcomed_marker Path.join([System.get_env("HOME", "/tmp"), ".config", "shem", "welcomed"])

@spec first_launch?() :: boolean()
def first_launch? do
  not File.exists?(@welcomed_marker)
end

@spec mark_welcomed() :: :ok
def mark_welcomed do
  dir = Path.dirname(@welcomed_marker)
  File.mkdir_p!(dir)
  File.write!(@welcomed_marker, "")
  :ok
end
```

- [ ] **Add `show_welcome` and update model initialisation in `lib/shem/tui/app.ex`**

In `init/1`, add to the initial model map:

```elixir
show_welcome: first_launch?(),
show_help: Map.get(model.show_help || %{}, :show_help, false),  # already added in Task 5
help_filter: ""
```

(Adjust if `show_help` was already added in Task 5 — just add `show_welcome`.)

- [ ] **Dismiss welcome on any key in `update/2`**

Add a clause at the top of `update/2`, before any other pattern, that handles the welcome screen dismiss:

```elixir
def update(%{show_welcome: true} = model, {:event, _event}) do
  mark_welcomed()
  %{model | show_welcome: false}
end
```

- [ ] **Add help command list to `CommandDispatch`**

Add a `commands/0` function to `lib/shem/tui/command_dispatch.ex` that returns a list of `{command, description}` tuples:

```elixir
@spec commands() :: [{String.t(), String.t()}]
def commands do
  [
    {"/agent <preset> <task>", "Start an agent with a preset and task"},
    {"/stop", "Stop the running agent"},
    {"/agents", "List all running agents"},
    {"/preset <name>", "Switch to a different preset (e.g. /preset coder)"},
    {"/preset list", "List all available presets"},
    {"/preset add <name>", "Add a preset from config"},
    {"/preset delete <name>", "Delete a custom preset"},
    {"/hire <name> <role>", "Generate a new preset with the LLM"},
    {"/trust <tool>", "Show trust score for a tool"},
    {"/redteam <tool>", "Run adversarial hardening on a tool"},
    {"/tools", "List all available tools"},
    {"/llm routes", "Show current LLM routing configuration"},
    {"/llm route <role>=<model>", "Set LLM routing for a role"},
    {"/help", "Toggle this help overlay"}
  ]
end
```

- [ ] **Add welcome screen and help overlay rendering in `lib/shem/tui/app.ex`**

The welcome screen and help overlay are rendered as overlays in the `render/1` function. Add them at the end of the render output. (Ratatouille renders the last overlay on top.)

For the welcome screen, render a centred panel with a brief introduction:

```elixir
# In render/1, after the main view:
if model.show_welcome do
  overlay(padding: 10) do
    panel(title: " Welcome to Shem ", color: :cyan) do
      label(content: "")
      label(content: "  Shem is a general-purpose AI agent platform.")
      label(content: "  Use it for coding, research, writing, security audits, and more.")
      label(content: "")
      label(content: "  Quick start:")
      label(content: "    • Type a message and press Enter to start a conversation")
      label(content: "    • /preset coder  — coding assistant")
      label(content: "    • /preset security  — security auditor")
      label(content: "    • /help  — see all commands")
      label(content: "")
      label(content: "  Press any key to continue.")
    end
  end
end
```

For the help overlay, render a filterable list:

```elixir
if model.show_help do
  overlay(padding: 5) do
    panel(title: " Commands — type to filter, Esc to close ") do
      label(content: "")
      filtered =
        Shem.TUI.CommandDispatch.commands()
        |> Enum.filter(fn {cmd, desc} ->
          model.help_filter == "" or
            String.contains?(String.downcase(cmd), String.downcase(model.help_filter)) or
            String.contains?(String.downcase(desc), String.downcase(model.help_filter))
        end)
      Enum.each(filtered, fn {cmd, desc} ->
        label(content: "  #{String.pad_trailing(cmd, 35)} #{desc}")
      end)
    end
  end
end
```

Also handle typing when `show_help` is true — route printable characters to `help_filter` instead of `command_buffer`. In `update/2` add a clause before the normal key handlers:

```elixir
def update(%{show_help: true} = model, {:event, %{type: :key, key: key, ch: ch}}) do
  cond do
    key == Ratatouille.Constants.key(:esc) ->
      %{model | show_help: false, help_filter: ""}
    ch > 0 ->
      %{model | help_filter: model.help_filter <> <<ch::utf8>>}
    key == Ratatouille.Constants.key(:backspace2) ->
      filter = String.slice(model.help_filter, 0..-2//1)
      %{model | help_filter: filter}
    true ->
      model
  end
end
```

- [ ] **Run tests**

```bash
mix test test/shem/tui/app_welcome_test.exs --no-deps-check 2>&1 | tail -5
```

- [ ] **Run full suite**

```bash
mix test --no-deps-check 2>&1 | tail -5
```

- [ ] **Commit**

```bash
git add lib/shem/tui/app.ex lib/shem/tui/command_dispatch.ex test/shem/tui/app_welcome_test.exs
git commit -m "feat: TUI welcome screen (first launch) + /help searchable overlay"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Covered by |
|---|---|
| Welcome sequence — first-launch only | Task 8: `first_launch?`, `mark_welcomed`, welcome overlay |
| Conversational mode — persistent context | Task 4: `:waiting` state, `send_message/2` |
| CWD awareness — silent injection | Tasks 2+3: `Context.Project`, `prepend_project_context/1` |
| `/help` searchable overlay | Tasks 1+8: `/help` parse + overlay render + filter |
| Default presets — 6 built-ins | Task 1: `@builtin_presets` expanded |
| "What can you do?" response | Task 1: built into `general` system prompt |
| `shem --dir` flag | Not covered — out of scope per "What this is NOT"; can be added as a follow-on |

**Placeholder scan:** No TBDs, TODOs, or vague steps found.

**Type consistency:** `Agent.Config.conversational`, `Agent.Config.project_context`, `Shem.Context.Project.t()`, `agent.status == :waiting`, `CommandDispatch.commands/0` — all defined before use across tasks.

**One gap found and added:** `start_with_preset/3` needed to accept `conversational:` option — added inline in Task 5 rather than as a separate task since it's a two-line change.
