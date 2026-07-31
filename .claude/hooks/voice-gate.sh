#!/usr/bin/env bash
#
# PermissionRequest / PermissionDenied / PreToolUse(ExitPlanMode) / Notification hook —
# the spoken GATE: "this is waiting for you".
#
# Thin by design, like voice-narrate.sh: spill the payload, fork scripts/voice/gate.sh detached,
# exit. Two of these events sit in front of a decision the user is about to make, so a hook that
# blocked for a second would be felt every time.
#
# It prints NOTHING on stdout and always exits 0 — a PermissionRequest hook can influence the
# decision, and a voice adapter must never be the reason a tool call is allowed or refused.
#
# Inert unless `language: th` AND voice.enabled AND voice.autoplay.enabled AND
# voice.autoplay.gates (the gates switch is independent of `chattiness` — a gate is a WHETHER,
# not a HOW MUCH). Safe to ship committed for the whole team.
#
# Wired in .claude/settings.json under PermissionRequest, PermissionDenied, Notification (matcher
# "*") and PreToolUse (matcher "ExitPlanMode").

set -uo pipefail

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
lib="$root/scripts/voice/lib.sh"
[ -f "$lib" ] || exit 0

input="$(cat 2>/dev/null || true)"

# shellcheck source=../../scripts/voice/lib.sh
. "$lib" 2>/dev/null || exit 0
set +e

[ "$(voice_language)" = "th" ] || exit 0
voice_cfg_bool voice.enabled false || exit 0
voice_cfg_bool voice.autoplay.enabled false || exit 0
voice_cfg_bool voice.autoplay.gates true || exit 0

command -v jq >/dev/null 2>&1 || exit 0
session="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
[ -n "$session" ] || session="$root"
[ -n "$event" ] || exit 0

payload=""
if [ -n "$input" ]; then
  payload="$(mktemp "${TMPDIR:-/tmp}/voice-gate.XXXXXX" 2>/dev/null || true)"
  [ -n "$payload" ] && printf '%s' "$input" > "$payload" 2>/dev/null
fi

( nohup "$root/scripts/voice/gate.sh" --session "$session" --event "$event" \
    ${payload:+--payload "$payload"} >/dev/null 2>&1 ) >/dev/null 2>&1 &

exit 0
