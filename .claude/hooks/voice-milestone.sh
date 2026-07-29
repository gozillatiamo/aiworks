#!/usr/bin/env bash
#
# Stop hook — voice milestones.
#
# TWO JOBS
#   1. Close the turn. That single timestamp is what lets a slow ack notice the answer already
#      landed and stay quiet — speaking "กำลังไปดู commission calculator" three seconds after
#      the answer is on screen is worse than saying nothing at all. It is also what stops the
#      heartbeat watcher. This half runs even when speech is switched off: it is bookkeeping,
#      and an ack that cannot tell whether the turn ended is worse than no ack.
#   2. Hand the finished turn to scripts/voice/milestone.sh, DETACHED, which decides whether
#      anything happened worth saying (it stays silent unless the reply carried a `VOICE:` tag
#      or matched a narrow keyword backstop — most turns are conversation).
#
# Prints nothing, returns fast, and is inert unless `language: th` and voice.enabled.

set -uo pipefail

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
lib="$root/scripts/voice/lib.sh"
[ -f "$lib" ] || exit 0

input="$(cat 2>/dev/null || true)"

# shellcheck source=../../scripts/voice/lib.sh
. "$lib" 2>/dev/null || exit 0
set +e   # lib.sh sets -e; a hook must not abort the moment a test returns non-zero

# NOT gated on voice.autoplay.enabled: closing the turn is bookkeeping, and the ack path needs
# the marker to be honest even when the ack itself is switched off.
[ "$(voice_language)" = "th" ] || exit 0
voice_cfg_bool voice.enabled false || exit 0

command -v jq >/dev/null 2>&1 || exit 0
session="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
[ -n "$session" ] || session="$root"

# Job 1 first, and unconditionally — a milestone that fails must not leave the turn open.
voice_turn_end "$session" 2>/dev/null || true

# Job 2. Detached: classification may call the summarizer and then TTS, which is seconds of
# work, and a Stop hook that blocks on it delays the prompt coming back.
[ -n "$transcript" ] || exit 0
( nohup "$root/scripts/voice/milestone.sh" --session "$session" --transcript "$transcript" \
    >/dev/null 2>&1 ) >/dev/null 2>&1 &

exit 0
