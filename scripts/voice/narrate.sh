#!/usr/bin/env bash
#
# The step narrator — two short spoken lines per step, while the turn runs: what the step is about
# to do, then how it went. `voice.autoplay.chattiness: max` only. Runs DETACHED, spawned by
# .claude/hooks/voice-narrate.sh on PreToolUse, PostToolUse and PostToolUseFailure.
#
# Usage:
#   narrate.sh [-v] --session ID --transcript PATH [--payload FILE] [--event NAME]
#
# ── WHAT IT SPEAKS ─────────────────────────────────────────────────────────────────
# `voice.autoplay.narrate_source: facts` (the default) — the tool call's own payload, turned into
# one line by scripts/voice/tool-fact.py. Both moments of a step, as a pair:
#
#     รัน cargo test    →  cargo test ผ่าน 42
#     อ่าน queue.sh     →  queue.sh อ่านแล้ว 260 บรรทัด
#
# Short (3–8 words), a subject and a figure, and NEW information every time. That form is what
# JARVIS actually does in the Iron Man films — "The armour is now at 92%", "18,000 feet. 10,000
# feet. 6,000 feet", "Thirteen, sir." The density that makes him feel present comes from FREQUENCY,
# not from length; the first `max` got that backwards and made the sentences longer.
#
# WHY THE INTENT HALF EXISTS, given that the film character speaks results and not intentions: a
# result-only narrator is silent for exactly as long as the work takes, and that silence is
# unreadable — a 90-second test run and a wedged command sound identical until one of them ends.
# `max` is the level asked for by someone who is NOT watching the screen, so the pair is the point:
# the intent line places the wait, the result line closes it. It has its own switch
# (voice.autoplay.narrate_intent) for anyone who wants the results alone.
#
# `narrate_source: prose` is the previous mechanism, kept: the assistant's own sentence from just
# before the tool call. Free and true, and the fallback whenever a step yields no speakable fact.
#
# Either way there is NO summarizer call on this path, so the whole channel costs zero tokens; the
# only spend is the TTS for a line that is deliberately tiny — and an intent line is short and
# repetitive enough that the audio cache answers most of them for nothing.
#
# ── THRESHOLDS (voice.autoplay.thresholds) ─────────────────────────────────────────
# JARVIS also speaks up unbidden when something crosses a line, and always names the consequence:
# "Sir, the suit has not even passed a basic wind-tunnel test", "may I remind you that you've been
# awake for nearly seventy-two hours". Three of those exist here:
#
#   red         a step FAILED (PostToolUseFailure, or a runner that printed failures). Skips the
#               rate floor and the per-turn cap — a failure is the one thing worth interrupting for.
#   again       the SAME step failed twice in a row. The second failure is the news.
#   long-turn   the turn has been running past voice.autoplay.long_turn_seconds. SINGLE-SHOT per
#               turn (and once more at 3×), and only on a step that actually ran — which is what
#               makes it a threshold and not the deleted heartbeat. A clock fires whether or not
#               anything happened; this cannot.
#
# ── WHY IT IS NOT A TIMER (the first `max` was, and it was wrong) ───────────────────
# A clock narrates a 3-second step never and a 90-second step twice, and can only name the tool it
# happens to catch. Steps are the unit `max` is about, so the hook fires on the step. That heartbeat
# is DELETED, not defaulted off.
#
# ── WHAT KEEPS IT FROM BECOMING NOISE ──────────────────────────────────────────────
#   dedupe   the same line is never spoken twice in a row (hash, per session). With `prose` this
#            matters most — one block introduces ~5 tool calls — but facts repeat too (three Reads
#            of the same file), and a repeated line is also a free CACHE hit when it is spoken.
#   stale    the queue drops a narration that waited too long, and drops the OLDEST first when a
#            session is already several deep. This is the load-shedding that matters, and it is on
#            the PLAYBACK side on purpose: it can see how far behind the voice actually is, which a
#            producer counting its own lines cannot.
#   rate     voice.autoplay.narrate_gap seconds between lines — 0, off, by default. A floor here
#            would eat one half of every pair, since the two halves arrive a second apart.
#   cap      voice.autoplay.narrate_max_per_turn lines per turn — 0, off, by default. Set a number
#            to bound a turn's TTS spend; when it bites it is LOGGED, never silent.
#
# It stays quiet once the turn has ENDED: the closing line owns the end of a turn.

