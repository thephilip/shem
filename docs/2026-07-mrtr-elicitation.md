# Sampling is dead, elicitation is standard: what MRTR means for agent servers

The MCP draft spec has a release candidate dated 2026-07-28, and it settles
something that's been ambiguous for a while: how a server asks a client for
more input mid-call. The pattern is called MRTR — Multi Round-Trip Requests
(SEP-2322) — and if you build or operate MCP servers, it's worth twenty
minutes even if you've never read a SEP in your life.

MRTR itself is not a feature you turn on. It's a transport shape. A server
that needs something from the client — a human answer, a sampled completion,
a list of roots — returns an `InputRequiredResult` instead of a final
response. That result carries `inputRequests` (what's needed) and an opaque
`requestState` (where the server left off). The client collects the input,
calls back with `inputResponses`, and the server picks up where it stopped.
Same call, extra hop.

What travels over that transport is where the real news is. MRTR standardizes
the envelope for three payload kinds: elicitation, sampling, and list_roots.
Of those, sampling — the pattern where a server borrows the client's model to
generate a completion — is deprecated as of SEP-2577. The migration guidance
in the spec is blunt: servers that were leaning on sampling should "integrate
directly with LLM provider APIs" instead. Elicitation, in contrast, is very
much alive: it's the standard way for a server to say "I need a human to
answer this before I can continue," and it's what MRTR is mostly for going
forward. If you've been putting off reading either SEP because "sampling" and
"elicitation" sound like the same kind of thing, they aren't anymore — one's
the payload getting deprecated, the other is the payload MRTR was built to
carry.

Here's why this matters to us. Shem has had a human co-driver loop for a
while: you spawn an agent with `brain: "client"`, it parks when it needs a
turn, a human (via `agent_status` / `provide_turn`) supplies that turn, and
the agent moves. That loop was never sampling — nothing borrows a model to
generate the completion, a human answers directly. It was, without us having
named it that at the time, already semantically an elicitation: server needs
input, client's principal provides it, call resumes.

So when a client speaks MRTR and has the `elicitation` capability, Shem's
co-driver loop now comes back as a standard `elicitation/create` input
request instead of Shem's own polling shape. The human answers, the client
retries the call, the agent's turn advances. This is a wire-format adapter
over code that already shipped — not a new capability, not a rewrite of the
loop's semantics. The claim we'll stand behind is precise: **Shem's co-driver
loop is MRTR-native via elicitation.** Not "Shem is MRTR-native" — the rest
of Shem (tool calls, event log, graduation gate, packs) doesn't speak MRTR
and has no reason to. It's the one loop, expressed in the one format, where
the two things actually line up.

One detail is worth reading past the summary for. The spec is explicit that
`requestState` — the opaque blob a server hands back on `InputRequiredResult`
and expects to get back verbatim in the retry — is attacker-controlled from
the server's point of view. A client could replay an old one, an intermediary
could tamper with it, and if the server just trusts whatever comes back, that's
a hole. Shem's `requestState` is a turn token: HMAC-signed, bound to the
specific agent it was issued for, and short-TTL. A tampered or replayed token
gets rejected before it can move an agent it wasn't issued for. That signing
isn't MRTR-specific scaffolding, either — it shipped on the plain REST
`provide_turn` loop too, so clients without the `elicitation` capability get
the same integrity guarantee over the same polling machinery they already
had.

On sampling: we're not implementing it, and the deprecation isn't why. MCP's
own migration guidance — integrate directly with provider APIs — is
already how Shem's BYO-key adapter path works, and it sits alongside the
keyless client-brain loop this whole post is about. Between the two, sampling
never had anything to add for us; its deprecation just removes a path we
weren't planning to walk.

The reason any of this is worth shipping rather than shrugging off as a
compliance checkbox comes back to how Shem is built: flight recorder first.
Every elicitation round-trip — the `InputRequiredResult`, the signed
`requestState`, the human's answer, the resumed call — lands in the same
hash-chained EventLog as every other turn in the agent's run. Nothing about
speaking the standard format buys an exception from being recorded. You get
a co-driver loop that's steerable through whatever client you're already
using, and provable after the fact regardless of which format steered it.
