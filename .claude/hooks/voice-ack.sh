#!/usr/bin/env bash
#
# UserPromptSubmit hook — the voice acknowledgement.
#
# TWO JOBS, AND A HARD LATENCY BUDGET
#   1. play the `ack` cue NOW, so "it heard me" is answered in ~400 ms
#   2. hand the prompt to scripts/voice/ack.sh in a DETACHED process, and return
#
# This hook sits directly in front of the user's turn: whatever it spends, the user waits.
# So it does no network work, no synthesis and no summarizing — it plays a cached file and
# forks. Everything slow happens in ack.sh, off the critical path.
#
# It prints NOTHING on stdout. A UserPromptSubmit hook's stdout is injected into the model's
# context, so a stray echo here would become part of the conversation.
#
# Inert unless `language: th` AND voice.enabled AND voice.autoplay.enabled — the gates live in
# scripts/voice/lib.sh, so this file is safe to ship committed for the whole team.
#
# Wired in .claude/settings.json alongside resolve-language.sh.

set -uo pipefail

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
lib="$root/scripts/voice/lib.sh"
[ -f "$lib" ] || exit 0

input="$(cat 2>/dev/null || true)"

# shellcheck source=../../scripts/voice/lib.sh
. "$lib" 2>/dev/null || exit 0
# lib.sh sets `-e`, which is right for a command-line script and wrong for a hook: a hook that
# aborts on the first non-zero test reports a failure to the user for something that is simply
# "no cue file yet". Turn it back off and handle failures explicitly below.
set +e

# The gates, inline rather than via voice_gate_or_exit: that helper exits 0 on failure, which
# is what we want, but we also want to skip the jq parse below when voice is off.
[ "$(voice_language)" = "th" ] || exit 0
voice_cfg_bool voice.enabled false || exit 0

# THE FOCUS SIGNAL, and the only honest one there is: a prompt just arrived HERE, so this is the
# worktree the user is working in. speak.sh reads it to drop the identity prefix for this session
# — you do not need to be told which worktree you just typed in. Recorded before the autoplay
# gate, so a hand-run `speak.sh` in a focused session is quiet about its identity too.
voice_focus_set "$VOICE_ROOT" 2>/dev/null || true

voice_cfg_bool voice.autoplay.enabled false || exit 0

command -v jq >/dev/null 2>&1 || exit 0
session="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)"
[ -n "$session" ] || session="$root"
[ -n "$prompt" ] || exit 0

# Mark the turn open. ack.sh compares against this to notice a newer prompt, and the Stop hook
# closes it so a slow ack can tell the answer already landed.
voice_turn_start "$session" 2>/dev/null || true

# The cue, detached and unconditional. It deliberately does NOT go through queue.sh: the queue
# serializes speech behind a lock, and a cue that waits for a milestone to finish speaking is
# not an acknowledgement any more. A 0.5 s cue landing under an ongoing sentence is a fair
# trade for it always being immediate.
cue="$VOICE_CUE_DIR/ack.mp3"
[ -s "$cue" ] && ( afplay "$cue" >/dev/null 2>&1 & ) 2>/dev/null

# Hand off the prompt by FILE: a prompt can be tens of kilobytes of pasted log, which is past
# what is safe to pass as an argv string.
pf="$(mktemp -t voice-ack.XXXXXX 2>/dev/null)" || exit 0
printf '%s' "$prompt" > "$pf"
# nohup, because the hook's process group goes away the moment this script returns and the
# summarizer call outlives it by seconds. The subshell owns the temp file's lifetime: ack.sh
# exits early on any of its quiet rules, and a leaked prompt file would sit in /tmp holding
# the user's text.
( nohup "$root/scripts/voice/ack.sh" --session "$session" --file "$pf" >/dev/null 2>&1
  rm -f "$pf" ) >/dev/null 2>&1 &

# NOTHING ELSE IS STARTED HERE. There used to be a long-turn heartbeat watcher — a background sleeper
# that said "still working, currently X" on a clock — and it was REMOVED, not switched off: in use it
# read as an odd, disembodied interruption, because a clock cannot know whether anything happened.
# What replaced it is per-step narration (scripts/voice/narrate.sh, on PostToolUse), which speaks
# because the WORK moved. Mid-turn speech is therefore `chattiness: max` only, and it is event-driven.
exit 0
