#!/usr/bin/env bash
# PostToolUse(Agent) — relay a sealed child instead of absorbing its partial.
#
# WHY THIS EXISTS
#   context-handoff.sh seals a subagent once its self-handoff document is written: past the
#   grace window every tool call is denied, so the only move left is to return. The child is
#   told to put the literal token HANDOFF_RELAY:<doc> in that result. Inside a WORKFLOW the
#   agent() wrapper reads the token and re-spawns the step itself. A subagent spawned from a
#   session has no such loop — the parent receives a partial and its natural next move is to
#   summarise it, which throws away the whole point: a replacement was supposed to continue
#   from the document. So the token is read here, off the Agent tool's own result, and the
#   parent is BLOCKED into re-spawning. `block` on PostToolUse does not undo the call; it puts
#   the reason in front of the model as the last thing it saw, which is the strongest thing a
#   hook can say to an agent it cannot drive.
#
#   Bounded, and bounded per (session, subagent_type): a step whose window fills faster than it
#   does work would otherwise relay forever. ponytail: subagent_type is the only stable
#   discriminator the parent's payload carries — the replacement is a new agent with a new id
#   and a different brief — so two unrelated `developer` children in one session share a
#   budget. Coarse, and the direction of the error is the safe one (fewer relays, never more).
#
# Exit 0 always: a relay hook must never break the call it rides on.
set -uo pipefail

RELAYS="${AIWORKS_HANDOFF_RELAYS:-5}"
tmp="${TMPDIR:-/tmp}"; DIR="${AIWORKS_HANDOFF_DIR:-${tmp%/}/aiworks-handoff}"

payload="$(cat 2>/dev/null)" || exit 0
sid="$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)"
[ -n "$sid" ] || exit 0

# The whole response as text: a result is sometimes a string, sometimes a structured object, and
# the token is a literal either way.
doc="$(printf '%s' "$payload" | jq -r '.tool_response // empty | tostring' 2>/dev/null \
       | grep -o 'HANDOFF_RELAY:[^ ",;)]*' | head -n 1 | cut -d: -f2-)"
[ -n "$doc" ] || exit 0

ty="$(printf '%s' "$payload" | jq -r '.tool_input.subagent_type // "agent"' 2>/dev/null)"
sdir="$DIR/${sid//[^A-Za-z0-9_.-]/_}"
ctr="$sdir/relay-${ty//[^A-Za-z0-9_.-]/_}.count"

n=0; [ -f "$ctr" ] && read -r n < "$ctr" 2>/dev/null
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
# Budget spent: the partial is the parent's to keep, and whatever the phase does with a partial
# it now does. Saying nothing is the point — a nag past its own budget is noise.
[ "$n" -le "$RELAYS" ] || exit 0
mkdir -p "$sdir" 2>/dev/null && printf '%s\n' "$n" > "$ctr" 2>/dev/null

jq -cn --arg d "$doc" --arg t "$ty" --arg n "$n" --arg m "$RELAYS" '{
  decision: "block",
  reason: ("🔁 That subagent did not finish — it was SEALED at the context ceiling and returned early on purpose. Its handoff document is at " + $d + ". Do NOT summarise its partial and do NOT continue its work yourself: re-spawn it. Spawn a NEW `" + $t + "` subagent with the SAME brief you gave the last one, plus this line: \"Read " + $d + " FIRST. It was written by your predecessor at this exact step. Verify what it claims against the repo before trusting it, then continue from its next steps — do not re-read what it says is already known.\" Relay " + $n + "/" + $m + " for this role; after that a partial is yours to keep.")
}'
exit 0
