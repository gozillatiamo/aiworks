#!/usr/bin/env bash
#
# PreToolUse / PostToolUse / PostToolUseFailure hook — the `max` step narration, both halves of it.
#
# ONE JOB, AND A HARD LATENCY BUDGET: hand the event to scripts/voice/narrate.sh in a DETACHED
# process and return. This hook fires before AND after every tool call, so it is the most
# frequently-executed thing in the workspace: whatever it spends is spent hundreds of times a turn.
# So it reads four config values, spills the payload to a temp file, forks, and exits. No transcript
# parsing, no synthesis, no network — all of that happens in narrate.sh, off the critical path.
#
# WHY THE PAYLOAD GOES TO A FILE: the after-half's line comes from the tool's OWN response
# (`tool_response` — "cargo test ผ่าน 42", "queue.sh อ่านแล้ว 260 บรรทัด"), and that response can be
# a whole file's contents. An argv-sized copy of it would hit ARG_MAX on the first big Read; a temp
# file costs one write and the reader deletes it.
#
# ── THE PreToolUse SIDE, WHICH THIS FILE ONCE ARGUED AGAINST ────────────────────────────────
# The objection was real and is worth keeping: a PreToolUse hook sits BETWEEN the model and its
# tool, where a slow hook delays real work and a non-zero exit BLOCKS the call outright. Narration
# is the least important thing in the workspace and must never be able to do either. What makes the
# position safe is not a promise, it is the shape of this script:
#
#   • it exits 0 on every path, including every gate and every failure to read anything;
#   • `set +e` right after the source, so no single non-zero test can become a blocking exit;
#   • it prints NOTHING on stdout — a PreToolUse hook's stdout can reach the model, and a narration
#     echoed back would become part of the conversation it is describing;
#   • the work is `nohup … &`, so the hook's own runtime is four config reads and one small write.
#     The PreToolUse payload has no `tool_response`, which makes it the CHEAPER of the two calls.
#
# MEASURED on this machine, since a latency claim is worth a number: ~68 ms per call at `max`, and
# ~26 ms for anyone the feature is off for (a non-`th` workspace exits after ONE config read — the
# gates are ordered cheapest-first for exactly that reason). ~26 ms of that floor is bash starting up
# and sourcing lib.sh, so the marginal cost of this being a hook at all is most of it.
#
# And the reason to accept that at all: a result-only narrator is silent for exactly as long as the
# work takes. `max` is the level for someone who is not watching the screen, and to them a 90-second
# test run and a wedged command sound identical. The before-line is what places the wait.
#
# PostToolUseFailure is wired to the same script: a failed step is the one thing worth interrupting
# for (narrate.sh's `red` threshold), and the failure event is how it learns that cheaply instead of
# guessing from output text.
#
# Inert unless `language: th` AND voice.enabled AND voice.autoplay.enabled AND chattiness == max
# (and, for the before-half alone, voice.autoplay.narrate_intent) — the gates live in
# scripts/voice/lib.sh and narrate.sh, so this file is safe to ship committed for the whole team.
#
# Wired in .claude/settings.json under PreToolUse, PostToolUse and PostToolUseFailure, matcher "*".

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
