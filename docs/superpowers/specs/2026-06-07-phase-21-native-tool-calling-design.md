# Phase 21 — Native Tool Calling Design

## Goal

Replace text-based tool invocation (regex-scanned JSON in LLM prose) with native tool calling across all four transports. Agents get reliable, structured tool dispatch; the LLM gets proper schema context; multi-turn tool conversations carry full fidelity IDs.

---

## Context

Currently `build_prompt/3` instructs the model to embed `{"tool": "<name>", "args": {...}}` inline in its response. `parse_response/1` regex-scans for these objects. This works but is fragile — the model may format JSON differently, add surrounding text, or omit args. OpenAI, Anthropic, Ollama, and llama.cpp all expose native tool-calling APIs that accept a structured `tools` array and return structured `tool_calls` or `tool_use` blocks. Phase 19 laid the foundation with structured `messages` on `Request`; Phase 21 adds `tools` on `Request` and `tool_calls` on `Response`, and wires all four transports.

---

## Design

### Data Model

**`Shem.LLM.Request`** — one new optional field:

```elixir
tools: [tool_schema()] | nil

@type tool_schema :: %{
  name: String.t(),
  description: String.t(),
  schema: %{type: String.t(), properties: map(), required: [String.t()]}
}
```

**`Shem.LLM.Response`** — one new optional field; `content` relaxes to `String.t() | nil` (models return nil content when only tool calls are present):

```elixir
tool_calls: [tool_call()] | nil

@type tool_call :: %{id: String.t(), name: String.t(), args: map()}
```

`@enforce_keys` on `Response` drops `content` since it can now be nil.

**History entries** — plain maps gain two optional keys:
- `tool_calls: [tool_call()]` on assistant turns that issued calls
- `tool_call_id: String.t()` on tool-result turns

**Canonical tool call key rename**: `parse_response/1` shifts from returning `%{tool: name, args: args}` to `%{id: nil, name: name, args: args}`. `ToolDispatch.execute/2` pattern-matches on `:name`. `Agent.Server` uses `.name` and `.id`.

---

### `ToolDispatch` — Inline Schemas

Each entry in `@builtins` gains a `schema` field with a proper JSON Schema object:

| Tool | Required | Optional |
|---|---|---|
| `list_tools` | _(none)_ | _(none)_ |
| `run_code` | `source` (string) | `timeout_ms` (integer) |
| `write_tool` | `source`, `test_source` (strings) | _(none)_ |
| `read_file` | `path` (string) | _(none)_ |
| `write_file` | `path`, `content` (strings) | _(none)_ |
| `list_dir` | `path` (string) | _(none)_ |
| `shell` | `cmd` (string) | `timeout_ms` (integer) |

Lab tools and MCP tools receive a permissive fallback schema: `%{type: "object", properties: %{}, required: []}`. Their args pass through unvalidated as before.

`build_manifest/1` is unchanged in structure — `schema` rides along in each map entry.

---

### `Agent.Turn`

**`build_request/4`** extracts tool schemas from the manifest and populates `request.tools`:

```elixir
def build_request(model, system_prompt, tools_manifest, history) do
  prompt   = build_prompt(system_prompt, tools_manifest, history)
  messages = case build_messages(history) do
    []   -> nil
    msgs -> msgs
  end
  tools = case Enum.map(tools_manifest, &Map.take(&1, [:name, :description, :schema])) do
    []  -> nil
    ts  -> ts
  end
  %Request{prompt: prompt, model: model, system: system_prompt, messages: messages, tools: tools}
end
```

**`build_messages/1`** (signature changes from `build_messages/2` to `build_messages/1`) drops the tool-header user message — tools are now communicated via `request.tools`. It maps all history entry shapes:

```elixir
defp build_messages(history) do
  Enum.map(history, fn
    %{role: :user,      content: c}                     -> %{role: :user,      content: c}
    %{role: :assistant, content: c, tool_calls: calls}  -> %{role: :assistant, content: c, tool_calls: calls}
    %{role: :assistant, content: c}                     -> %{role: :assistant, content: c}
    %{role: :tool,      content: c, tool_call_id: id}   -> %{role: :tool,      content: c, tool_call_id: id}
    %{role: :tool,      content: c}                     -> %{role: :tool,      content: c}
  end)
end
```

**`build_prompt/3`** is unchanged — the text prompt stays in `request.prompt` for the `prompt` field, keeping existing tests green.

**`parse_response/1`** return format shifts from `%{tool: name, args: args}` to `%{id: nil, name: name, args: args}`.

**`step/4`** checks `response.tool_calls` first:

