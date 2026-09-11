#!/usr/bin/env bash
# hook-relay-probe.sh — TEMPORARY. Dumps whole hook payloads so the parent-side relay can be
# wired to an event that actually carries a finished subagent's result.
#
# Measured question (docs/adr/0037): posttool-agent-relay.sh reads HANDOFF_RELAY off the Agent
# tool's PostToolUse `tool_response`. When the Agent tool launches ASYNCHRONOUSLY that response is
# launch metadata and the real result arrives later, so the hook never fires. This probe records
# every payload for the candidate events, with their keys, so the answer is read rather than
# guessed.
#
# Wire in .claude/settings.local.json (git-ignored), run one subagent, then read the log:
#   "$TMPDIR/hook-relay-probe.log"
set -uo pipefail
log="${TMPDIR:-/tmp}/hook-relay-probe.log"
payload="$(cat 2>/dev/null)"
{
  printf '=== %s ===\n' "$(date -u +%H:%M:%S)"
  printf '%s' "$payload" | jq -c '{event: .hook_event_name, keys: (keys), agent_id: (.agent_id // null), has_relay_token: ((tostring | test("HANDOFF_RELAY")))}' 2>/dev/null
  printf '%s' "$payload" | head -c 1200
  printf '\n'
} >> "$log" 2>/dev/null
exit 0
