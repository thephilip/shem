Shem attest bundle — offline-verifiable session record.

Contents
  events.jsonl   one canonical-JSON event per line (the record)
  tools/         exact source of each tool the session referenced
  tools.sha256   sha256sum manifest for tools/
  manifest.json  session id, event count, portable_head, beam_head, tool hashes
  verify.py      the verifier (Python 3 stdlib only)

Verify (primary):
  python3 verify.py .
  # exit 0 = verified, 1 = tampered/incomplete

Two heads, two guarantees:
  portable_head  recomputed by verify.py from events.jsonl. Proves the bundle is
                 internally consistent and unmodified since export. (lowercase hex)
  beam_head      the live BEAM hash-chain head at export. verify.py cannot
                 recompute it (it commits over Erlang term encoding, not JSON).
                 Anyone running Shem can confirm the source session's head equals
                 this value. (uppercase hex — native Base.encode16)

Tools show status "present" (source in tools/) or "missing" (the named tool no
longer existed in the source registry at export). Tool source is captured as it
existed AT EXPORT, not provably the bytes that ran — the event log records tool
names, not source, at call time.

Shell fallback (no Python, POSIX sh + sha256sum):
  # tool sources:
  sha256sum -c tools.sha256

  # chain: seed at genesis = sha256(session_id), fold over each line,
  # then compare the printed head to portable_head in manifest.json.
  # If manifest.json has a "gc" block, this session was pruned: seed h
  # with gc.portable_anchor instead of the genesis (the loop is unchanged).
  sid=$(sed -n 's/.*"session_id": *"\([^"]*\)".*/\1/p' manifest.json)
  h=$(printf %s "$sid" | sha256sum | cut -d' ' -f1)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    h=$(printf %s "$h$line" | sha256sum | cut -d' ' -f1)
  done < events.jsonl
  echo "recomputed head: $h"
  grep portable_head manifest.json
