#!/usr/bin/env bash
#
# The step narrator — "here is what I am doing, and what I am about to do", spoken WHILE the turn
# runs. `voice.autoplay.chattiness: max` only. Runs DETACHED, spawned by
# .claude/hooks/voice-narrate.sh on PostToolUse.
#
# Usage:
#   narrate.sh [-v] --session ID --transcript PATH
#
# ── WHAT IT SPEAKS, AND WHY THAT COSTS NOTHING ─────────────────────────────────────
# The assistant already writes one short line before it reaches for a tool — "อ่าน queue ก่อน
# แล้วค่อยแก้ cadence". That line IS the narration: it says what is happening and what comes next,
# in the assistant's own words, and it is already in the transcript. So this speaks it verbatim
# (trimmed) instead of asking a model to invent a description of a tool call.
#
#   no summarizer call   the text exists — a per-step LLM call would cost more than the ack and
#                        the closing line together on a long turn
#   cannot drift         it is the assistant's own sentence, not a guess about what a tool did
#   no tool vocabulary   "Read summarize.sh" is what a machine would say; the prose is what a
#                        person would say, and it explains WHY the file is being read
#
# The fallback, when several tool calls go by with no prose at all, is the last tool activity as a
# template ("กำลัง <activity>") — thin but true, and it keeps a long silent stretch from being
# silent. This extraction came from the timed heartbeat that used to hold this space, and outlived it.
#
# ── WHY IT IS NOT A TIMER (the first `max` was, and it was wrong) ───────────────────
# A clock fires whether or not anything happened: it narrates a 3-second step never and a 90-second
# step twice, and it can only name the tool it happens to catch, never why. Steps are the unit `max`
# is about, so the hook fires on the step. That heartbeat has since been DELETED — in use it read as
# an odd, disembodied interruption — so this is the only mid-turn voice in the feature.
#
# ── THE THREE RULES THAT KEEP IT FROM BECOMING NOISE ───────────────────────────────
#   dedupe   one prose block introduces several tool calls (~1 block per 5 calls, measured), so
#            the same line would otherwise be spoken five times. Hash-compared, per session.
#   rate     MIN_GAP seconds between utterances. Tool calls fire several per second while a spoken
#            line takes seconds — without a floor the queue takes on work faster than it drains.
#   stale    a narration is dropped by the queue if it waits too long: "กำลังอ่าน X" arriving
#            after X is finished and two steps have passed is worse than silence. Hence its own
#            queue kind, with a tighter staleness than an ack.
#
# It stays quiet when the turn has ENDED, too: the closing line owns the end of a turn, and a step
# narration landing after the result would describe work the user has already been told about.

set -euo pipefail
VOICE_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$VOICE_SELF_DIR/lib.sh"

MIN_GAP=9          # seconds between narrations — a spoken line is ~3-6 s, so this leaves air
MAX_CHARS=120      # ~8 s of Thai speech. A step narration must be shorter than the step
MIN_CHARS=12       # below this there is no sentence, only a fragment

SESSION="" TRANSCRIPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) export VOICE_VERBOSE=1; shift ;;
    --session)    SESSION="${2:-}"; shift 2 ;;
    --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
    -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; exit 0 ;;
    *)            vdie "unknown option $1 (see -h)" ;;
  esac
done

