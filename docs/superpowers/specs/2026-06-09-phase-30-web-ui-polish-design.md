# Phase 30: Web UI Polish

**Date:** 2026-06-09
**Status:** Approved for implementation

## Overview

Bring the Web UI to parity with the TUI for preset management. Streaming and conversational mode are already fully wired (Phase 26 + 28). The remaining gap: the preset list is hardcoded in `app.js` and there is no way to create or delete presets from the browser.

This phase adds `POST /api/presets` and `DELETE /api/presets/:name` to the REST API, updates `GET /api/presets` to include a `deletable` flag, and wires dynamic preset loading + a modal preset manager into the Web UI.

---

## Backend

### `GET /api/presets` — add `deletable` field

`Preset.all/0` already tags each preset with `:source` (`:builtin`, `:config`, or `:dynamic`). The response gains one new field:

```json
[
  { "name": "general", "description": "...", "deletable": false },
  { "name": "my-preset", "description": "...", "deletable": true }
]
```

`deletable` is `true` only when `source == :dynamic`. Built-in (`:builtin`) and config-file (`:config`) presets return `false`.

### `POST /api/presets`

Request body: `{"name": "...", "system_prompt": "..."}`

- 201 + preset object on success
- 422 + `{"error": "name and system_prompt are required"}` if either field is missing or blank
- 409 + `{"error": "preset already exists: <name>"}` if the name already exists in `PresetStore` or as a built-in

Creates via `Shem.Agent.PresetStore.put/2`. The response body matches the `GET` format:

```json
{ "name": "my-preset", "description": "...", "deletable": true }
```

### `DELETE /api/presets/:name`

- 204 (no body) on success
- 404 + `{"error": "preset not found: <name>"}` if name does not exist
- 403 + `{"error": "cannot delete built-in preset: <name>"}` if `source` is `:builtin` or `:config`

Implementation: call `Shem.Agent.Preset.all/0`, find the preset by name. If not found → 404. If found with `source: :builtin` or `source: :config` → 403. If found with `source: :dynamic` → `PresetStore.delete/1` → 204.

---

## Frontend

### `app.js` changes

**Preset data shape change:** `presets` array changes from `['general', ...]` to `[{name, description, deletable}, ...]`. The `preset` model field (currently bound to the select) stays as a name string — it is set to `p.name` on selection.

**Dynamic loading:** `init()` calls `GET /api/presets` and populates `this.presets`. On error, falls back to a hardcoded `['general']` so the UI is never completely broken.

**New state fields:**

```js
showPresetModal: false,
newPresetName: '',
newPresetPrompt: '',
createError: '',
creating: false,
```

**New methods:**

`openPresetModal()` — sets `showPresetModal = true`, clears create form fields and errors.

`closePresetModal()` — sets `showPresetModal = false`.

`createPreset()` — POSTs to `/api/presets` with `{name: this.newPresetName, system_prompt: this.newPresetPrompt}`. On 201: adds the new preset to `this.presets`, resets form, focuses the new preset. On error: sets `this.createError` to the response error message.

`deletePreset(name)` — sends `DELETE /api/presets/:name`. On 204: removes the preset from `this.presets`. If the deleted preset was the active `this.preset`, switches to `'general'`.

**Preset selector binding:** The `<select>` binds to `this.preset` (a name string). Each `<option>` uses `p.name` as value and text.

### `index.html` changes

**Sidebar:** Add a "Manage Presets" button below the preset selector. Calls `openPresetModal()`.

**Modal:** Overlays the full page with a semi-transparent backdrop. Clicking the backdrop calls `closePresetModal()`. The modal panel (centered, max-width 520px) contains:

1. Header: "Presets" title + X close button
2. Preset list: each row shows `name` (bold) and `description` (truncated, muted). Rows where `deletable` is true show a delete icon button on the right. Built-in presets show no delete button.
3. Divider
4. Create form: "Name" text input + "System Prompt" textarea (8 rows, full width, monospace). Error text in red if `createError` is set. "Save Preset" button (disabled while `creating`).

**CSS additions:** Modal backdrop (`position: fixed; inset: 0; background: rgba(0,0,0,0.6)`), modal panel (white-on-dark card, same `--surface` background, `--border` border, `border-radius: 8px`), delete icon button (small, red on hover), create form inputs (same style as existing `select` and `textarea.chat-input`).

No new libraries. Alpine.js handles all reactivity.

---

## Testing

### REST (automated)

`test/shem/rest/presets_test.exs` additions:

**`GET /presets`:**
- Returns `deletable: false` for built-in presets
- Returns `deletable: true` for a dynamically created preset

**`POST /presets`:**
- Returns 201 with preset object on valid input
- Returns 422 when name is missing
- Returns 422 when system_prompt is missing
- Returns 422 when name is blank string
- Returns 409 when name already exists

**`DELETE /presets/:name`:**
- Returns 204 and removes the preset
- Returns 404 for unknown name
- Returns 403 for a built-in preset name (e.g. "general")

### Frontend (manual checklist)

- [ ] Preset list loads dynamically on page load (includes user-created presets from TUI)
- [ ] Built-in presets show no delete button
- [ ] User-created presets show a delete button
- [ ] Creating a preset via form: appears in the list and in the selector
- [ ] Deleting the active preset: selector switches to "general"
- [ ] Create form rejects blank name or prompt with an error message
- [ ] Duplicate name shows 409 error inline in the form
- [ ] Modal closes on backdrop click and X button

---

## What this phase does NOT include

- `/hire` flow in the Web UI (LLM-generated presets from a role description — future phase)
- Preset editing (modify an existing preset's system prompt — future phase)
- Web UI kill button or `/fence` support (TUI-only for Phase 34)