set -euo pipefail
VOICE_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$VOICE_SELF_DIR/lib.sh"

MAX_CHARS=60       # ~4 s of Thai speech. A JARVIS line is 3-8 words; so is this one
MIN_CHARS=12       # below this there is no sentence, only a fragment
PROSE_CHARS=90     # the prose fallback is a written sentence, so it gets a little more room
INTENT_CHARS=34    # the intent half is half a result's length — a pair has to fit in one step

SESSION="" TRANSCRIPT="" PAYLOAD="" EVENT="PostToolUse"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) export VOICE_VERBOSE=1; shift ;;
    --session)    SESSION="${2:-}"; shift 2 ;;
    --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
    --payload)    PAYLOAD="${2:-}"; shift 2 ;;
    --event)      EVENT="${2:-PostToolUse}"; shift 2 ;;
    -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; exit 0 ;;
    *)            vdie "unknown option $1 (see -h)" ;;
  esac
done

# The payload is a temp file the hook owns; this process is the only reader, so it cleans up.
cleanup() { [[ -n "$PAYLOAD" && -f "$PAYLOAD" ]] && rm -f "$PAYLOAD"; return 0; }
trap cleanup EXIT

voice_gate_or_exit "narrate"
voice_cfg_bool voice.autoplay.enabled false || { vlog "narrate skipped: autoplay off"; exit 0; }
# Its own switch, so the running commentary can be turned off without leaving `max`: it is the
# loudest thing this feature does, and the ack/closing-line lengths are worth keeping on their own.
voice_cfg_bool voice.autoplay.narrate true || { vlog "narrate skipped: voice.autoplay.narrate is false"; exit 0; }
[[ "$(voice_chattiness)" == "max" ]] || { vlog "narrate skipped: chattiness is $(voice_chattiness), not max"; exit 0; }
# The BEFORE half of the pair, on its own switch: it doubles the number of spoken lines, so someone
# who wants the running commentary but not the intents can drop it without leaving `max`.
INTENT=0
if [[ "$EVENT" == "PreToolUse" ]]; then
  voice_cfg_bool voice.autoplay.narrate_intent true \
    || { vlog "narrate skipped: voice.autoplay.narrate_intent is false"; exit 0; }
  INTENT=1
fi
voice_is_muted && { vlog "narrate: muted — nothing synthesized"; exit 0; }
[[ -n "$SESSION" ]] || SESSION="$VOICE_ROOT"
voice_require jq

# ── the turn must still be open ───────────────────────────────────────────────────
TURN="$(voice_turn_get "$SESSION" turn)"
ENDED="$(voice_turn_get "$SESSION" ended)"
if [[ "$ENDED" -ge "$TURN" && "$TURN" -gt 0 ]]; then
  vlog "narrate: the turn already ended — the closing line owns this"
  exit 0
fi

SOURCE="$(voice_narrate_source)"
GAP="$(voice_narrate_gap)"
CAP="$(voice_narrate_cap)"
NOW="$(voice_now)"
LAST_TS="$(voice_narrate_get "$SESSION" ts)"
SPOKEN="$(voice_narrate_count "$SESSION" "$TURN")"

# ── the fact, from the step's own response ────────────────────────────────────────
# `<severity>\t<line>`, or nothing when the step carries no news (see tool-fact.py's SKIP_TOOLS).
SEV=info LINE="" SRC=""
_try_fact() {
  [[ -n "$PAYLOAD" && -f "$PAYLOAD" ]] || return 1
  local out
  out="$(python3 "$VOICE_SELF_DIR/tool-fact.py" --event "$EVENT" < "$PAYLOAD" 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  SEV="${out%%$'\t'*}"
  LINE="${out#*$'\t'}"
  SRC=fact
  return 0
}