```elixir
case LLM.complete(request) do
  {:ok, %Response{tool_calls: [_ | _] = calls, content: content}} ->
    {:tool_calls, calls, content || ""}
  {:ok, %Response{content: content}} ->
    content |> strip_thinking() |> parse_response()
  {:error, reason} ->
    {:error, reason}
end
```

Return type of `{:tool_calls, calls, raw}` is unchanged in shape; `calls` now always carry `%{id, name, args}` regardless of path (text-parsed calls get `id: nil`).

---

### Transport Behaviour

#### OpenAI and LlamaCpp (identical wire format)

LlamaCpp switches from `/v1/completions` to `/v1/chat/completions`.

**Request**: when `request.tools` is non-nil, add `"tools"` array and `"tool_choice": "auto"`:

```json
{
  "tools": [
    {"type": "function", "function": {
      "name": "run_code",
      "description": "...",
      "parameters": {"type": "object", "properties": {"source": {"type": "string"}}, "required": ["source"]}
    }}
  ],
  "tool_choice": "auto"
}
```

**Message formatting** — the message mapper handles new history shapes:

```elixir
# assistant with tool calls
%{role: :assistant, content: c, tool_calls: calls} ->
  %{"role" => "assistant", "content" => c,
    "tool_calls" => Enum.map(calls, fn %{id: id, name: n, args: a} ->
      %{"id" => id, "type" => "function",
        "function" => %{"name" => n, "arguments" => Jason.encode!(a)}}
    end)}

# tool result
%{role: :tool, tool_call_id: id, content: c} ->
  %{"role" => "tool", "tool_call_id" => id, "content" => c}
```

**Response parsing**: `choices[0]["message"]` may have `"tool_calls"`. Arguments arrive as a JSON string:

```elixir
tool_calls = Enum.map(raw_calls, fn %{"id" => id, "function" => %{"name" => n, "arguments" => args_str}} ->
  %{id: id, name: n, args: Jason.decode!(args_str)}
end)
```

`content` is extracted from `message["content"]` (may be `nil`).

#### Anthropic

**Request**: tools use `"input_schema"` key, no `"type": "function"` wrapper:

```json
{
  "tools": [
    {"name": "run_code", "description": "...",
     "input_schema": {"type": "object", "properties": {"source": {"type": "string"}}, "required": ["source"]}}
  ]
}
```

**Message formatting** — Anthropic tool results go as `role: "user"` with content block arrays:

```elixir
# assistant with tool calls → content array
%{role: :assistant, content: c, tool_calls: calls} ->
  text_blocks = if c && c != "", do: [%{"type" => "text", "text" => c}], else: []
  call_blocks = Enum.map(calls, fn %{id: id, name: n, args: a} ->
    %{"type" => "tool_use", "id" => id, "name" => n, "input" => a}
  end)
  %{"role" => "assistant", "content" => text_blocks ++ call_blocks}

# tool result → user message with tool_result block
%{role: :tool, tool_call_id: id, content: c} ->
  %{"role" => "user",
    "content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => c}]}
```

**Response parsing**: `content` is an array of blocks. Extract `tool_use` and `text` blocks:

```elixir
tool_calls = content
  |> Enum.filter(&(&1["type"] == "tool_use"))
  |> Enum.map(fn %{"id" => id, "name" => n, "input" => a} -> %{id: id, name: n, args: a} end)

text = content
  |> Enum.filter(&(&1["type"] == "text"))
  |> Enum.map_join("", & &1["text"])
```

#### Ollama

Switches from `/api/generate` to `/api/chat`. Request body:

```json
{"model": "...", "messages": [...], "tools": [...], "stream": false}
```

Tool format is identical to OpenAI (`"type": "function"` wrapper).

