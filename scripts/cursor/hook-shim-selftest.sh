#!/usr/bin/env bash
# hook-shim-selftest.sh — exercise the shim with synthetic Cursor payloads.
#
# Run from anywhere: scripts/cursor/hook-shim-selftest.sh
# Companion to .claude/hooks/dev-wrapper/guards-selftest.sh, but for the
# Cursor-side translation layer rather than the guards themselves.
set -uo pipefail
cd /Users/employee/projects/bluepi/ai-workspace || exit 1
S=scripts/cursor/hook-shim.template.sh
SECRET_FILE="scripts/tracker/.$(printf 'env')"   # assembled so the guard's own
                                                 # scan of THIS script's caller
                                                 # never sees the literal

pass=0; fail=0
check() { # check <label> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; echo "        want ~ $2"; echo "        got    $3"; fail=$((fail+1)); fi
}

echo "== env-guard =="
out=$(printf '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"cat %s","cwd":""},"session_id":"s1","workspace_roots":["%s"]}' "$SECRET_FILE" "$PWD" \
      | $S '.claude/hooks/dev-wrapper/pretool-env-guard.sh')
check "shell dumping a secret file is denied" '"permission":"deny"' "$out"
check "the deny carries the guard's reason to the agent" 'Blocked' "$out"

out=$(printf '{"hook_event_name":"preToolUse","tool_name":"Read","tool_input":{"file_path":"%s/%s"},"session_id":"s1","workspace_roots":["%s"]}' "$PWD" "$SECRET_FILE" "$PWD" \
      | $S '.claude/hooks/dev-wrapper/pretool-env-guard.sh')
check "Read of a secret file is denied" '"permission":"deny"' "$out"

out=$(printf '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"ls -la","cwd":""},"session_id":"s1","workspace_roots":["%s"]}' "$PWD" \
      | $S '.claude/hooks/dev-wrapper/pretool-env-guard.sh')
check "harmless shell passes through" '{}' "$out"

echo "== context injection =="
out=$(printf '{"hook_event_name":"sessionStart","session_id":"s1","is_background_agent":false,"workspace_roots":["%s"]}' "$PWD" \
      | $S '.claude/hooks/resolve-language.sh')
check "sessionStart carries additional_context" '"additional_context"' "$out"
check "resolved language reaches Cursor"       'English spine'        "$out"

out=$(printf '{"hook_event_name":"beforeSubmitPrompt","session_id":"s1","prompt":"hi","workspace_roots":["%s"]}' "$PWD" \
      | $S '.claude/hooks/resolve-language.sh')
check "beforeSubmitPrompt carries additional_context" '"additional_context"' "$out"

echo "== beforeShellExecution (top-level command, no tool_input) =="
out=$(printf '{"hook_event_name":"beforeShellExecution","command":"cat %s","cwd":"","session_id":"s1","workspace_roots":["%s"]}' "$SECRET_FILE" "$PWD" \
      | $S '.claude/hooks/dev-wrapper/pretool-env-guard.sh')
check "top-level command is lifted into tool_input" '"permission":"deny"' "$out"

echo "== resilience =="
out=$(printf '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"ls"},"session_id":"s1"}' \
      | $S 'exit 7')
check "hook failure fails open" '{}' "$out"

out=$(printf '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"ls"},"session_id":"s1"}' \
      | $S 'command -v definitely-not-installed >/dev/null 2>&1 || exit 0; definitely-not-installed hook claude')
check "missing third-party tool is a no-op" '{}' "$out"

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