# ── the prose fallback ────────────────────────────────────────────────────────────
# Written for the eye, spoken by an engine: fences, tables and list markers read as punctuation
# noise, and a heading is not a sentence. Backtick CONTENT survives — an identifier is usually the
# most informative word in the line. Only the first sentence, accumulated to at least ENOUGH
# characters, because an em dash is used mid-sentence constantly in this prose and a plain
# "first chunk" rule produced "both: 0" (7 characters) and one amputated line.
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

_last_prose() {
  jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text]
          | last // ""' "$TRANSCRIPT" 2>/dev/null || printf ''
}

_try_prose() {
  [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || return 1
  local out
  out="$(_speakable "$(_last_prose)")"
  [[ "$(printf '%s' "$out" | wc -m | tr -d ' ')" -ge "$MIN_CHARS" ]] || return 1
  # A `VOICE[...]` tag is the CLOSING line's mechanism — speaking it mid-turn would announce the
  # result before the work is done, twice.
  case "$out" in *VOICE\[*|*VOICE:*) return 1 ;; esac
  LINE="$out"
  SRC=prose
  return 0
}

# Each source is the other's fallback, which is why both survive: `facts` goes quiet on a step whose
# response carries no figure (see SKIP_TOOLS), and `prose` goes quiet on the four-in-five tool calls
# that have no sentence of their own in front of them.
if [[ "$SOURCE" == "facts" ]]; then
  _try_fact || _try_prose || true
else
  _try_prose || _try_fact || true
fi
[[ -n "$LINE" ]] || { vlog "narrate: nothing to say (no fact, no usable prose)"; exit 0; }
CHAR_CAP="$MAX_CHARS"
[[ "$SRC" == "prose" ]] && CHAR_CAP="$PROSE_CHARS"
[[ "$INTENT" -eq 1 && "$SRC" == "fact" ]] && CHAR_CAP="$INTENT_CHARS"
URGENT_CHARS=110   # a threshold line prefixes the fact ("ผ่านมา 11 นาที… ล่าสุด <fact>"), and the
                   # tail is the informative half — the step cap would cut exactly that off

# ── thresholds: what speaks even when the floor says no ────────────────────────────
# URGENT skips the rate floor AND the per-turn cap. Only a failure and the long-turn crossing get
# it, both of which are things the user would rather hear late than not at all.
# Never on the intent half: a threshold is a statement about what HAS happened. "ผ่านมา 11 นาทีแล้ว
# … ล่าสุด รัน cargo test" would name as the latest news a step that has not run yet, and a call
# that has not run cannot have failed. The result half of the same step carries both.
URGENT=0 CUE=""
if [[ "$INTENT" -eq 0 ]] && voice_cfg_bool voice.autoplay.thresholds true; then
  if [[ "$SEV" == "bad" ]]; then
    URGENT=1 CUE=red
    # The SAME step failing twice is a different event from two steps failing once: say so, because
    # "still red" is the fact that changes a person's next move. Counted rather than flagged — the
    # third attempt is more news than the second, and a fixed "ซ้ำรอบสอง" would call it the second
    # forever (and be swallowed by the dedupe hash for saying the identical thing).
    FAILHASH="$(voice_sha "$(voice_normalize_text "$LINE")")"
    FAILN=1
    if [[ "$FAILHASH" == "$(voice_narrate_get "$SESSION" fail)" ]]; then
      FAILN=$(( $(voice_narrate_get "$SESSION" failn) + 1 ))
      LINE="$LINE ซ้ำรอบ $FAILN"
    fi
    voice_narrate_put "$SESSION" fail "$FAILHASH"
    voice_narrate_put "$SESSION" failn "$FAILN"
  elif [[ "$TURN" -gt 0 ]]; then
    LONG="$(voice_long_turn_seconds)"
    ELAPSED=$(( NOW - TURN ))
    for mult in 3 1; do
      (( ELAPSED >= LONG * mult )) || continue
      if voice_threshold_fire "$SESSION" "$TURN" "long$mult"; then
        LINE="ผ่านมา $(( ELAPSED / 60 )) นาทีแล้ว ยังทำอยู่ ล่าสุด $LINE"
        URGENT=1 CUE=attention
      fi
      break
    done
  fi
fi

# ── the floors, checked after the line exists so a red can bypass them ─────────────
# Both are OFF by default at `max` (0 = no floor, 0 = no ceiling) — the level's whole promise is
# that every action is spoken, and a floor drops half of every pair. They stay implemented because
# a number in the config is the way to buy quiet or bound TTS spend without leaving `max`.
if [[ "$URGENT" -eq 0 ]]; then
  if (( GAP > 0 )) && [[ "$LAST_TS" -gt 0 ]] && (( NOW - LAST_TS < GAP )); then
    vlog "narrate: $((NOW - LAST_TS))s since the last line, floor is ${GAP}s — skipping"
    exit 0
  fi
  if (( CAP > 0 && SPOKEN >= CAP )); then
    # Said out loud in the log, not swallowed: a cap that hides itself looks like a dead feature.
    vlog "narrate: per-turn cap reached ($SPOKEN/$CAP lines) — staying quiet for the rest of this turn"
    exit 0
  fi
fi

[[ "$URGENT" -eq 1 ]] && CHAR_CAP="$URGENT_CHARS"

# Cap by CHARACTERS, not bytes: Thai is multibyte and ${#} would cut a 40-character line at 60
# bytes, mid-syllable. Cut at a word boundary when there is one nearby.
if [[ "$(printf '%s' "$LINE" | wc -m | tr -d ' ')" -gt "$CHAR_CAP" ]]; then
  LINE="$(printf '%s' "$LINE" | python3 -c '
import sys
s = sys.stdin.read()
n = int(sys.argv[1])
cut = s[:n]
sp = cut.rfind(" ")
sys.stdout.write(cut if sp < n * 0.6 else cut[:sp])
' "$CHAR_CAP" 2>/dev/null || printf '%s' "$LINE")"
fi

# ── dedupe: has this exact line already been spoken? ───────────────────────────────
HASH="$(voice_sha "$(voice_normalize_text "$LINE")")"
if [[ "$HASH" == "$(voice_narrate_get "$SESSION" hash)" ]]; then
  vlog "narrate: same line as last time ($SRC) — skipping"
  exit 0
fi

# Recorded BEFORE speaking, not after: two PostToolUse hooks can land in the same second, and the
# loser of that race must see the winner's hash rather than both queuing the same sentence.
voice_narrate_set "$SESSION" "$HASH" "$TURN"
CAPTXT="$CAP"; (( CAP > 0 )) || CAPTXT="no cap"
HALF=after; [[ "$INTENT" -eq 1 ]] && HALF=before
vlog "narrate[$SRC/$HALF${CUE:+/$CUE}] $((SPOKEN + 1))/$CAPTXT: $LINE"

# A normal step is --kind narration: its own queue class, dropped harder than an ack, and no cue —
# a sound before every step would be a metronome. A threshold is a MILESTONE: never dropped, and it
# carries the cue that says which kind of news it is.
# The payload is deleted HERE rather than left to the EXIT trap: `exec` replaces this process, so
# the trap never runs on the one path that always reaches the end. (Measured — every narrated step
# leaked one temp file until the suite started asserting on it.)
cleanup
if [[ "$URGENT" -eq 1 ]]; then
  exec "$VOICE_SELF_DIR/speak.sh" --kind milestone ${CUE:+--cue "$CUE"} "$LINE"
fi
exec "$VOICE_SELF_DIR/speak.sh" --kind narration "$LINE"
