#!/usr/bin/env bash
#
# PostToolUse hook (matcher "*") — stagehand: put what the tool just touched ON SCREEN.
#
# Thin by design, exactly like voice-narrate.sh / voice-gate.sh: spill the payload to a temp
# file, fork scripts/stagehand/show.sh detached, exit. All the real work (AppleScript round
# trips, window enumeration, placement) happens off the hook's clock — a hook that blocked for
# a second would be felt on EVERY tool call, which is every few seconds all day.
#
# Prints NOTHING on stdout and always exits 0. A window placer must never be the reason a tool
# call reports failure, and PostToolUse stdout is context the model would then have to read.
#
# Inert unless stagehand.enabled AND this is the ROOT worktree (a linked/Superset worktree shares
# the same physical screen and would fight this one for it). Both gates live in
# scripts/stagehand/lib.sh — kept there, not here, so the CLI and the hook can never disagree
# about when the feature is on.
#
# Wired in .claude/settings.json under PostToolUse, matcher "*".

set -uo pipefail

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
show="$root/scripts/stagehand/show.sh"
[ -x "$show" ] || exit 0

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

payload="$(mktemp "${TMPDIR:-/tmp}/stagehand.XXXXXX" 2>/dev/null || true)"
[ -n "$payload" ] || exit 0
printf '%s' "$input" > "$payload" 2>/dev/null

( nohup "$show" --payload "$payload" >/dev/null 2>&1 ) >/dev/null 2>&1 &

exit 0
