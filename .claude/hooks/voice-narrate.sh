#!/usr/bin/env bash
#
# PostToolUse / PostToolUseFailure hook — the `max` step narration.
#
# ONE JOB, AND A HARD LATENCY BUDGET: hand the event to scripts/voice/narrate.sh in a DETACHED
# process and return. This hook fires after EVERY tool call, so it is the most frequently-executed
# thing in the workspace: whatever it spends is spent hundreds of times a turn. So it reads three
# config values, spills the payload to a temp file, forks, and exits. No transcript parsing, no
# synthesis, no network — all of that happens in narrate.sh, off the critical path.
#
# WHY THE PAYLOAD GOES TO A FILE: what the narrator speaks now comes from the tool's OWN response
# (`tool_response` — "cargo test ผ่าน 42", "queue.sh อ่านแล้ว 260 บรรทัด"), and that response can be
# a whole file's contents. An argv-sized copy of it would hit ARG_MAX on the first big Read; a temp
# file costs one write and the reader deletes it.
#
# WHY PostToolUse RATHER THAN PreToolUse: a PreToolUse hook sits between the model and its tool,
# where a slow or wedged hook delays real work and a non-zero exit can block the call outright.
# Narration is the least important thing here; it does not belong in that position. And the facts it
# speaks only exist AFTER the call.
#
# PostToolUseFailure is wired to the same script: a failed step is the one thing worth interrupting
# for (narrate.sh's `red` threshold), and the failure event is how it learns that cheaply instead of
# guessing from output text.
#
# It prints NOTHING on stdout. A PostToolUse hook's stdout can reach the model's context, and a
# narration echoed back would become part of the conversation it is describing.
#
# Inert unless `language: th` AND voice.enabled AND voice.autoplay.enabled AND chattiness == max —
# the gates live in scripts/voice/lib.sh and narrate.sh, so this file is safe to ship committed for
# the whole team.
#
# Wired in .claude/settings.json under PostToolUse and PostToolUseFailure, matcher "*".

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
event="$(printf '%s' "$input" | jq -r '.hook_event_name // "PostToolUse"' 2>/dev/null || true)"
[ -n "$session" ] || session="$root"
[ -n "$event" ] || event=PostToolUse

# The payload file is owned by narrate.sh, which deletes it (trap EXIT) — including on every early
# gate return, so a turn that narrates nothing still leaves no litter.
payload=""
if [ -n "$input" ]; then
  payload="$(mktemp "${TMPDIR:-/tmp}/voice-narrate.XXXXXX" 2>/dev/null || true)"
  [ -n "$payload" ] && printf '%s' "$input" > "$payload" 2>/dev/null
fi

# nohup + a detached subshell: this hook's process group goes away the moment it returns, and the
# synthesis it triggers outlives it by seconds.
( nohup "$root/scripts/voice/narrate.sh" --session "$session" --event "$event" \
    ${transcript:+--transcript "$transcript"} ${payload:+--payload "$payload"} \
    >/dev/null 2>&1 ) >/dev/null 2>&1 &

exit 0
