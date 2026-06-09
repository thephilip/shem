# Phase 30: Web UI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add full preset management to the Web UI — dynamic loading, create, and delete — backed by new `POST` and `DELETE` REST endpoints.

**Architecture:** Three backend changes to `lib/shem/rest/handlers/presets.ex` (add `deletable` to GET, add POST, add DELETE), then two frontend changes to `priv/static/app.js` and `priv/static/index.html`. Backend is tested with existing Plug.Test patterns; frontend is verified manually against the checklist in the spec.

**Tech Stack:** Elixir/Plug REST handlers, Alpine.js, vanilla CSS. No new dependencies.

---

## File map

| File | Action | Purpose |
|------|--------|---------|
| `lib/shem/rest/handlers/presets.ex` | Modify | Add `deletable` to GET; add POST and DELETE handlers |
| `test/shem/rest/presets_test.exs` | Modify | Tests for all three endpoints |
| `priv/static/app.js` | Modify | Dynamic preset loading; modal state; `createPreset`, `deletePreset` |
| `priv/static/index.html` | Modify | "Manage Presets" button; modal overlay with list and create form |

---

### Task 1: Update `GET /api/presets` to include `deletable`

**Files:**
- Modify: `lib/shem/rest/handlers/presets.ex`
- Modify: `test/shem/rest/presets_test.exs`

The existing `GET /` handler maps presets to `%{name, description}`. This task adds `deletable: source == :dynamic`.

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/rest/presets_test.exs` (after the existing tests):

```elixir
describe "GET /presets — deletable field" do
  test "built-in presets have deletable: false" do
    conn = conn(:get, "/presets") |> Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    general = Enum.find(body, &(&1["name"] == "general"))
    assert general != nil
    assert general["deletable"] == false
  end

  test "user-created presets have deletable: true" do
    Shem.Agent.PresetStore.put("test-preset-get", %{
      name: "test-preset-get",
      system_prompt: "Test prompt"
    })
    on_exit(fn -> Shem.Agent.PresetStore.delete("test-preset-get") end)

    conn = conn(:get, "/presets") |> Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    preset = Enum.find(body, &(&1["name"] == "test-preset-get"))
    assert preset != nil
    assert preset["deletable"] == true
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/rest/presets_test.exs
```

Expected: new tests fail with `assert nil != nil` (no `deletable` key in response).

- [ ] **Step 3: Update the GET handler**

Replace the entire `get "/"` block in `lib/shem/rest/handlers/presets.ex`:

```elixir
get "/" do
  presets =
    Shem.Agent.Preset.all()
    |> Enum.map(fn p ->
      %{
        name: p.name,
        description: p.system_prompt,
        deletable: p.source == :dynamic
      }
    end)

  send_json(conn, 200, presets)