voice_gate_or_exit "narrate"
voice_cfg_bool voice.autoplay.enabled false || { vlog "narrate skipped: autoplay off"; exit 0; }
# Its own switch, so the running commentary can be turned off without leaving `max`: it is the
# loudest thing this feature does, and the ack/closing-line lengths are worth keeping on their own.
voice_cfg_bool voice.autoplay.narrate true || { vlog "narrate skipped: voice.autoplay.narrate is false"; exit 0; }
[[ "$(voice_chattiness)" == "max" ]] || { vlog "narrate skipped: chattiness is $(voice_chattiness), not max"; exit 0; }
voice_is_muted && { vlog "narrate: muted — nothing synthesized"; exit 0; }
[[ -n "$SESSION" ]] || SESSION="$VOICE_ROOT"
[[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || { vlog "narrate: no readable transcript"; exit 0; }
voice_require jq

# ── the turn must still be open ───────────────────────────────────────────────────
TURN="$(voice_turn_get "$SESSION" turn)"
ENDED="$(voice_turn_get "$SESSION" ended)"
if [[ "$ENDED" -ge "$TURN" && "$TURN" -gt 0 ]]; then
  vlog "narrate: the turn already ended — the closing line owns this"
  exit 0
fi

# ── the rate floor, checked before anything is read or synthesized ─────────────────
LAST_TS="$(voice_narrate_get "$SESSION" ts)"
NOW="$(voice_now)"
if [[ "$LAST_TS" -gt 0 ]] && (( NOW - LAST_TS < MIN_GAP )); then
  vlog "narrate: $((NOW - LAST_TS))s since the last line, floor is ${MIN_GAP}s — skipping"
  exit 0
fi

# ── the assistant's own last prose block ──────────────────────────────────────────
# Text and tool_use never share one assistant message (measured: 0 of 2 534 messages in a real
# session had both), so the prose is its own entry immediately before the tool it introduces —
# which means "the last text block in the file" is exactly the line that explains the step that
# just ran.
_last_prose() {
  jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text]
          | last // ""' "$TRANSCRIPT" 2>/dev/null || printf ''
}

# The tool-activity fallback, for a stretch with no prose at all.
_last_activity() {
  jq -rs '
    [.[] | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")] | last
    | if . == null then ""
      elif .name == "Bash"      then (.input.description // (.input.command // "" | .[0:60]))
      elif .name == "Task"      then ("agent: " + (.input.description // ""))
      elif (.name | test("^(Read|Edit|Write|NotebookEdit)$")) then
        (.name + " " + ((.input.file_path // "") | split("/") | last))
      elif (.name | test("^(Grep|Glob)$")) then (.name + " " + (.input.pattern // ""))
      elif (.name | startswith("mcp__")) then (.name | split("__") | .[1:] | join(" "))
      else .name end
    | gsub("[\"`]"; "") | .[0:70]
  ' "$TRANSCRIPT" 2>/dev/null || printf ''
}

# ── prose → one speakable line ────────────────────────────────────────────────────
# Written for the eye, spoken by an engine: fences, tables and list markers are read out as
# punctuation noise, and a heading is not a sentence. Backtick CONTENT is kept — an identifier is
# usually the most informative word in the line — while the backticks themselves go.
#
# Only the FIRST sentence survives — the prose block can be a paragraph, and a step narration has
# to be over before the step is.
#
# …EXCEPT when that sentence carries nothing. Measured against this workspace's own transcript: an
# em dash is used mid-sentence constantly here, so a plain "first chunk" rule produced "both: 0"
# (7 characters, from "`both: 0` — prose กับ tool_use เป็น assistant message แยกกัน…") and
# "Memory เก็บแล้ว ทีนี้ max" — one meaningless, one with its point amputated. So chunks are
# ACCUMULATED until there is enough to be worth hearing, and the character cap trims the tail. A
# too-short line is the worse failure: a long one is merely cut, a thin one says nothing at all.
_speakable() {   # TEXT → one line, or nothing
  printf '%s' "$1" | python3 -c '
import re, sys
t = sys.stdin.read()
t = re.sub(r"```.*?```", " ", t, flags=re.S)          # fenced code: never speakable
t = re.sub(r"^\s*\|.*$", " ", t, flags=re.M)          # table rows
t = re.sub(r"^\s{0,3}#{1,6}\s*", "", t, flags=re.M)   # heading marks (keep the words)
t = re.sub(r"^\s*[-*+]\s+", "", t, flags=re.M)        # list markers
t = re.sub(r"^\s*\d+\.\s+", "", t, flags=re.M)        # ordered list markers
t = t.replace("`", "").replace("**", "").replace("__", "")
t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", t)        # links: say the label, not the URL
t = re.sub(r"<[^>]{1,40}>", " ", t)                   # stray tags
t = re.sub(r"\s+", " ", t).strip()
# Thai has no full stop, so a newline, an em dash or a colon ends a sentence here too — and those
# are what this prose actually uses. Take chunks until the line carries something.
ENOUGH = 25
line = ""
for part in re.split(r"(?<=[.!?])\s+|\s+[—:·]\s+", t):
    part = part.strip(" -—:·,")
    if not part:
        continue
    line = part if not line else line + " " + part
    if len(line) >= ENOUGH:
        break
sys.stdout.write(line[:400])
' 2>/dev/null || true
}

RAW="$(_last_prose)"
SRC=prose
LINE="$(_speakable "$RAW")"
if [[ "$(printf '%s' "$LINE" | wc -m | tr -d ' ')" -lt "$MIN_CHARS" ]]; then
  act="$(_last_activity)"
  [[ -n "$act" ]] || { vlog "narrate: no prose and no activity — nothing to say"; exit 0; }
  LINE="กำลัง $act"
  SRC=activity
fi

# A `VOICE[...]` tag is the CLOSING line's mechanism — speaking it mid-turn would announce the
# result before the work is done, twice.
case "$LINE" in *VOICE\[*|*VOICE:*) vlog "narrate: that block is a VOICE tag — the closing line owns it"; exit 0 ;; esac

# Cap by CHARACTERS, not bytes: Thai is multibyte and ${#} would cut a 40-character line at 120
# bytes, mid-syllable. Cut at a word boundary when there is one nearby.
if [[ "$(printf '%s' "$LINE" | wc -m | tr -d ' ')" -gt "$MAX_CHARS" ]]; then
  LINE="$(printf '%s' "$LINE" | python3 -c '
import sys
s = sys.stdin.read()
n = '"$MAX_CHARS"'
cut = s[:n]
sp = cut.rfind(" ")
sys.stdout.write(cut if sp < n * 0.6 else cut[:sp])
' 2>/dev/null || printf '%s' "$LINE")"
fi

# ── dedupe: has this exact line already been spoken this session? ──────────────────
HASH="$(voice_sha "$(voice_normalize_text "$LINE")")"
if [[ "$HASH" == "$(voice_narrate_get "$SESSION" hash)" ]]; then
  vlog "narrate: same line as last time ($SRC) — skipping"
  exit 0
fi

# Recorded BEFORE speaking, not after: two PostToolUse hooks can land in the same second, and the
# loser of that race must see the winner's hash rather than both queuing the same sentence.
voice_narrate_set "$SESSION" "$HASH"
vlog "narrate[$SRC]: $LINE"

# --kind narration: its own queue class, dropped harder than an ack (see queue.sh). No cue — a
# sound before every step would be a metronome — and no identity prefix logic beyond the usual.
exec "$VOICE_SELF_DIR/speak.sh" --kind narration "$LINE"
