#!/usr/bin/env bash
#
# Regression suite for the Cursor subagent projection: agent.awk (the transform)
# and the `sync_agents` half of aiworks-cursor.sh (write, check, migrate, prune,
# remove) — docs/adr/0040.
#
# Run:  scripts/cursor/agents-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# Fixtures live in a THROWAWAY temp dir with its own HOME, so the result does not
# depend on this machine's plugins or on whatever repos this workspace has cloned.
# Same doctrine as root-rules-selftest.sh.
#
# Why a test at all: the generated file looks plausible whether or not the model
# line was rewritten, and a `model: opus` that slips through does not fail loudly
# — it pins a quota-gated model and the subagent refuses to start only once the
# account's pool is exhausted.

set -uo pipefail

H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$H/../.." && pwd)"
AWKAGENT="$H/agent.awk"
[ -f "$AWKAGENT" ] || { echo "missing $AWKAGENT"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

pass=0; fail=0
has()   { if printf '%s' "$3" | grep -qF -- "$2"; then echo "  PASS  $1"; pass=$((pass+1));
          else echo "  FAIL  $1"; echo "        want ~ $2"; fail=$((fail+1)); fi }
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then echo "  FAIL  $1 (unexpected: $2)"; fail=$((fail+1));
          else echo "  PASS  $1"; pass=$((pass+1)); fi }
yes()   { if "$@"; then echo "  PASS  $1 ${*:2}"; pass=$((pass+1)); else echo "  FAIL  $1 ${*:2}"; fail=$((fail+1)); fi }
no()    { if "$@"; then echo "  FAIL  not $1 ${*:2}"; fail=$((fail+1)); else echo "  PASS  not $1 ${*:2}"; pass=$((pass+1)); fi }
MARK='# aiworks-cursor: generated from'

echo "== transform: only the frontmatter model line changes =="
cat > "$TMP/agent.md" <<'EOF'
---
name: a
description: Fixture agent.
model: opus
effort: medium
tools:
  - Read
---

Body. Set `model: opus` in the frontmatter, never here.

---

After the horizontal rule.
EOF
out=$(awk -v src=.claude/agents/a.md -f "$AWKAGENT" "$TMP/agent.md")
has   "model becomes inherit"            'model: inherit'   "$out"
lacks "the tier name is gone from the frontmatter" 'model: opus' "$(printf '%s\n' "$out" | sed -n '2,/^---$/p')"
has   "marker on line 2"                 "$MARK .claude/agents/a.md" "$(printf '%s\n' "$out" | sed -n 2p)"
has   "effort survives"                  'effort: medium'   "$out"
has   "tools survive"                    '  - Read'         "$out"
has   "a model: inside the body is not rewritten" 'Set `model: opus` in the frontmatter' "$out"
has   "text after a body horizontal rule survives" 'After the horizontal rule.' "$out"
body_in=$(sed -n '/^---$/,/^---$/!p' "$TMP/agent.md")
body_out=$(printf '%s\n' "$out" | sed -n '/^---$/,/^---$/!p')
[ "$body_in" = "$body_out" ] && { echo "  PASS  body is byte-identical"; pass=$((pass+1)); } \
                             || { echo "  FAIL  body is byte-identical"; fail=$((fail+1)); }
printf -- '---\nname: b\n---\n\nB\n' > "$TMP/nomodel.md"
out=$(awk -v src=x -f "$AWKAGENT" "$TMP/nomodel.md")
has   "a file without model: gains only the marker" "$MARK" "$out"
lacks "…and no invented model line"      'model:'           "$out"
yes test "$(awk -v src=x -f "$AWKAGENT" "$TMP/nomodel.md" | grep -c '^---$')" -eq 2

