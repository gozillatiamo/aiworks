#!/usr/bin/env bash
# PostToolUse(*) — warn when the session's context window has grown expensive.
#
# WHY THIS EXISTS
#   Cache read is billed per request at the FULL window size:
#
#       cache_read = Σ (window size) over every request
#
#   A high cache-hit rate does not reduce that sum — it only means the sum is billed at the
#   discounted tier instead of the 10× one. So a session that drifts to a 700k window pays
#   4.7× per turn for the same work as one held at 150k, and no amount of cache efficiency
#   touches it. The only two levers are FEWER requests and a SMALLER window.
#
#   Measured over 7 days on the workspace this was written for: 3,112 requests, 730.7M cache
#   read, mean window 234,805 tokens. Requests above a 150k window were 53% of the count and
#   84% of the spend; a single session that drifted to 709k was 56% of the week's total.
#   Capping every request at 150k would have cut cache read 44%.
#
#   Nothing in a normal working loop surfaces the window until it is already large — the
#   status line shows headroom remaining, not what the last turn cost. This prints the number
#   at the moment it starts to matter, with the one action that fixes it.
#
# Advisory, never blocking: exit 0 always. Prints to stderr so it lands in the transcript.
# Throttled to one line per 50k crossed, so a long session gets a handful of nudges, not a
# warning on every tool call.
#
#   --check <n>   print the verdict for a window of n tokens and exit; used by the selftest.
set -uo pipefail

WARN="${AIWORKS_CONTEXT_WARN:-150000}"
ALARM="${AIWORKS_CONTEXT_ALARM:-300000}"
BUCKET=50000

# Render the advice for a window size. Split out so the selftest can assert on the text
# without having to build a transcript.
verdict() {  # $1=window
  local w="$1"
  if [ "$w" -ge "$ALARM" ]; then
    printf '⛔ context window %sk — every further turn bills %sk of cache read.\n' \
           "$((w / 1000))" "$((w / 1000))"
    printf '   At this size the window itself, not the work, is the bill. Run /compact now,\n'
    printf '   or finish this thread and start a fresh session (which re-bases to ~82k).\n'
  elif [ "$w" -ge "$WARN" ]; then
    printf '⚠️  context window %sk — past the %sk point where cache read starts to dominate.\n' \
           "$((w / 1000))" "$((WARN / 1000))"
    printf '   Compact soon, or push the next fan-out read into a subagent so its bytes never\n'
    printf '   land here. A turn at 700k costs 4.7× the same turn at 150k.\n'
  fi
}

if [ "${1:-}" = "--check" ]; then
  verdict "${2:-0}"
  exit 0
fi

payload="$(cat)"
tp="$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)"
aid="$(printf '%s' "$payload" | jq -r '.agent_id // ""' 2>/dev/null)"

# The payload names the MAIN transcript even inside a subagent; the resolver finds the caller's
# own file, and the measurement is the newest row that actually billed (lib-context-window.sh).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-context-window.sh"
win="$(window_of "$(own_transcript "$tp" "$aid")")"
[ "$win" -ge "$WARN" ] || exit 0

# Throttle: one line per bucket crossed, per session. Without this the same warning would
# print on every tool call for the rest of a long session and become invisible.
sid="$(printf '%s' "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)"
key="${sid}-${aid:-main}"
state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.context-budget-${key//[^A-Za-z0-9_-]/_}"
now=$((win / BUCKET))
last=0
[ -f "$state" ] && read -r last < "$state" 2>/dev/null
case "$last" in ''|*[!0-9]*) last=0 ;; esac
[ "$now" -gt "$last" ] || exit 0
printf '%s\n' "$now" > "$state" 2>/dev/null

verdict "$win" >&2
exit 0
