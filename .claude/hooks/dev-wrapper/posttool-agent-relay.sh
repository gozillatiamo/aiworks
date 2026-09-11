#!/usr/bin/env bash
# SubagentStop + PostToolUse(*) — relay a sealed child instead of absorbing its partial.
#
# WHY THIS EXISTS
#   context-handoff.sh seals a subagent once its self-handoff document is written: past the grace
#   window every tool call is denied, so the only move left is to return. The child is told to put
#   the literal token HANDOFF_RELAY:<doc> in that result. Inside a WORKFLOW the agent() wrapper
#   reads the token off the value it awaited and re-spawns the step itself. A subagent spawned from
#   a session has no such loop — the parent receives a partial and its natural next move is to
#   summarise it, which throws the point away: a replacement was supposed to continue from the
#   document. So the token is read here and the parent is BLOCKED into re-spawning.
#
# WHY TWO EVENTS, measured rather than assumed (scripts/hook-relay-probe.sh, 2026-09-11):
#   • The Agent tool launches ASYNCHRONOUSLY. Its PostToolUse fires at LAUNCH: `tool_response` is
#     launch metadata and `tool_input` still holds the brief. Reading the child's result there
#     finds nothing — and reading the payload at large finds the BRIEF, so a brief that merely
#     mentions the token relays a child that never ran. Both were observed.
#   • SubagentStop fires at completion and carries `last_assistant_message` — the child's own final
#     text, and none of the brief. That is the only field read here.
#
# WHY SubagentStop NEVER ANSWERS
#   On a Stop event `decision: block` means "do not stop", and it is fed to the agent that was
#   about to end — here a SEALED one, every tool of which is denied. It would spin against a closed
#   seal. So SubagentStop only RECORDS a pending relay; the parent's next tool call is what gets
#   told, on an event that actually addresses the parent.
#
#   Bounded per (session, agent_type): a step whose window fills faster than it does work would
#   otherwise relay forever. ponytail: agent_type is the coarsest honest key — the replacement is a
#   new agent with a new id — so two unrelated children of one role share a budget. The error runs
#   toward fewer relays, never more.
#
# Exit 0 always: a relay hook must never break the call it rides on.
set -uo pipefail

RELAYS="${AIWORKS_HANDOFF_RELAYS:-5}"
tmp="${TMPDIR:-/tmp}"; DIR="${AIWORKS_HANDOFF_DIR:-${tmp%/}/aiworks-handoff}"

payload="$(cat 2>/dev/null)" || exit 0
ev="$(printf '%s' "$payload" | jq -r '.hook_event_name // "PostToolUse"' 2>/dev/null)" || exit 0
sid="$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)"
[ -n "$sid" ] || exit 0
sdir="$DIR/${sid//[^A-Za-z0-9_.-]/_}"
pend="$sdir/pending-relay"

# ── SubagentStop: the child has ended. Record a pending relay; say nothing.
if [ "$ev" = "SubagentStop" ]; then
  doc="$(printf '%s' "$payload" | jq -r '.last_assistant_message // ""' 2>/dev/null \
         | grep -o 'HANDOFF_RELAY:[^ ",;)]*' | head -n 1 | cut -d: -f2-)"
  [ -n "$doc" ] || exit 0
  ty="$(printf '%s' "$payload" | jq -r '.agent_type // "agent"' 2>/dev/null)"
  ty="${ty//[^A-Za-z0-9_.-]/_}"
  mkdir -p "$pend" 2>/dev/null && printf '%s\n' "$doc" > "$pend/$ty" 2>/dev/null
  exit 0
fi

# ── PostToolUse: the parent's next tool call. A subagent is never told to relay its sibling.
[ -d "$pend" ] || exit 0
[ -z "$(printf '%s' "$payload" | jq -r '.agent_id // ""' 2>/dev/null)" ] || exit 0

marker="$(ls "$pend" 2>/dev/null | head -n 1)"
[ -n "$marker" ] || exit 0
doc=""; [ -f "$pend/$marker" ] && read -r doc < "$pend/$marker" 2>/dev/null
rm -f "$pend/$marker" 2>/dev/null          # one directive per sealed child, never re-served
[ -n "$doc" ] || exit 0

ctr="$sdir/relay-$marker.count"
n=0; [ -f "$ctr" ] && read -r n < "$ctr" 2>/dev/null
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
# Budget spent: the partial is the parent's to keep, and whatever it does with a partial it now
# does. Saying nothing is the point — a nag past its own budget is noise.
[ "$n" -le "$RELAYS" ] || exit 0
printf '%s\n' "$n" > "$ctr" 2>/dev/null

jq -cn --arg d "$doc" --arg t "$marker" --arg n "$n" --arg m "$RELAYS" '{
  decision: "block",
  reason: ("🔁 That subagent did not finish — it was SEALED at the context ceiling and returned early on purpose. Its handoff document is at " + $d + ". Do NOT summarise its partial and do NOT continue its work yourself: re-spawn it. Spawn a NEW `" + $t + "` subagent with the SAME brief you gave the last one, plus this line: \"Read " + $d + " FIRST. It was written by your predecessor at this exact step. Verify what it claims against the repo before trusting it, then continue from its next steps — do not re-read what it says is already known.\" Relay " + $n + "/" + $m + " for this role; after that a partial is yours to keep.")
}'
exit 0
