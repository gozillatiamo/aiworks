#!/usr/bin/env bash
#
# Regression for the mermaid.live link encoder + its checker. A link is 800+ chars of
# base64 that no human proof-reads, and mermaid.live answers a CORRUPT fragment by loading
# its own "Loading URL failed" sample diagram — so a broken link looks exactly like a
# working one until someone reads the picture. That happened on a real ticket: one base64
# character differed from what the encoder printed, every other byte identical.
#
# So: the encoder must round-trip, and --check must REFUSE a mutated or truncated link
# rather than shrug.
#
# Run:  scripts/diagram/selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# Pure local encode/decode — no network, no credentials, nothing rendered.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0

ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

SRC='flowchart TD
  A["Player initiates deposit"] --> B{"amount_zero_fraction ok?"}
  B -->|Valid| C["Send core payment request"]
  B -->|Invalid| D["Terminal: rejected, zero credit"]'

link="$(printf '%s' "$SRC" | "$DIR/live-link.sh" -)" || bad "encode" "live-link.sh failed"
case "$link" in
  https://mermaid.live/edit\#pako:*) ok "link has the pako form" ;;
  *) bad "link has the pako form" "got: $link" ;;
esac

# The round-trip: what the encoder printed must decode back to the same source.
if out="$("$DIR/live-link.sh" --check "$link" 2>&1)"; then
  case "$out" in
    ok:*Mermaid\ source*) ok "fresh link passes --check" ;;
    *) bad "fresh link passes --check" "unexpected output: $out" ;;
  esac
else
  bad "fresh link passes --check" "$out"
fi
if printf '%s' "$SRC" | diff -q - <(python3 - "$link" <<'PY'
import sys, base64, zlib, json
frag = sys.argv[1].split("#pako:")[1]
print(json.loads(zlib.decompress(base64.urlsafe_b64decode(frag + "=" * (-len(frag) % 4))))["code"], end="")
PY
) >/dev/null 2>&1; then ok "decoded source is byte-identical"; else bad "decoded source is byte-identical" "source changed through the round-trip"; fi

# One altered character — the real-world failure. zlib must reject it, and so must we.
frag="${link#*\#pako:}"
mutated="${frag:0:70}$([[ "${frag:70:1}" == "A" ]] && echo "B" || echo "A")${frag:71}"
if "$DIR/live-link.sh" --check "https://mermaid.live/edit#pako:$mutated" >/dev/null 2>&1
then bad "--check rejects a one-char mutation" "it passed a corrupt fragment"
else ok "--check rejects a one-char mutation"; fi

# A truncated fragment (a copy/paste that lost the tail) must fail too.
if "$DIR/live-link.sh" --check "https://mermaid.live/edit#pako:${frag:0:200}" >/dev/null 2>&1
then bad "--check rejects a truncated link" "it passed a truncated fragment"
else ok "--check rejects a truncated link"; fi

# A state whose `mermaid` field is a nested OBJECT parses as JSON but renders blank in the
# editor (it calls JSON.parse on that field), so --check must treat it as corrupt.
nested="$(python3 - <<'PY'
import base64, zlib, json
state = {"code": "flowchart TD\n  A --> B", "mermaid": {"theme": "default"}, "updateDiagram": True}
raw = zlib.compress(json.dumps(state).encode(), 9)
print(base64.urlsafe_b64encode(raw).decode().rstrip("="))
PY
)"
if "$DIR/live-link.sh" --check "pako:$nested" >/dev/null 2>&1
then bad "--check rejects a non-string mermaid field" "it passed a blank-rendering state"
else ok "--check rejects a non-string mermaid field"; fi

# The rendered image must be OPAQUE by default. mermaid.ink renders a transparent
# background, and a transparent PNG takes the colour of whatever the viewer puts behind
# it — Jira's full-screen media viewer is near-black, which turned a diagram's own dark
# text and edges unreadable on a real ticket. Checked via --dry-run so this stays offline.
url="$(printf '%s' "$SRC" | "$DIR/render.sh" - out.png --dry-run)"
case "$url" in
  *bgColor=FFFFFF*) ok "render defaults to an opaque background" ;;
  *) bad "render defaults to an opaque background" "no bgColor in: $url" ;;
esac
url="$(printf '%s' "$SRC" | "$DIR/render.sh" - out.png --bg transparent --dry-run)"
case "$url" in
  *bgColor*) bad "--bg transparent omits bgColor" "still set: $url" ;;
  *) ok "--bg transparent omits bgColor" ;;
esac
url="$(printf '%s' "$SRC" | "$DIR/render.sh" - out.png --bg '!white' --dry-run)"
case "$url" in
  *bgColor=\!white*) ok "--bg passes a !name through" ;;
  *) bad "--bg passes a !name through" "got: $url" ;;
esac

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