end
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
mix test test/shem/rest/presets_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Run the full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/rest/handlers/presets.ex test/shem/rest/presets_test.exs
git commit -m "feat: add deletable field to GET /api/presets"
```

---

### Task 2: Add `POST /api/presets`

**Files:**
- Modify: `lib/shem/rest/handlers/presets.ex`
- Modify: `test/shem/rest/presets_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/rest/presets_test.exs`:

```elixir
describe "POST /presets" do
  setup do
    on_exit(fn ->
      Shem.Agent.PresetStore.delete("new-preset")
      Shem.Agent.PresetStore.delete("dupe-preset")
    end)
    :ok
  end

  test "returns 201 with preset object on valid input" do
    conn =
      conn(:post, "/presets", Jason.encode!(%{name: "new-preset", system_prompt: "Be helpful."}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["name"] == "new-preset"
    assert body["description"] == "Be helpful."
    assert body["deletable"] == true
  end

  test "returns 422 when name is missing" do
    conn =
      conn(:post, "/presets", Jason.encode!(%{system_prompt: "Be helpful."}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"] =~ "required"
  end

  test "returns 422 when system_prompt is missing" do
    conn =
      conn(:post, "/presets", Jason.encode!(%{name: "new-preset"}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"] =~ "required"
  end

  test "returns 422 when name is blank" do
    conn =
      conn(:post, "/presets", Jason.encode!(%{name: "  ", system_prompt: "Be helpful."}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"] =~ "required"
  end

  test "returns 409 when name already exists as a built-in" do
    conn =
      conn(:post, "/presets", Jason.encode!(%{name: "general", system_prompt: "Override."}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 409
    assert Jason.decode!(conn.resp_body)["error"] =~ "already exists"
  end

  test "returns 409 when name already exists as a user preset" do
    Shem.Agent.PresetStore.put("dupe-preset", %{name: "dupe-preset", system_prompt: "First."})

    conn =
      conn(:post, "/presets", Jason.encode!(%{name: "dupe-preset", system_prompt: "Second."}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 409
    assert Jason.decode!(conn.resp_body)["error"] =~ "already exists"
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/rest/presets_test.exs
```

Expected: POST tests fail with 404 (route not matched yet).

- [ ] **Step 3: Add the POST handler**

In `lib/shem/rest/handlers/presets.ex`, add after the `get "/"` block:

```elixir
post "/" do
  name   = String.trim(conn.body_params["name"] || "")
  prompt = String.trim(conn.body_params["system_prompt"] || "")

  cond do
    name == "" or prompt == "" ->
      send_json(conn, 422, %{error: "name and system_prompt are required"})

    Enum.any?(Shem.Agent.Preset.all(), &(&1.name == name)) ->
      send_json(conn, 409, %{error: "preset already exists: #{name}"})

    true ->
      Shem.Agent.PresetStore.put(name, %{name: name, system_prompt: prompt})
      send_json(conn, 201, %{name: name, description: prompt, deletable: true})
  end
end
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
mix test test/shem/rest/presets_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Run the full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/rest/handlers/presets.ex test/shem/rest/presets_test.exs
git commit -m "feat: add POST /api/presets — create user preset"
```

---

### Task 3: Add `DELETE /api/presets/:name`

**Files:**
- Modify: `lib/shem/rest/handlers/presets.ex`
- Modify: `test/shem/rest/presets_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/rest/presets_test.exs`:

```elixir
describe "DELETE /presets/:name" do
  setup do
    Shem.Agent.PresetStore.put("deletable-preset", %{
      name: "deletable-preset",
      system_prompt: "Delete me."
    })
    on_exit(fn -> Shem.Agent.PresetStore.delete("deletable-preset") end)
    :ok
  end

  test "returns 204 and removes the preset" do
    conn =
      conn(:delete, "/presets/deletable-preset")
      |> Router.call(@opts)

    assert conn.status == 204
    assert conn.resp_body == ""

    # verify it's gone
    conn2 = conn(:get, "/presets") |> Router.call(@opts)
    body = Jason.decode!(conn2.resp_body)
    refute Enum.any?(body, &(&1["name"] == "deletable-preset"))
  end

  test "returns 404 for unknown preset name" do
    conn =
      conn(:delete, "/presets/no-such-preset-#{System.unique_integer([:positive])}")
      |> Router.call(@opts)

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] =~ "not found"
  end

  test "returns 403 for built-in preset" do
    conn =
      conn(:delete, "/presets/general")
      |> Router.call(@opts)

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"] =~ "cannot delete"
  end

  test "returns 403 for explorer built-in preset" do
    conn =
      conn(:delete, "/presets/explorer")
      |> Router.call(@opts)

    assert conn.status == 403
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/rest/presets_test.exs
```

Expected: DELETE tests fail with 404 (route not matched yet).

- [ ] **Step 3: Add the DELETE handler**

In `lib/shem/rest/handlers/presets.ex`, add after the `post "/"` block and before the `match _` catch-all:

```elixir
delete "/:name" do
  all = Shem.Agent.Preset.all()

  case Enum.find(all, &(&1.name == name)) do
    nil ->
      send_json(conn, 404, %{error: "preset not found: #{name}"})

    %{source: source} when source in [:builtin, :config] ->
      send_json(conn, 403, %{error: "cannot delete built-in preset: #{name}"})

    %{source: :dynamic} ->
      Shem.Agent.PresetStore.delete(name)
      send_resp(conn, 204, "")
  end
end
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
mix test test/shem/rest/presets_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Run the full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/rest/handlers/presets.ex test/shem/rest/presets_test.exs
git commit -m "feat: add DELETE /api/presets/:name — remove user preset"
```

---

### Task 4: Update `app.js` — dynamic loading, modal state, create/delete

**Files:**
- Modify: `priv/static/app.js`

This task replaces the hardcoded preset array with dynamic loading and adds the modal + preset management methods. No tests — verified manually against the checklist at the end of this plan.

- [ ] **Step 1: Replace `priv/static/app.js` entirely**

```js
function shem() {
  return {
    // chat state
    preset: 'general',
    presets: [],              // [{name, description, deletable}]
    messages: [],
    inputText: '',
    status: 'idle',
    errorMsg: '',
    agentId: null,
    pendingContent: '',

    // preset modal state
    showPresetModal: false,
    newPresetName: '',
    newPresetPrompt: '',
    createError: '',
    creating: false,

    async init() {
      await this._loadPresets();
    },

    async _loadPresets() {
      try {
        const res = await fetch('/api/presets');
        if (!res.ok) throw new Error();
        this.presets = await res.json();
        // ensure current preset is still valid
        if (!this.presets.find(p => p.name === this.preset)) {
          this.preset = 'general';
        }
      } catch (_) {
        // fallback so the UI is never broken
        this.presets = [{ name: 'general', description: 'General assistant.', deletable: false }];
      }
    },

    openPresetModal() {
      this.newPresetName = '';
      this.newPresetPrompt = '';
      this.createError = '';
      this.creating = false;
      this.showPresetModal = true;
    },

    closePresetModal() {
      this.showPresetModal = false;
    },

    async createPreset() {
      const name   = this.newPresetName.trim();
      const prompt = this.newPresetPrompt.trim();
      if (!name || !prompt) {
        this.createError = 'Name and system prompt are required.';
        return;
      }
      this.creating = true;
      this.createError = '';
      try {
        const res = await fetch('/api/presets', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name, system_prompt: prompt })
        });
        const data = await res.json();
        if (!res.ok) {
          this.createError = data.error || 'Failed to create preset.';
          return;
        }
        this.presets.push(data);
        this.preset = data.name;
        this.newPresetName = '';
        this.newPresetPrompt = '';
      } catch (_) {
        this.createError = 'Network error.';
      } finally {
        this.creating = false;
      }
    },

    async deletePreset(name) {
      try {
        const res = await fetch(`/api/presets/${encodeURIComponent(name)}`, { method: 'DELETE' });
        if (!res.ok) return;
        this.presets = this.presets.filter(p => p.name !== name);
        if (this.preset === name) this.preset = 'general';
      } catch (_) {}
    },

    async send() {
      const text = this.inputText.trim();
      if (!text || this.status === 'running') return;
      this.inputText = '';
      this.errorMsg = '';

      if (this.status === 'idle') {
        await this._startAgent(text);
      } else if (this.status === 'waiting') {
        await this._sendMessage(text);
      }
    },

    async _startAgent(text) {
      this.messages.push({ role: 'user', content: text, pending: false });
      this.messages.push({ role: 'assistant', content: '', pending: true });
      this.status = 'running';

      try {
        const res = await fetch('/api/agents', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ preset: this.preset, task: text, conversational: true })
        });
        if (!res.ok) throw new Error('Failed to start agent');
        const data = await res.json();
        this.agentId = data.agent_id;
        await this._openStream(this.agentId);
      } catch (e) {
        this.errorMsg = e.message;
        this.status = 'error';
        this.messages[this.messages.length - 1].pending = false;
      }
    },

    async _sendMessage(text) {
      this.messages.push({ role: 'user', content: text, pending: false });
      this.messages.push({ role: 'assistant', content: '', pending: true });
      this.status = 'running';

      try {
        const res = await fetch(`/api/agents/${this.agentId}/message`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ message: text })
        });
        if (!res.ok) throw new Error('Failed to send message');
        await this._openStream(this.agentId);
      } catch (e) {
        this.errorMsg = e.message;
        this.status = 'error';
        this.messages[this.messages.length - 1].pending = false;
      }
    },

    async _openStream(agentId) {
      this.pendingContent = '';
      const es = new EventSource(`/api/agents/${agentId}/stream`);

      es.onmessage = (e) => {
        const msg = JSON.parse(e.data);
        if (msg.type === 'chunk') {
          this.pendingContent += msg.content;
          const last = this.messages[this.messages.length - 1];
          if (last && last.pending) last.content = this.pendingContent;
          this.$nextTick(() => {
            const el = this.$refs.chatBody;
            if (el) el.scrollTop = el.scrollHeight;
          });
        } else if (msg.type === 'done') {
          es.close();
          const last = this.messages[this.messages.length - 1];
          if (last) last.pending = false;
          this.status = msg.status === 'error' ? 'error' : 'waiting';
          this.pendingContent = '';
        }
      };

      es.onerror = () => {
        es.close();
        const last = this.messages[this.messages.length - 1];
        if (last) last.pending = false;
        if (this.status === 'running') {
          this.status = 'error';
          this.errorMsg = 'Connection lost.';
        }
      };
    },

    newChat() {
      this.messages = [];
      this.agentId = null;
      this.status = 'idle';
      this.inputText = '';
      this.errorMsg = '';
      this.pendingContent = '';
    }
  };
}
```

- [ ] **Step 2: Verify syntax**

```bash
node --check priv/static/app.js && echo "JS syntax OK"
```

Expected: `JS syntax OK`

- [ ] **Step 3: Commit**

```bash
git add priv/static/app.js
git commit -m "feat: dynamic preset loading and preset modal state in app.js"
```

---

### Task 5: Update `index.html` — modal UI

**Files:**
- Modify: `priv/static/index.html`

- [ ] **Step 1: Replace `priv/static/index.html` entirely**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Shem</title>
  <script src="/app.js" defer></script>
  <script src="/alpine.min.js" defer></script>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --bg:      #0f0f1a;
      --surface: #1a1a2e;
      --border:  #2a2a4a;
      --accent:  #7c6af7;
      --text:    #e0e0f0;
      --muted:   #666688;
      --green:   #8be9a0;
      --red:     #ff6b6b;
      --user-bg: #1e1e3a;
      --ai-bg:   #141428;
    }

    html, body { height: 100%; background: var(--bg); color: var(--text);
      font-family: 'JetBrains Mono', 'Fira Code', monospace; font-size: 14px; }

    .layout { display: flex; height: 100vh; }

    /* Sidebar */
    .sidebar {
      width: 240px; flex-shrink: 0;
      background: var(--surface); border-right: 1px solid var(--border);
      padding: 20px 16px; display: flex; flex-direction: column; gap: 16px;
    }
    .logo { font-size: 16px; font-weight: 700; color: var(--accent);
      letter-spacing: 2px; text-transform: uppercase;
      padding-bottom: 12px; border-bottom: 1px solid var(--border); }
    .field { display: flex; flex-direction: column; gap: 6px; }
    .field label { font-size: 11px; color: var(--muted); letter-spacing: 1px; text-transform: uppercase; }
    select { background: var(--bg); border: 1px solid var(--border); border-radius: 4px;
      color: var(--text); font-family: inherit; font-size: 13px; padding: 8px 10px;
      outline: none; transition: border-color 0.15s; }
    select:focus { border-color: var(--accent); }
    .btn { padding: 9px 12px; border-radius: 4px; border: none; font-family: inherit;
      font-size: 12px; cursor: pointer; transition: opacity 0.15s; width: 100%; }
    .btn:disabled { opacity: 0.4; cursor: not-allowed; }
    .btn-outline { background: transparent; border: 1px solid var(--border); color: var(--muted); }
    .btn-outline:not(:disabled):hover { border-color: var(--accent); color: var(--accent); }

    /* Chat area */
    .chat { flex: 1; display: flex; flex-direction: column; overflow: hidden; }

    .chat-body { flex: 1; overflow-y: auto; padding: 24px 20px; display: flex;
      flex-direction: column; gap: 16px; }

    .msg { display: flex; flex-direction: column; gap: 4px; max-width: 80%; }
    .msg-user { align-self: flex-end; align-items: flex-end; }
    .msg-assistant { align-self: flex-start; align-items: flex-start; }

    .msg-label { font-size: 10px; color: var(--muted); letter-spacing: 1px;
      text-transform: uppercase; }

    .msg-bubble { padding: 10px 14px; border-radius: 8px; line-height: 1.6;
      font-size: 13px; white-space: pre-wrap; word-break: break-word; }
    .msg-user .msg-bubble { background: var(--user-bg); border: 1px solid var(--border); }
    .msg-assistant .msg-bubble { background: var(--ai-bg); border: 1px solid var(--border); }
    .msg-bubble.error { border-color: var(--red); color: var(--red); }

    .cursor { color: var(--accent); animation: blink 1s step-end infinite; }
    @keyframes blink { 50% { opacity: 0; } }

    .placeholder { color: var(--muted); font-style: italic; align-self: center;
      margin-top: 40px; }

    /* Input row */
    .chat-input-row {
      padding: 14px 16px; border-top: 1px solid var(--border);
      background: var(--surface); display: flex; gap: 10px; align-items: flex-end;
    }
    textarea.chat-input {
      flex: 1; background: var(--bg); border: 1px solid var(--border);
      border-radius: 6px; color: var(--text); font-family: inherit; font-size: 13px;
      padding: 10px 12px; outline: none; resize: none; line-height: 1.5;
      min-height: 42px; max-height: 200px; transition: border-color 0.15s;
    }
    textarea.chat-input:focus { border-color: var(--accent); }
    .btn-send { background: var(--accent); color: #fff; border: none;
      border-radius: 6px; padding: 10px 18px; font-family: inherit; font-size: 13px;
      cursor: pointer; transition: opacity 0.15s; white-space: nowrap; flex-shrink: 0; }
    .btn-send:disabled { opacity: 0.4; cursor: not-allowed; }
    .btn-send:not(:disabled):hover { opacity: 0.85; }

    .error-bar { padding: 8px 16px; background: #4a2a2a; color: var(--red);
      font-size: 12px; flex-shrink: 0; }

    /* Status indicator */
    .status-dot { width: 6px; height: 6px; border-radius: 50%; display: inline-block; margin-right: 6px; }
    .dot-running { background: var(--accent); animation: pulse 1.5s ease-in-out infinite; }
    .dot-waiting { background: var(--green); }
    .dot-error   { background: var(--red); }
    @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.3; } }

    /* Preset modal */
    .modal-backdrop {
      position: fixed; inset: 0; background: rgba(0,0,0,0.65);
      display: flex; align-items: center; justify-content: center; z-index: 100;
    }
    .modal-panel {
      background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
      width: 100%; max-width: 520px; max-height: 80vh;
      display: flex; flex-direction: column; overflow: hidden;
    }
    .modal-header {
      display: flex; align-items: center; justify-content: space-between;
      padding: 16px 20px; border-bottom: 1px solid var(--border);
      font-size: 13px; font-weight: 700; letter-spacing: 1px; text-transform: uppercase;
      color: var(--accent);
    }
    .modal-close {
      background: none; border: none; color: var(--muted); font-size: 18px;
      cursor: pointer; line-height: 1; padding: 0 4px;
    }
    .modal-close:hover { color: var(--text); }
    .modal-body { flex: 1; overflow-y: auto; padding: 16px 20px; display: flex; flex-direction: column; gap: 12px; }
    .modal-footer { padding: 16px 20px; border-top: 1px solid var(--border); }

    .preset-row {
      display: flex; align-items: center; justify-content: space-between;
      padding: 8px 10px; border-radius: 4px; border: 1px solid var(--border);
    }
    .preset-row:hover { border-color: var(--accent); }
    .preset-info { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
    .preset-name { font-size: 13px; font-weight: 600; color: var(--text); }
    .preset-desc { font-size: 11px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 360px; }
    .btn-delete {
      background: none; border: 1px solid transparent; border-radius: 4px;
      color: var(--muted); font-size: 14px; cursor: pointer; padding: 4px 8px; flex-shrink: 0;
    }
    .btn-delete:hover { border-color: var(--red); color: var(--red); }

    .modal-divider { border: none; border-top: 1px solid var(--border); margin: 4px 0; }

    .form-group { display: flex; flex-direction: column; gap: 6px; }
    .form-label { font-size: 11px; color: var(--muted); letter-spacing: 1px; text-transform: uppercase; }
    .form-input {
      background: var(--bg); border: 1px solid var(--border); border-radius: 4px;
      color: var(--text); font-family: inherit; font-size: 13px; padding: 8px 10px;
      outline: none; transition: border-color 0.15s; width: 100%;
    }
    .form-input:focus { border-color: var(--accent); }
    textarea.form-input { resize: vertical; min-height: 140px; line-height: 1.5; }
    .form-error { font-size: 12px; color: var(--red); }

    .btn-primary {
      background: var(--accent); color: #fff; border: none; border-radius: 4px;
      padding: 9px 16px; font-family: inherit; font-size: 12px; cursor: pointer;
      transition: opacity 0.15s; width: 100%;
    }
    .btn-primary:disabled { opacity: 0.4; cursor: not-allowed; }
    .btn-primary:not(:disabled):hover { opacity: 0.85; }
  </style>
</head>
<body x-data="shem()" x-init="init()">
  <div class="layout">
    <aside class="sidebar">
      <div class="logo">⬡ shem</div>

      <div class="field">
        <label>Preset</label>
        <select x-model="preset" :disabled="status === 'running'">
          <template x-for="p in presets" :key="p.name">
            <option :value="p.name" x-text="p.name"></option>
          </template>
        </select>
      </div>

      <button class="btn btn-outline" @click="openPresetModal()">
        Manage Presets
      </button>

      <div style="flex: 1"></div>

      <button class="btn btn-outline" @click="newChat()" :disabled="status === 'running'">
        New Chat
      </button>

      <div x-show="status !== 'idle'" style="display:flex;align-items:center;font-size:11px;color:var(--muted)">
        <span class="status-dot"
          :class="{'dot-running': status==='running', 'dot-waiting': status==='waiting', 'dot-error': status==='error'}">
        </span>
        <span x-text="status"></span>
      </div>
    </aside>

    <main class="chat">
      <div class="chat-body" x-ref="chatBody">
        <span class="placeholder" x-show="messages.length === 0">
          Start a conversation — type anything below.
        </span>

        <template x-for="(msg, i) in messages" :key="i">
          <div class="msg" :class="msg.role === 'user' ? 'msg-user' : 'msg-assistant'">
            <span class="msg-label" x-text="msg.role === 'user' ? 'you' : 'shem'"></span>
            <div class="msg-bubble" :class="{error: msg.error}">
              <span x-text="msg.content"></span><span
                class="cursor"
                x-show="msg.pending && status === 'running'">▌</span>
            </div>
          </div>
        </template>
      </div>

      <div class="error-bar" x-show="errorMsg !== ''" x-text="errorMsg"></div>

      <div class="chat-input-row">
        <textarea
          class="chat-input"
          x-model="inputText"
          placeholder="Type a message..."
          :disabled="status === 'running'"
          @keydown.enter.prevent="if (!$event.shiftKey) send()"
          rows="1"></textarea>
        <button
          class="btn-send"
          @click="send()"
          :disabled="status === 'running' || inputText.trim() === ''">
          Send
        </button>
      </div>
    </main>
  </div>

  <!-- Preset management modal -->
  <div class="modal-backdrop" x-show="showPresetModal" x-cloak @click.self="closePresetModal()">
    <div class="modal-panel" @click.stop>
      <div class="modal-header">
        <span>Presets</span>
        <button class="modal-close" @click="closePresetModal()">✕</button>
      </div>

      <div class="modal-body">
        <!-- Preset list -->
        <template x-for="p in presets" :key="p.name">
          <div class="preset-row">
            <div class="preset-info">
              <span class="preset-name" x-text="p.name"></span>
              <span class="preset-desc" x-text="p.description"></span>
            </div>
            <button
              class="btn-delete"
              x-show="p.deletable"
              @click="deletePreset(p.name)"
              title="Delete preset">✕</button>
          </div>
        </template>

        <hr class="modal-divider">

        <!-- Create form -->
        <div class="form-group">
          <label class="form-label">New Preset Name</label>
          <input
            class="form-input"
            type="text"
            x-model="newPresetName"
            placeholder="e.g. analyst"
            @keydown.enter.prevent>
        </div>

        <div class="form-group">
          <label class="form-label">System Prompt</label>
          <textarea
            class="form-input"
            x-model="newPresetPrompt"
            placeholder="You are a..."></textarea>
        </div>

        <p class="form-error" x-show="createError !== ''" x-text="createError"></p>
      </div>

      <div class="modal-footer">
        <button
          class="btn-primary"
          @click="createPreset()"
          :disabled="creating || newPresetName.trim() === '' || newPresetPrompt.trim() === ''">
          <span x-text="creating ? 'Saving...' : 'Save Preset'"></span>
        </button>
      </div>
    </div>
  </div>
</body>
</html>
```

- [ ] **Step 2: Verify HTML is well-formed**

```bash
python3 -c "
from html.parser import HTMLParser
class V(HTMLParser): pass
V().feed(open('priv/static/index.html').read())
print('HTML OK')
"
```

Expected: `HTML OK`

- [ ] **Step 3: Commit**

```bash
git add priv/static/index.html
git commit -m "feat: preset management modal in Web UI (Phase 30)"
```

---

## Manual verification checklist

Start Shem and open `http://localhost:4000` in a browser:

```bash
mix run --no-halt
```

- [ ] Preset selector populates from the API on load (not hardcoded)
- [ ] "Manage Presets" button opens the modal
- [ ] Clicking the backdrop closes the modal
- [ ] X button closes the modal
- [ ] Built-in presets (general, coder, etc.) show no delete button
- [ ] Create a preset: fill name + prompt, click Save — appears in list and selector
- [ ] Duplicate name shows inline error (not a page reload)
- [ ] Blank name or prompt: Save button is disabled
- [ ] Delete a user-created preset: removed from list; if it was active, selector switches to general
- [ ] Create a preset via TUI (`/preset add`), reload browser — it appears in the Web UI list
