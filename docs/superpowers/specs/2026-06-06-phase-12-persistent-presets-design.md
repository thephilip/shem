# Phase 12: Persistent User-Defined Presets — Design

## Goal

Make agent presets first-class, user-configurable objects. The three hardcoded presets (`general`, `coding`, `explore`) are a hard ceiling for Shem as a daily driver. Phase 12 adds a DETS-backed preset store, config-file loading for version-controlled presets, and a multiline TUI input mode that makes `/preset add` usable for real system prompts.

## Scope

- `Preset.Store` — DETS-backed GenServer for user-defined presets
- Config loading — optional `config/user_presets.exs` for static presets
- Updated `Preset.resolve/1` and `Preset.all/0` — three-layer resolution with `:source` annotation
- `CommandDispatch` — `/preset list`, `/preset add <name>`, `/preset delete <name>`
- `App` — `:multiline_input` mode, handlers for all three preset commands
- Interactive view — multiline input rendering

## Architecture

### Three-layer resolution

Preset resolution checks layers in order, first match wins:

| Layer | Source | Deletable from TUI |
|---|---|---|
| `:builtin` | Hardcoded in `Preset` module | No |
| `:config` | `Application.get_env(:shem, :user_presets, [])` | No |
| `:dynamic` | `Preset.Store` (DETS) | Yes |

Built-ins cannot be shadowed — if a config or dynamic preset shares a name with a built-in, the built-in wins. This prevents accidental override of known-good presets.

`Preset.all/0` returns all three layers as a flat list of maps, each annotated with `source: :builtin | :config | :dynamic`. Used by `/preset list` and by the TUI to determine deletability.

### Preset shape

```elixir
%{
  name: String.t(),
  system_prompt: String.t(),
  tools: :all | [String.t()]
}
```

The `:source` field is added at read time — it is not stored in DETS.

## Components

### `lib/shem/application.ex`

`Preset.Store` must be added to the supervision tree alongside `Trust.Store`. No other changes.

### `lib/shem/agent/preset_store.ex`

New DETS-backed GenServer. Mirrors `Trust.Store` structurally.

```elixir
@spec put(String.t(), map()) :: :ok
def put(name, preset)

@spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
def get(name)

@spec delete(String.t()) :: :ok | {:error, :not_found}
def delete(name)

@spec all() :: %{String.t() => map()}
def all()
```

DETS table stored at `priv/preset_store.dets`. Keyed by preset name (string).

### `lib/shem/agent/preset.ex`

Updated `resolve/1` and `all/0`.

**`resolve/1`** — walks built-ins → config → dynamic. Returns `{:ok, %{system_prompt:, tools:}}` or `{:error, :not_found}`.

**`all/0`** — returns:
```elixir
[
  %{name: "general", system_prompt: "...", tools: :all, source: :builtin},
  %{name: "reviewer", system_prompt: "...", tools: [...], source: :config},
  %{name: "my_preset", system_prompt: "...", tools: :all, source: :dynamic},
  ...
]
```

### `config/config.exs`

Add at the bottom:

```elixir
if File.exists?("config/user_presets.exs"), do: import_config("user_presets.exs")
```

### `config/user_presets.exs` (optional, gitignored)

User-authored file, not committed:

```elixir
import Config

config :shem, :user_presets, [
  %{
    name: "reviewer",
    system_prompt: "You are a careful code reviewer...",
    tools: ["read_file", "list_dir", "shell"]
  }
]
```

### `lib/shem/tui/command_dispatch.ex`

New parse results added to the spec:

| Input | Result |
|---|---|
| `/preset list` | `{:preset_list}` |
| `/preset add <name>` | `{:preset_add, name}` |
| `/preset delete <name>` | `{:preset_delete, name}` |
| `/preset` | `{:error, "usage: /preset <list\|add\|delete> ..."}` |

### `lib/shem/tui/app.ex`

**New model fields:**

```elixir
multiline_buffer: [],    # [String.t()] — lines collected so far
multiline_target: nil,   # {:preset_add, String.t()} | nil
```

**New mode:** `:multiline_input`

