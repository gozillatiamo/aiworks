#!/usr/bin/env bash
#
# Regression suite for pretool-repo-context.sh — the hook that hands a
# workspace-root session the configuration of whichever repo it reaches into.
#
# Run:  .claude/hooks/dev-wrapper/repo-context-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# Everything runs against a THROWAWAY workspace in a temp dir — its own
# workspace.config.yaml, its own product repos, its own rules — so the suite is
# portable and its result does not depend on which repos this workspace has
# cloned or on what their rules happen to say. Same doctrine as guards-selftest.sh.

set -uo pipefail

H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$H/pretool-repo-context.sh"
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

TMP="$(mktemp -d)"
STATE="${TMPDIR:-/tmp}/aiworks-repo-context"
trap 'rm -rf "$TMP" "$STATE"/t? 2>/dev/null' EXIT
export CLAUDE_PROJECT_DIR="$TMP"

# A workspace root is identified by its workspace.config.yaml — that is what tells
# the hook this session has the nested-config problem at all.
: > "$TMP/workspace.config.yaml"
mkdir -p "$TMP/tools"; : > "$TMP/tools/helper.sh"

mk_repo() { # mk_repo <name> <marker>
  local d="$TMP/$1" m="$2"
  mkdir -p "$d/.claude/rules/nested" "$d/src"
  printf '# %s\n\nThe %s marker is %s.\n' "$1" "$1" "$m" > "$d/CLAUDE.md"
  # scoped to one extension
  printf -- '---\ndescription: Scoped rule\npaths:\n  - "src/**/*.ts"\nglobs:\n  - "src/**/*.ts"\n---\n\nSCOPED-%s\n' "$m" > "$d/.claude/rules/scoped.md"
  # scoped to a suffix, to prove matching is per rule rather than all-or-nothing
  printf -- '---\ndescription: Story rule\nglobs:\n  - "**/*.stories.ts"\n---\n\nSTORIES-%s\n' "$m" > "$d/.claude/rules/stories.md"
  # no globs at all — description-only, must never be pulled in by a path match
  printf -- '---\ndescription: Broad rule\n---\n\nBROAD-%s\n' "$m" > "$d/.claude/rules/broad.md"
  # a nested rules directory, to prove the tree is walked
  printf -- '---\ndescription: Nested rule\nglobs:\n  - "src/**"\n---\n\nNESTED-%s\n' "$m" > "$d/.claude/rules/nested/deep.md"
  : > "$d/src/app.ts"
}
mk_repo svc SVC
mk_repo web WEB

pass=0; fail=0
call() { # call <session> <call-id> <path> [event]
  jq -cn --arg p "$3" --arg e "${4:-PreToolUse}" --arg s "$1" --arg c "$2" \
    '{hook_event_name:$e, session_id:$s, tool_use_id:$c, tool_input:{file_path:$p}}' | "$HOOK"
}
fresh() { rm -rf "$STATE/$1" 2>/dev/null; }
has()  { if printf '%s' "$3" | grep -qF "$2"; then echo "  PASS  $1"; pass=$((pass+1));
         else echo "  FAIL  $1 (missing: $2)"; fail=$((fail+1)); fi }
lacks(){ if printf '%s' "$3" | grep -qF "$2"; then echo "  FAIL  $1 (unexpected: $2)"; fail=$((fail+1));
         else echo "  PASS  $1"; pass=$((pass+1)); fi }
empty(){ if [ -z "$2" ]; then echo "  PASS  $1"; pass=$((pass+1));
         else echo "  FAIL  $1 (expected no output)"; fail=$((fail+1)); fi }

echo "== the touched repo's instruction and the rules that match =="
fresh t1; out=$(call t1 c1 "$TMP/svc/src/app.ts")
has   "the repo's own CLAUDE.md"          "The svc marker is SVC." "$out"
has   "a rule whose glob matches"         "SCOPED-SVC"             "$out"
has   "a rule in a nested rules dir"      "NESTED-SVC"             "$out"
lacks "a rule whose glob does not match"  "STORIES-SVC"            "$out"
lacks "a description-only rule"           "BROAD-SVC"              "$out"
lacks "another repo's rules"              "SCOPED-WEB"             "$out"

echo "== matching is per rule, not all-or-nothing =="
fresh t2; out=$(call t2 c1 "$TMP/svc/src/button.stories.ts")
has   "the suffix rule fires"                    "STORIES-SVC" "$out"
has   "and so does every other rule it matches"  "SCOPED-SVC"  "$out"

echo "== once per session per repo, keyed on the tool call =="
fresh t3; out=$(call t3 c1 "$TMP/svc/src/app.ts")
has   "first touch injects"                  "SCOPED-SVC" "$out"
out=$(call t3 c2 "$TMP/svc/src/other.ts")
empty "a later, different call is silent"    "$out"
# Both tools invoke a hook more than once for one tool call. Suppressing the repeat
# would let the first invocation emit and the second return nothing, and the empty
# result wins — which is exactly how this hook first failed under Cursor.
out=$(call t3 c1 "$TMP/svc/src/app.ts")
has   "a repeat of the SAME call re-emits"   "SCOPED-SVC" "$out"
# ...but the Pre/Post pair of one call must not inject the same text twice.
out=$(call t3 c1 "$TMP/svc/src/app.ts" PostToolUse)
empty "the Post half of that call is silent" "$out"
out=$(call t3 c3 "$TMP/web/src/app.ts")
has   "a different repo still injects"       "The web marker is WEB." "$out"

echo "== stays out of the way =="
fresh t4; out=$(call t4 c1 "$TMP/tools/helper.sh"); empty "a path outside any product repo" "$out"
fresh t5; out=$(call t5 c1 "/etc/hosts");           empty "a path outside the workspace"    "$out"
fresh t6; out=$(CLAUDE_PROJECT_DIR="$TMP/svc" call t6 c1 "$TMP/svc/src/app.ts")
empty "a session already rooted at the repo" "$out"
fresh t7; out=$(printf '{"hook_event_name":"PreToolUse","session_id":"t7","tool_input":{}}' | "$HOOK")
empty "a tool call with no file_path" "$out"

echo "== the envelope the Cursor shim knows how to translate =="
fresh t8; out=$(call t8 c1 "$TMP/svc/src/app.ts")
has "hookSpecificOutput envelope"        '"hookEventName"' "$out"
has "echoes the event it was called for" 'PreToolUse'      "$out"
fresh t9; out=$(call t9 c1 "$TMP/svc/src/app.ts" PostToolUse)
has "works on PostToolUse too"           'PostToolUse'     "$out"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
