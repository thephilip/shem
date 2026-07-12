# Sampling is dead, elicitation is standard: what MRTR means for agent servers

The MCP draft spec has a release candidate dated 2026-07-28. It settles
something that has been ambiguous for a while: how a server asks a client for
more input in the middle of a call. The pattern is called MRTR, Multi
Round-Trip Requests (SEP-2322). If you build or operate MCP servers, it is
worth reading even if you have never opened a SEP before.

MRTR is not a feature you turn on. It is a transport shape. A server that
needs something from the client (a human answer, a sampled completion, a list
of roots) returns an `InputRequiredResult` instead of a final response. That
result carries `inputRequests` (what is needed) and an opaque `requestState`
(where the server left off). The client collects the input, calls back with
`inputResponses`, and the server picks up where it stopped. Same call, one
extra hop.

The real news is what travels over that transport. MRTR standardizes the
envelope for three payload kinds: elicitation, sampling, and list_roots.
Sampling, the pattern where a server borrows the client's model to generate a
completion, is deprecated as of SEP-2577. The spec's migration guidance is to
"integrate directly with LLM provider APIs" instead. Elicitation is the part
that survives: it is the standard way for a server to say "I need a human to
answer this before I can continue", and it is what MRTR is for going forward.
If you have been treating "sampling" and "elicitation" as roughly the same
kind of thing, they no longer are. One is the payload being deprecated, the
other is the payload MRTR was built to carry.

Why this matters to Shem: it has had a human co-driver loop for a while. You
spawn an agent with `brain: "client"`, it parks when it needs a turn, a human
supplies that turn via `agent_status` / `provide_turn`, and the agent moves.
That loop was never sampling. Nothing borrows a model to generate the
completion; a human answers directly. It was already, semantically, an
elicitation: server needs input, the client's principal provides it, the call
resumes.

So when a client speaks MRTR and has the `elicitation` capability, Shem's
co-driver loop now comes back as a standard `elicitation/create` input
request instead of Shem's own polling shape. Concretely, a `spawn_agent`
tool call that parks returns this instead of a final result:

```json
{
  "resultType": "input_required",
  "inputRequests": {
    "turn": {
      "method": "elicitation/create",
      "params": {
        "mode": "form",
        "message": "<the agent's prompt for its next turn>",
        "requestedSchema": {
          "type": "object",
          "properties": {
            "content": {
              "type": "string",
              "description": "Next turn for the agent: embed a {\"tool\":…,\"args\":…} JSON object to call a tool, or plain text to finish"
            }
          },
          "required": ["content"]
        }
      }
    }
  },
  "requestState": "<HMAC-signed turn token>"
}
```

The human answers, and the client retries the same `tools/call` with the
`requestState` echoed back and the answer under `inputResponses`:

```json
{
  "requestState": "<the token, verbatim>",
  "inputResponses": {
    "turn": {
      "action": "accept",
      "content": { "content": "{\"tool\": \"http_get\", \"args\": {\"url\": \"…\"}}" }
    }
  }
}
```

The agent's turn advances, and the call either completes or parks again with
a fresh `InputRequiredResult` for the next turn. A `decline` or `cancel`
action leaves the agent parked and steerable through the classic
`agent_status` / `provide_turn` path. This is a wire-format adapter
over code that already shipped, not a new capability and not a rewrite of the
loop's semantics. The claim is precise: **Shem's co-driver loop is
MRTR-native via elicitation.** Not "Shem is MRTR-native". The rest of Shem
(tool calls, event log, graduation gate, packs) does not speak MRTR and has
no reason to. It is the one loop, expressed in the one format, where the two
actually line up.

One detail is worth reading past the summary for. The spec is explicit that
`requestState`, the opaque blob a server hands back on `InputRequiredResult`
and expects to get back verbatim in the retry, is attacker-controlled from
the server's point of view. A client can replay an old one, an intermediary
can tamper with it, and a server that trusts whatever comes back has a hole.
Shem's `requestState` is a turn token: HMAC-signed, bound to the specific
agent it was issued for, and short-TTL. A tampered or replayed token gets
rejected before it can move an agent it was not issued for. The signing is
not MRTR-specific scaffolding either. It shipped on the plain REST
`provide_turn` loop too, so clients without the `elicitation` capability get
the same integrity guarantee over the polling machinery they already had.

On sampling: Shem is not implementing it, and the deprecation is not why.
MCP's own migration guidance (integrate directly with provider APIs) is
already how Shem's BYO-key adapter works, and it sits alongside the keyless
client-brain loop this post is about. Between the two, sampling never had
anything to add here; its deprecation just removes a path that was never on
the map.

The reason this is worth shipping rather than treating as a compliance
checkbox comes back to how Shem is built: flight recorder first. Every
elicitation round-trip (the `InputRequiredResult`, the signed `requestState`,
the human's answer, the resumed call) lands in the same hash-chained EventLog
as every other turn in the agent's run. Speaking the standard format buys no
exception from being recorded. You get a co-driver loop that is steerable
through whatever client you already use, and provable after the fact
regardless of which format steered it.

## References

- SEP-2322 (Multi Round-Trip Requests) and SEP-2577 (sampling deprecation),
  in the [MCP specification repo](https://github.com/modelcontextprotocol/modelcontextprotocol).
- The adapter itself: [`lib/shem/mcp/mrtr.ex`](../lib/shem/mcp/mrtr.ex),
  about 150 lines over the existing park / `provide_turn` loop.
- The signed turn token (`requestState`): [`lib/shem/turn_token.ex`](../lib/shem/turn_token.ex).
- Conformance tests, including tampered and replayed `requestState`
  rejection: [`test/shem/mcp/mrtr_test.exs`](../test/shem/mcp/mrtr_test.exs).
