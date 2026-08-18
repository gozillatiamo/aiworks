#!/usr/bin/env bash
#
# hook-signal-probe.sh — one-time confirmation of a PreToolUse payload's subagent
# discriminators, for an org about to flip C7's Kickoff-arming on (docs/adr/0019).
#
# WHY: pretool-orchestrator-guard.sh's discriminator (agent_id / transcript_path
# substring "/subagents/" / CLAUDE_CODE_CHILD_SESSION=1) was measured from a
# subagent's own Bash environment in THIS session, never from inside a wired hook
# subprocess — no hook was granted in this session to prove it. This probe is the
# cheap, standalone way to close that gap on any machine, without editing the guard.
#
# HOW TO WIRE IT TEMPORARILY (a human does this, not an agent — settings is config):
#   1. Add to .claude/settings.local.json (git-ignored, personal):
#        { "hooks": { "PreToolUse": [ { "matcher": "*", "hooks": [
#          { "type": "command",
#            "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/hook-signal-probe.sh" }
#        ] } ] } }
#   2. Run ONE Bash tool call in the MAIN session.
#   3. Spawn a trivial subagent (Agent tool / Task) that runs ONE Bash tool call.
#   4. cat "${TMPDIR:-/tmp}/hook-signal-probe.log" — two lines. Compare:
#        - the MAIN line should show agent_id= (empty).
#        - the SUBAGENT line should show a non-empty agent_id.
#   5. Remove the temporary hook from settings.local.json when done.
#
# MEASURED once already (2026-08-18, macOS, org workspace) — expect the same:
#   - agent_id DISCRIMINATES: non-empty on the subagent line, empty on main.
#   - child=1 on BOTH lines — the hook process is itself a Claude-spawned child, so
#     CLAUDE_CODE_CHILD_SESSION is NOT a discriminator (the guard no longer reads it).
#   - transcript_path names the MAIN session transcript on BOTH lines.
#   - a user's own `!`-typed command ALSO fires this hook, main-shaped — which is why
#     the guard exempts the ship verbs (git merge|push); see docs/adr/0019.
# A machine where the MAIN line shows a non-empty agent_id, or the SUBAGENT line an
# empty one, breaks the guard's discriminator — report it before trusting the guard.
#
# Reads the hook payload from stdin, appends one line, exits 0. Never blocks.

set -uo pipefail

input=$(cat 2>/dev/null) || exit 0

if command -v jq >/dev/null 2>&1; then
  agent_id=$(printf '%s' "$input" | jq -r '.agent_id // ""' 2>/dev/null)
  agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""' 2>/dev/null)
  session_id=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)
  transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null)
else
  agent_id="(jq missing)"; agent_type="(jq missing)"; session_id="(jq missing)"; transcript_path="(jq missing)"
fi

log="${TMPDIR:-/tmp}/hook-signal-probe.log"
printf '%s|%s|%s|%s|child=%s\n' "$agent_id" "$agent_type" "$session_id" "$transcript_path" "${CLAUDE_CODE_CHILD_SESSION:-}" >> "$log" 2>/dev/null

exit 0
