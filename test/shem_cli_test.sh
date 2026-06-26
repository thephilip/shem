#!/bin/sh
# Smoke test for rel/overlays/shem: dispatch + guard branches + stop narration.
# No framework. Stubs the release launcher; "running" iff $TMP/up exists.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cp "$ROOT/rel/overlays/shem" "$TMP/shem"; chmod +x "$TMP/shem"
cat > "$TMP/bin/shem" <<'EOF'
#!/bin/sh
U="$(dirname "$0")/../up"
case "$1" in
  pid)    [ -f "$U" ] && { echo 4242; exit 0; } || exit 1 ;;
  daemon) touch "$U"; exit 0 ;;
  stop)   rm -f "$U"; exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/shem"

fail() { echo "FAIL: $1" >&2; exit 1; }
S="$TMP/shem"

out="$("$S" stop)"   || fail "stop(down) returned nonzero"
echo "$out" | grep -q "not running"   || fail "stop(down) should say not running"

"$S" status >/dev/null 2>&1 && fail "status(down) should exit nonzero" || true

out="$("$S" start --port 4010)" || fail "start returned nonzero"
echo "$out" | grep -q "Shem running" || fail "start should print banner"

out="$("$S" start)"  || fail "start(up) returned nonzero"
echo "$out" | grep -q "already running" || fail "start(up) should guard"

out="$("$S" status)" || fail "status(up) returned nonzero"
echo "$out" | grep -q "4010" || fail "status should reflect the port start chose"

out="$("$S" stop)"   || fail "stop returned nonzero"
echo "$out" | grep -q "evacuating"   || fail "stop should narrate evacuation"
echo "$out" | grep -q "Shem stopped" || fail "stop should confirm completion"

echo "ok"
