#!/usr/bin/env bash
# repo-context-selftest.sh — exercise pretool-repo-context.sh, the hook that hands a
# workspace-root session the configuration of whichever repo it reaches into.
#
# Run from anywhere: .claude/hooks/dev-wrapper/repo-context-selftest.sh
set -uo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$H/../../.." && pwd)"
HOOK="$H/pretool-repo-context.sh"
export CLAUDE_PROJECT_DIR="$ROOT"

pass=0; fail=0
run() { # run <session> <path> [event] — fresh session state
  rm -rf "${TMPDIR:-/tmp}/aiworks-repo-context/$1" 2>/dev/null
  jq -cn --arg p "$2" --arg e "${3:-PreToolUse}" --arg s "$1" --arg c "call-$1-1" \
    '{hook_event_name:$e, session_id:$s, tool_use_id:$c, tool_input:{file_path:$p}}' | "$HOOK"
}
again() { # again <session> <path> <call-id> — same session, state kept
  jq -cn --arg p "$2" --arg s "$1" --arg c "$3" \
    '{hook_event_name:"PreToolUse", session_id:$s, tool_use_id:$c, tool_input:{file_path:$p}}' | "$HOOK"
}
has()  { if printf '%s' "$3" | grep -qF "$2"; then echo "  PASS  $1"; pass=$((pass+1));
         else echo "  FAIL  $1 (missing: $2)"; fail=$((fail+1)); fi }
lacks(){ if printf '%s' "$3" | grep -qF "$2"; then echo "  FAIL  $1 (unexpected: $2)"; fail=$((fail+1));
         else echo "  PASS  $1"; pass=$((pass+1)); fi }
empty(){ if [ -z "$2" ]; then echo "  PASS  $1"; pass=$((pass+1));
         else echo "  FAIL  $1 (expected no output)"; fail=$((fail+1)); fi }

echo "== injects the repo's own instruction =="
# Assert on the injected SECTION HEADER, not the bare filename: a repo's CLAUDE.md
# lists its own rule files by name, so a loose match reads that prose as an injection.
out=$(run s1 "$ROOT/paotung-template/src/features/wallet/WalletCard.tsx")
has   "CLAUDE.md of the touched repo" "===== paotung-template/CLAUDE.md" "$out"
has   "a rule scoped to src/**/*.tsx" "===== paotung-template/.claude/rules/data-cy-i18n.md" "$out"
lacks "a rule scoped to *.stories.tsx" "===== paotung-template/.claude/rules/storybook.md" "$out"

echo "== glob matching is per-rule, not all-or-nothing =="
out=$(run s2 "$ROOT/paotung-template/src/components/Button.stories.tsx")
has   "story file pulls the storybook rule" "===== paotung-template/.claude/rules/storybook.md" "$out"
# ...and also the src/**/*.tsx rule, because a story under src/ genuinely satisfies
# both globs. Every matching rule is injected, not just the most specific one.
has   "and every other rule it also matches" "===== paotung-template/.claude/rules/data-cy-i18n.md" "$out"

echo "== once per session per repo, keyed on the tool call =="
out=$(again s2 "$ROOT/paotung-template/src/components/Card.tsx" "call-s2-2")
empty "a later, different tool call is silent" "$out"
# Both tools invoke a hook more than once for a SINGLE tool call. Suppressing the
# repeat would let the first invocation emit and the second return nothing, and the
# empty second result wins — which is exactly how this hook first failed in Cursor.
out=$(again s2 "$ROOT/paotung-template/src/components/Card.tsx" "call-s2-1")
has   "a repeat of the same tool call re-emits" "===== paotung-template/CLAUDE.md" "$out"
out=$(again s2 "$ROOT/backoffice/src/app/page.tsx" "call-s2-3")
has   "a different repo in the same session still injects" "===== backoffice/CLAUDE.md" "$out"
# The hook is wired on Pre AND Post so that whichever event a given tool honours
# wins. The pair must not inject the same text twice for one call.
out=$(run s9 "$ROOT/game/src/lib.rs")
has   "PreToolUse of a fresh call injects" "===== game/CLAUDE.md" "$out"
out=$(jq -cn --arg p "$ROOT/game/src/lib.rs" --arg c "call-s9-1" \
        '{hook_event_name:"PostToolUse", session_id:"s9", tool_use_id:$c, tool_input:{file_path:$p}}' | "$HOOK")
empty "the PostToolUse half of the same call is silent" "$out"

echo "== stays out of the way =="
out=$(run s3 "$ROOT/scripts/aiworks-cursor.sh")
empty "a path outside any product repo" "$out"
out=$(run s4 "/etc/hosts")
empty "an absolute path outside the workspace" "$out"
out=$(CLAUDE_PROJECT_DIR="$ROOT/paotung-template" run s5 "$ROOT/paotung-template/src/x.tsx")
empty "a session already rooted at the repo" "$out"
out=$(printf '{"hook_event_name":"PreToolUse","session_id":"s6","tool_input":{}}' | "$HOOK")
empty "a tool call with no file_path" "$out"

echo "== output shape the shim can translate =="
out=$(run s7 "$ROOT/agent-webservice/src/routes/external_game_route.rs")
has   "hookSpecificOutput envelope" '"hookEventName"' "$out"
has   "echoes the event it was called for" 'PreToolUse' "$out"
out=$(run s8 "$ROOT/agent-webservice/src/routes/external_game_route.rs" PostToolUse)
has   "works on PostToolUse too" 'PostToolUse' "$out"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