Message formatting follows the OpenAI formatter **except** tool results omit `"tool_call_id"`. The formatter matches and discards the ID (history entries always carry it, Ollama just doesn't need it):

```elixir
%{role: :tool, content: c, tool_call_id: _} -> %{"role" => "tool", "content" => c}
%{role: :tool, content: c}                  -> %{"role" => "tool", "content" => c}
```

**Response parsing**: `body["message"]` replaces `body["response"]`. Ollama's `tool_calls` have arguments already parsed (not a JSON string) and carry no `id`. Synthetic IDs are generated:

```elixir
tool_calls = Enum.map(raw_calls, fn %{"function" => %{"name" => n, "arguments" => a}} ->
  %{id: "ollama_#{:erlang.unique_integer([:positive, :monotonic])}", name: n, args: a}
end)
```

Synthetic IDs flow into history normally. When the Ollama formatter rebuilds messages from that history, tool result entries omit the ID (Ollama doesn't require it).

---

### `Agent.Server`

Three localised changes in `handle_info(:run_turn, ...)` and `execute_tool_calls/4`:

**Tool call key**: `call.tool` → `call.name` throughout (EventLog appends, ToolDispatch calls).

**Assistant turn with tool calls** — structured entry, not raw text:

```elixir
assistant_entry = %{
  role: :assistant,
  content: (if raw == "", do: nil, else: raw),
  tool_calls: calls
}
history = state.history ++ [assistant_entry]
```

**Tool result entries** carry `tool_call_id`:

```elixir
acc ++ [%{role: :tool, tool_call_id: id, content: result_str}]
```

`finish/3` is unchanged — `Map.get(:content, "")` already handles `nil` content correctly.

---

## File Map

| File | Action |
|---|---|
| `lib/shem/llm/request.ex` | Modify — add `tools` field and `tool_schema()` type |
| `lib/shem/llm/response.ex` | Modify — add `tool_calls` field, `tool_call()` type; relax `content` to `nil`-able; drop from `@enforce_keys` |
| `lib/shem/agent/tool_dispatch.ex` | Modify — add `schema` to each builtin; permissive fallback for Lab/MCP; rename `:tool` → `:name` in `execute/2` |
| `lib/shem/agent/turn.ex` | Modify — `build_request/4` passes tools; `build_messages/1` drops tool header, handles new history shapes; `parse_response/1` returns `%{id: nil, name, args}`; `step/4` checks `response.tool_calls` |
| `lib/shem/llm/middleware/openai_transport.ex` | Modify — inject tools array; format new history entry shapes; decode `tool_calls` from response |
| `lib/shem/llm/middleware/anthropic_transport.ex` | Modify — inject tools with `input_schema`; format content-block messages; decode `tool_use` blocks |
| `lib/shem/llm/middleware/ollama_transport.ex` | Modify — switch to `/api/chat`; inject tools; generate synthetic IDs; decode tool_calls |
| `lib/shem/llm/middleware/llama_cpp_transport.ex` | Modify — switch to `/v1/chat/completions`; inject tools; decode tool_calls |
| `lib/shem/agent/server.ex` | Modify — structured assistant entry; `tool_call_id` on tool results; `call.name` throughout |
| `test/shem/llm/request_test.exs` | Modify — add `tools` field test |
| `test/shem/llm/response_test.exs` | Modify — add `tool_calls` field test; nil content test |
| `test/shem/agent/tool_dispatch_test.exs` | Modify — schema presence per builtin; `:name` key in execute |
| `test/shem/agent/turn_test.exs` | Modify — `parse_response` return format; `build_request` tools field; `build_messages` no tool header; `step` native path |
| `test/shem/llm/middleware/openai_transport_test.exs` | Modify — tools in body; tool_calls parsed; message formatting |
| `test/shem/llm/middleware/anthropic_transport_test.exs` | Modify — `input_schema` format; tool_use parsed; role conversion |
| `test/shem/llm/middleware/ollama_transport_test.exs` | Modify — `/api/chat` endpoint; tools; synthetic IDs |
| `test/shem/llm/middleware/llama_cpp_transport_test.exs` | **Create** — basic completion; tools in body; tool_calls parsed |
| `test/shem/agent/server_test.exs` | Modify — history entries after tool-call turn |

---

## Testing Strategy

- `parse_response/1` tests updated: assert `%{id: nil, name: ..., args: ...}` shape
- `build_request/4` tests: `request.tools` non-nil when manifest non-empty; no "Available tools" message in `request.messages`
- Per-transport: one test for tools in request body (correct format for that API); one test for tool_calls decoded from response; one test for new history entry shapes formatted correctly
- Ollama: assert synthetic IDs are non-nil strings
- `server_test`: after a turn that yields `{:tool_calls, ...}`, history has `%{role: :assistant, tool_calls: [...]}` and `%{role: :tool, tool_call_id: ..., content: ...}`
- All 583 existing tests continue to pass (backward compat: `tools: nil` / `tool_calls: nil` defaults leave current behaviour unchanged)

---

## Future Work

- `:tool` history role for Anthropic could carry richer tool-result metadata (tool name alongside content) — deferred; the current string content is sufficient
- Streaming tool calls (partial JSON arguments arriving via SSE) — blocked on Phase 22 streaming
- Tool schemas for Lab-graduated tools (inferred from `@moduledoc` or a `schema/0` callback) — deferred
