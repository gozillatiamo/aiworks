#!/usr/bin/env bash
#
# PostToolUse hook — the `max` step narration.
#
# ONE JOB, AND A HARD LATENCY BUDGET: hand the transcript path to scripts/voice/narrate.sh in a
# DETACHED process and return. This hook fires after EVERY tool call, so it is the most
# frequently-executed thing in the workspace: whatever it spends is spent hundreds of times a turn.
# So it reads three config values, forks, and exits. No transcript parsing, no synthesis, no
# network — all of that happens in narrate.sh, off the critical path.
#
# WHY PostToolUse RATHER THAN PreToolUse, given that the line it speaks describes what is ABOUT to
# happen: the prose it reads is written BEFORE the tool call either way, so both events see the same
# text — but a PreToolUse hook sits between the model and its tool, where a slow or wedged hook
# delays real work and a non-zero exit can block the call outright. Narration is the least important
# thing here; it does not belong in that position.
#
# It prints NOTHING on stdout. A PostToolUse hook's stdout can reach the model's context, and a
# narration echoed back would become part of the conversation it is describing.
#
# Inert unless `language: th` AND voice.enabled AND voice.autoplay.enabled AND
# chattiness == max — the gates live in scripts/voice/lib.sh and narrate.sh, so this file is safe
# to ship committed for the whole team.
#
# Wired in .claude/settings.json under PostToolUse with matcher "*".

set -uo pipefail

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
lib="$root/scripts/voice/lib.sh"
[ -f "$lib" ] || exit 0

input="$(cat 2>/dev/null || true)"

# shellcheck source=../../scripts/voice/lib.sh
. "$lib" 2>/dev/null || exit 0
# lib.sh sets `-e`, which is right for a script and wrong for a hook — a hook that aborts on the
# first non-zero test reports a failure for something that is simply "voice is off".
set +e

# The cheapest gates first, in the order that rejects the most sessions for the least work: a
# non-`th` workspace never reads the second key, and a workspace with voice off never reads the
# third. `chattiness` is checked here as well as in narrate.sh so that at every OTHER level this
# hook costs one config read and a process exit, never a fork.
[ "$(voice_language)" = "th" ] || exit 0
voice_cfg_bool voice.enabled false || exit 0
voice_cfg_bool voice.autoplay.enabled false || exit 0
[ "$(voice_chattiness)" = "max" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
session="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
[ -n "$session" ] || session="$root"
[ -n "$transcript" ] || exit 0

# nohup + a detached subshell: this hook's process group goes away the moment it returns, and the
# synthesis it triggers outlives it by seconds. Nothing is passed by file — the transcript is
# already one — so there is no temp file to own.
( nohup "$root/scripts/voice/narrate.sh" --session "$session" --transcript "$transcript" \
    >/dev/null 2>&1 ) >/dev/null 2>&1 &

exit 0
