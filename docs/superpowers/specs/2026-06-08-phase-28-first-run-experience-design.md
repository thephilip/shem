# Phase 28: First-Run Experience & Conversational Mode

## Vision

Shem is a general-purpose AI agent platform — useful for coding, research, writing, security audits, brainstorming, and more. It competes with tools like Hermes and OpenClaw by doing the same things better: real concurrency, a trust/safety layer, and a full audit trail that no Python-based framework can match.

The infrastructure (BEAM supervision, trust gating, multi-agent coordination, event log) is solid through Phase 27. Phase 28 is the front door: the first thing a new user sees and does. If that experience isn't smooth and obvious, none of the impressive internals matter.

### Target user

A developer or researcher who has used an AI agent tool before (Hermes, OpenClaw, Claude Code, etc.) and wants something self-hosted (but not tied down to any particular LLM; Claude, ChatGPT, and may other models can easily be used with this tool), safer, and more capable. They arrive with curiosity, not patience. They will ask "what can you do?" before they read any documentation.

---

## The First-Run Experience

### 1. Welcome sequence

On first launch (no existing config/sessions), Shem displays a welcome screen before entering the normal TUI or Web UI. It:

- Introduces itself by name with a one-line description
- Lists the main things it can do (not exhaustively — just enough to orient)
- Suggests a first thing to try: "Try asking me about your current project, or type `/help` to see what's available"
- Does not require any setup to dismiss — pressing any key or typing enters conversational mode immediately

The welcome screen only shows on first launch. Subsequent launches go straight to the interface.

### 2. Conversational mode

Currently agents are task-runners: you give a task, they execute, they stop. Conversational mode makes the default agent persistent — it keeps context across messages in a session, responding to follow-ups naturally.

- The default agent starts in conversational mode when no task is given at launch
- Messages are sent by typing and pressing Enter (TUI) or submitting the input (Web UI)
- The agent keeps the full conversation history in its context window across turns
- The session can be named and resumed later
- Switching to a different preset mid-conversation is supported via `/preset <name>`
- Explicit task mode (current behaviour) is still available — conversational mode is the new default

### 3. CWD awareness

When Shem launches, it automatically detects and injects the working directory into the agent's context. The agent knows:

- The directory it was launched from
- The directory's name and top-level structure (a shallow `ls` on startup)
- Whether it looks like a known project type (git repo, Elixir/Mix project, Node/Python/Rust project, etc.)

This happens silently — no prompt required from the user. The agent can immediately answer "what's in this directory?" or "is this a git repo?" without being told where to look.

The user can also redirect to a different path by passing a flag at launch: `shem --dir /path/to/project`.

### 4. `/help` with searchable command list

The current `/help` command (if it exists) is replaced with a full searchable list. Pressing `/help` in the TUI opens an overlay showing:

- All available slash commands with a one-line description each
- A search input — typing filters the list in real time
- Pressing Enter on a selected command either executes it or fills it into the command buffer

The same list is available in the Web UI as a sidebar panel or modal.

### 5. Default presets

The current `general` preset is expanded into a set of built-in presets covering the main use cases. These ship with Shem and require no configuration:

| Preset       | Purpose                                                                                            |
| ------------ | -------------------------------------------------------------------------------------------------- |
| `general`    | Conversational assistant, no domain bias. The default.                                             |
| `coder`      | Code reading, writing, refactoring, debugging. Aware of common languages and patterns.             |
| `researcher` | Information synthesis, summarisation, structured note-taking. Good at "tell me about X."           |
| `writer`     | Drafting, editing, tone adjustment, structure feedback.                                            |
| `security`   | Security posture review, vulnerability identification, threat modelling. Conservative tool access. |
| `explorer`   | Codebase or filesystem exploration. Good at "what does this project do?"                           |

Users can create custom presets with `/hire <name> <role description>` (already implemented in Phase 27).

### 6. "What can you do?" response

When any agent receives a message that amounts to "what can you do?" or "help me understand what you are", it responds with a concise, friendly description of:

- What Shem is (general-purpose AI agent platform)
- What the current preset specialises in
- The key things it can do in this context (list the available tools)
- How to switch presets or get help

This is implemented as a recognised intent in the agent's system prompt, not a hardcoded route — the LLM generates the response naturally.

---

## Architecture

### Conversational mode changes

**Agent.Server:** Add a `:conversational` mode alongside the existing task-runner mode. In conversational mode:

- `max_turns` is effectively unlimited (or very high — 100)
- The agent does not terminate on producing a final answer — it returns to a waiting state
- A new event type `:user_message` is added to the event log for user inputs in conversation
- The TUI/Web UI input feeds into `Agent.Server.send_message/2` rather than launching a new agent

**TUI App:** The main input field (currently the task textarea) becomes a chat input in conversational mode. Pressing Enter sends the message. Previous turns are shown in the output panel as a conversation thread, not a flat stream.

**Web UI:** Same pattern — the task textarea becomes a persistent chat input. Output panel shows the conversation history with clear user/agent turn demarcation.

### CWD injection

A new module `Shem.Context.Project` runs at startup:

- Detects `File.cwd!()`
- Runs a shallow directory listing
- Detects project type from marker files (`mix.exs`, `package.json`, `Cargo.toml`, `pyproject.toml`, `.git`, etc.)
- Returns a `%ProjectContext{}` struct

The project context is injected into every agent's system prompt as a preamble:

```
You are running in: /home/user/my-project
Project type: Elixir/Mix (git repo, 47 files)
Working directory contents: lib/, test/, mix.exs, README.md, ...
```

### Welcome screen

A new TUI view `Shem.TUI.WelcomeView` shown on first launch. First-launch detection: check for the absence of any sessions in the event log and any presets in the preset store. Once dismissed, a marker is written to `~/.config/shem/welcomed` so it never shows again.

### `/help` overlay

A new TUI component `Shem.TUI.HelpOverlay` rendered on top of the main view when `/help` is entered. Built with Ratatouille's overlay support. The command list is derived from `CommandDispatch` at runtime — no hardcoded list.

---

## What this is NOT

- This phase does not add new agent capabilities or tools
- This phase does not change the trust system or event log
- This phase does not add the Timeline Viewer (Phase 32)
- This phase does not change the install story (Phase 29)

---

## Success criteria

A new user can:

1. Launch Shem cold and immediately understand what it is
2. Ask "what can you do?" and get a useful answer
3. Ask about the contents of their current directory without any setup
4. Find any command via `/help` in under 5 seconds
5. Have a multi-turn conversation without relaunching the agent between messages
6. Switch to a specialist preset (`/preset coder`, `/preset security`) and immediately notice the difference in responses
