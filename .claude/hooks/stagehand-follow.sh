#!/usr/bin/env bash
#
# Stop hook — stagehand: point the screen at what the reply just TALKED ABOUT.
#
# The PostToolUse hook (stagehand-show.sh) covers what a tool touched. This one covers the rest:
# the subjects a turn only discussed — an MR it flagged as stale, a ticket it said spans three
# repos, a file it explained. Stop is the one event that has the finished reply in hand.
#
# Thin, same as every other hook here: fork scripts/stagehand/follow.sh detached and exit 0. It
# reads the transcript itself rather than being handed text, so nothing large crosses the pipe.
#
# Prints NOTHING and always exits 0. A Stop hook that wrote to stdout would inject text into the
# turn's tail, and one that failed loudly would turn a cosmetic feature into a broken session.
#
# Inert unless stagehand.enabled AND stagehand.triggers.narration AND this is the ROOT worktree —
# all three gates live in scripts/stagehand/lib.sh.
#
# Wired in .claude/settings.json under Stop, matcher "*".

set -uo pipefail

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
follow="$root/scripts/stagehand/follow.sh"
[ -x "$follow" ] || exit 0

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
[ -n "$transcript" ] || exit 0

( nohup "$follow" --transcript "$transcript" >/dev/null 2>&1 ) >/dev/null 2>&1 &

exit 0
