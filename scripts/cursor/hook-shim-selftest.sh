#!/usr/bin/env bash
#
# Regression suite for the Cursor hook shim: feed it the JSON shape Cursor
# actually sends, and assert the JSON it hands back, with this workspace's real
# guard hooks in the middle.
#
# Run:  scripts/cursor/hook-shim-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# Companion to .claude/hooks/dev-wrapper/guards-selftest.sh, which covers the
# guards themselves. This covers only the translation around them — get that
# wrong and every guard silently stops guarding under Cursor.
#
# Like that suite, file cases use a THROWAWAY temp dir rather than anything this
# workspace happens to have cloned, so the result is not tied to one org's names.

set -uo pipefail

H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$H/../.." && pwd)"
SHIM="$H/hook-shim.template.sh"
export CLAUDE_PROJECT_DIR="$ROOT"

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
[ -x "$SHIM" ] || chmod +x "$SHIM" 2>/dev/null

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Assembled, not written literally, so this file never contains the name of a
# secret file — the env guard scans command strings, including the ones that
# launch this suite.
SECRET="$TMP/scripts/tracker/.$(printf 'env')"
mkdir -p "$TMP/scripts/tracker" && printf 'TOKEN=not-a-real-secret\n' > "$SECRET"

pass=0; fail=0
check() { # check <label> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; echo "        want ~ $2"; echo "        got    $3"; fail=$((fail+1)); fi
}
GUARD='"$CLAUDE_PROJECT_DIR"/.claude/hooks/dev-wrapper/pretool-env-guard.sh'
LANG_HOOK='"$CLAUDE_PROJECT_DIR"/.claude/hooks/resolve-language.sh'
shell_call() { jq -cn --arg c "$1" --arg r "$ROOT" \
  '{hook_event_name:"preToolUse",tool_name:"Shell",tool_input:{command:$c,cwd:""},session_id:"s1",workspace_roots:[$r]}'; }
read_call()  { jq -cn --arg p "$1" --arg r "$ROOT" \
  '{hook_event_name:"preToolUse",tool_name:"Read",tool_input:{file_path:$p},session_id:"s1",workspace_roots:[$r]}'; }

echo "== a guard's block reaches Cursor as a deny =="
out=$(shell_call "cat $SECRET" | "$SHIM" "$GUARD")
check "shell dumping a secret file is denied"          '"permission":"deny"' "$out"
check "the deny carries the guard's reason to the agent" 'Blocked'           "$out"
out=$(read_call "$SECRET" | "$SHIM" "$GUARD")
check "Read of a secret file is denied"                '"permission":"deny"' "$out"
out=$(shell_call 'ls -la' | "$SHIM" "$GUARD")
check "harmless shell passes through"                  '{}'                  "$out"

echo "== injected context is re-shaped for Cursor =="
out=$(jq -cn --arg r "$ROOT" '{hook_event_name:"sessionStart",session_id:"s1",is_background_agent:false,workspace_roots:[$r]}' | "$SHIM" "$LANG_HOOK")
check "sessionStart carries additional_context"        '"additional_context"' "$out"
out=$(jq -cn --arg r "$ROOT" '{hook_event_name:"beforeSubmitPrompt",session_id:"s1",prompt:"hi",workspace_roots:[$r]}' | "$SHIM" "$LANG_HOOK")
check "beforeSubmitPrompt carries additional_context"  '"additional_context"' "$out"

echo "== beforeShellExecution carries the command at the top level =="
out=$(jq -cn --arg c "cat $SECRET" --arg r "$ROOT" \
        '{hook_event_name:"beforeShellExecution",command:$c,cwd:"",session_id:"s1",workspace_roots:[$r]}' | "$SHIM" "$GUARD")
check "the top-level command is lifted into tool_input" '"permission":"deny"' "$out"

echo "== a rewritten command survives the crossing =="
# Cursor honours a rewritten tool input as `updated_input`, on preToolUse only. Claude
# spells the same thing `hookSpecificOutput.updatedInput`; drop the translation and a
# guard that repairs a command instead of blocking it silently stops repairing it, with
# no error anywhere. A script file, not an inline string: the shim runs its argument
# through `bash -c` and a nested-quoted jq one-liner does not survive that.
REWRITER="$TMP/rewriter.sh"
cat > "$REWRITER" <<'REW'
#!/usr/bin/env bash
cat >/dev/null
jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:{command:"echo fixed"}}}'
REW
chmod +x "$REWRITER"
out=$(shell_call 'echo broken' | "$SHIM" "$REWRITER")
check "updatedInput becomes updated_input"  '"updated_input"'        "$out"
check "the rewritten command comes through" '"command":"echo fixed"' "$out"

echo "== a broken hook must not break the agent =="
out=$(shell_call 'ls' | "$SHIM" 'exit 7')
check "hook failure fails open"                        '{}' "$out"
out=$(shell_call 'ls' | "$SHIM" 'command -v definitely-not-installed >/dev/null 2>&1 || exit 0; definitely-not-installed hook claude')
check "missing third-party tool is a no-op"            '{}' "$out"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