echo "== generator fixture =="
WS="$TMP/ws"
mkdir -p "$WS/scripts/cursor" "$WS/.claude/agents"
cp "$ROOT/scripts/aiworks-cursor.sh" "$WS/scripts/"
cp "$H"/*.awk "$H"/hook-shim.template.sh "$WS/scripts/cursor/"
printf 'projects: []\n' > "$WS/mani.yaml"
printf 'products: []\n' > "$WS/workspace.config.yaml"
printf '# Fixture\n' > "$WS/CLAUDE.md"
printf -- '---\nname: a\nmodel: opus\n---\n\nA\n' > "$WS/.claude/agents/a.md"
printf -- '---\nname: b\nmodel: haiku\n---\n\nB\n' > "$WS/.claude/agents/b.md"
gen() { (cd "$WS" && scripts/aiworks-cursor.sh root "$@" 2>&1); }

out=$(gen)
yes test -f "$WS/.cursor/agents/a.md"
yes test -f "$WS/.cursor/agents/b.md"
no  test -L "$WS/.cursor/agents"
has "a.md was rewritten to inherit" 'model: inherit' "$(cat "$WS/.cursor/agents/a.md")"
has "b.md carries the marker"       "$MARK .claude/agents/b.md" "$(cat "$WS/.cursor/agents/b.md")"
has "second run changes nothing"    '(0 change(s)' "$(gen)"
gen --check >/dev/null; yes test "$?" -eq 0

echo "== drift: an edited canonical agent is caught, then reconciled =="
printf -- '---\nname: a\nmodel: sonnet\neffort: high\n---\n\nA2\n' > "$WS/.claude/agents/a.md"
out=$(gen --check); rc=$?
yes test "$rc" -eq 1
has "names the stale file" 'agents/a.md is stale' "$out"
gen >/dev/null
has "reconciled body" 'A2' "$(cat "$WS/.cursor/agents/a.md")"
has "reconciled effort" 'effort: high' "$(cat "$WS/.cursor/agents/a.md")"
gen --check >/dev/null; yes test "$?" -eq 0

echo "== legacy: the old directory link is drift, then migrated =="
rm -rf "$WS/.cursor/agents"; ln -s ../.claude/agents "$WS/.cursor/agents"
out=$(gen --check); rc=$?
yes test "$rc" -eq 1
has "names the legacy link" 'legacy link' "$out"
gen >/dev/null
no  test -L "$WS/.cursor/agents"
yes test -d "$WS/.cursor/agents"
has "files generated in its place" 'model: inherit' "$(cat "$WS/.cursor/agents/a.md")"
yes test -f "$WS/.claude/agents/a.md"

echo "== a hand-written Cursor agent is never touched =="
printf -- '---\nname: mine\nmodel: composer-2.5\n---\n\nMine.\n' > "$WS/.cursor/agents/mine.md"
printf -- '---\nname: b\nmodel: opus\n---\n\nHand-edited b.\n' > "$WS/.cursor/agents/b.md"
out=$(gen)
has "unmarked b.md is refused with a note" 'agents/b.md' "$out"
has "…and left as written" 'Hand-edited b.' "$(cat "$WS/.cursor/agents/b.md")"
has "mine.md untouched" 'Mine.' "$(cat "$WS/.cursor/agents/mine.md")"
rm -f "$WS/.cursor/agents/b.md"; gen >/dev/null

echo "== prune: a generated file whose source is gone =="
rm -f "$WS/.claude/agents/b.md"
out=$(gen --check); rc=$?
yes test "$rc" -eq 1
has "check reports the orphan" 'agents/b.md' "$out"
gen >/dev/null
no  test -e "$WS/.cursor/agents/b.md"
yes test -f "$WS/.cursor/agents/mine.md"

echo "== remove: only generator-owned files go =="
out=$(gen --remove)
no  test -e "$WS/.cursor/agents/a.md"
yes test -f "$WS/.cursor/agents/mine.md"
rm -f "$WS/.cursor/agents/mine.md"; gen >/dev/null; gen --remove >/dev/null
no  test -e "$WS/.cursor/agents"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