The App has three modes: `:dashboard`, `:interactive`, `:multiline_input`. The `:multiline_input` mode is entered from `:interactive` only and always returns to `:interactive`.

**Multiline mode key handling:**

| Event | Action |
|---|---|
| `Enter` (buffer ≠ `"/done"`) | Append `command_buffer` to `multiline_buffer`, clear `command_buffer` |
| `Enter` (buffer == `"/done"`) | Submit: join `multiline_buffer` with `"\n"`, dispatch to `multiline_target`, clear multiline state, return to `:interactive` |
| `Escape` | Cancel: clear `multiline_buffer`, `multiline_target`, `command_buffer`, return to `:interactive` |
| Typing | Same as normal: appends char to `command_buffer` |
| Backspace | Same as normal: removes last char from `command_buffer` |

**Command handlers:**

- `{:preset_list}` — calls `Preset.all/0`, formats as multiline string, sets `command_output`
- `{:preset_add, name}` — switches mode to `:multiline_input`, sets `multiline_target: {:preset_add, name}`, clears `command_buffer`/`command_error`
- `{:preset_delete, name}` — calls `Preset.all/0` to find preset; if `:source` is `:builtin` or `:config`, sets `command_error: "cannot delete built-in or config preset"`; if `:dynamic`, calls `Preset.Store.delete/1`; if not found, sets `command_error`

**On multiline submit** (`{:preset_add, name}`):
- Calls `Preset.Store.put(name, %{system_prompt: text, tools: :all})`
- Sets `command_output: "preset '#{name}' saved"`, clears multiline state, returns to `:interactive`

### `lib/shem/tui/views/interactive.ex`

New `render/1` clause for `:multiline_input` mode — renders in place of the normal interactive view:

```elixir
def render(%{mode: :multiline_input} = model) do
  # panel showing collected lines so far
  # label showing hint: "Type lines. Enter '/done' to submit, Esc to cancel."
  # current command_buffer as the active input line
end
```

The multiline panel title includes the preset name: `"Shem // New Preset · #{name}"`.

## Files

| Action | File |
|---|---|
| Create | `lib/shem/agent/preset_store.ex` |
| Create | `test/shem/agent/preset_store_test.exs` |
| Modify | `lib/shem/agent/preset.ex` |
| Modify | `test/shem/agent/preset_test.exs` |
| Modify | `config/config.exs` |
| Modify | `lib/shem/tui/command_dispatch.ex` |
| Modify | `test/shem/tui/command_dispatch_test.exs` |
| Modify | `lib/shem/tui/app.ex` |
| Modify | `test/shem/tui/app_test.exs` |
| Modify | `lib/shem/tui/views/interactive.ex` |
| Modify | `test/shem/tui/views/interactive_test.exs` |
| Modify | `lib/shem/application.ex` |

## Tests

- `test/shem/agent/preset_store_test.exs` — `put/get/delete/all`; `get` on unknown returns `{:error, :not_found}`; `delete` on unknown returns `{:error, :not_found}`; `all/0` returns a map
- `test/shem/agent/preset_test.exs` — `resolve/1` finds built-ins; falls through to dynamic layer; returns `{:error, :not_found}` for unknown; `all/0` annotates `:source` correctly for each layer; built-in wins over same-named dynamic preset
- `test/shem/tui/command_dispatch_test.exs` — `/preset list`, `/preset add name`, `/preset delete name`, `/preset` with no subcommand
- `test/shem/tui/app_test.exs` — `{:preset_add, name}` enters `:multiline_input` mode; `Enter` appends line; `/done` submits, saves preset, returns to `:interactive`; `Escape` cancels and returns to `:interactive`; `{:preset_list}` sets `command_output`; `{:preset_delete}` on dynamic preset succeeds; `{:preset_delete}` on built-in sets `command_error`
- `test/shem/tui/views/interactive_test.exs` — `:multiline_input` mode renders collected lines and hint text; normal interactive mode unaffected

## Non-goals

- No tool allowlist editor in the TUI — tools field defaults to `:all` for TUI-created presets; config presets can specify allowlists
- No preset editing (only add/delete) — delete and re-add
- No per-preset trust gating — the existing trust gate operates at tool dispatch, independent of which preset is active
- No preset export/import
