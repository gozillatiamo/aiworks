#!/usr/bin/env bash
#
# The mid-turn narrator — the CONCLUSION of each piece of work, spoken while the turn runs.
# `voice.autoplay.chattiness: max` only. Runs DETACHED, spawned by
# .claude/hooks/voice-narrate.sh on PreToolUse, PostToolUse and PostToolUseFailure.
#
# Usage:
#   narrate.sh [-v] --session ID --transcript PATH [--payload FILE] [--event NAME]
#
# ── WHAT IT SPEAKS ─────────────────────────────────────────────────────────────────
# `voice.autoplay.narrate_source: insight` (the default) — one line per thing WORKED OUT, from the
# assistant's own reasoning block, via the summarizer's `insight` kind:
#
#     "root cause คือ submodule pointer ค้างที่ APP-631 เพราะ teardown.sql พัง
#      จะ bump แล้วรัน scoped test ใหม่ค่ะ"
#
# THE UNIT IS A CONCLUSION, NOT A TOOL CALL, and that correction is the whole history of this file.
# The previous version narrated every step in both directions — "รัน cd", "อ่าน queue.sh",
# "cargo test ผ่าน 42" — mechanically true, and dismissed on first contact with the person it was
# built for: nobody listening wants to be told which command is running, they want to be told what
# it MEANT. A step is a unit of machinery; a finding, its cause and the next move are what a
# colleague would say out loud.
#
# Most blocks are NOT a conclusion (they announce a step), so this source is mostly silent by
# design — see _try_insight for the two gates, and note that it never falls back to the step
# sources: falling back would put "รัน cd" back in the channel one silence at a time.
#
# `narrate_source: facts` is the previous mechanism, kept whole and now opt-in: two lines per step
# from tool-fact.py, the JARVIS-metronome register ("The armour is now at 92%"), with the before-half
# on its own switch (voice.autoplay.narrate_intent). It costs no tokens at all, which is why it
# survives — but it is the register that was too much.
#
# `narrate_source: prose` is the cheapest of the three: the assistant's own sentence from just before
# the tool call, verbatim and truncated. No summarizer call, and no judgement about whether the
# sentence was worth saying.
#
# COST: `insight` is the only source that spends tokens, and less than the step pair it replaced —
# one cheap-model call per substantive block (~1 block per 5 tool calls, and most are refused)
# against two TTS lines per step.
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
# shellcheck source=./variety.sh
. "$VOICE_SELF_DIR/variety.sh"   # variety_particle — the insight source speaks a full sentence

MAX_CHARS=60       # ~4 s of Thai speech. A JARVIS line is 3-8 words; so is this one
MIN_CHARS=12       # below this there is no sentence, only a fragment
PROSE_CHARS=90     # the prose fallback is a written sentence, so it gets a little more room
INTENT_CHARS=34    # the intent half is half a result's length — a pair has to fit in one step
INSIGHT_CHARS=170  # a conclusion needs room for a because-clause and the next move. The summarizer
                   # is already capped at 160, so this only stops a runaway from being cut mid-word

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
SOURCE="$(voice_narrate_source)"
# The BEFORE half of a STEP pair — `narrate_source: facts` only, since that is the only source with
# steps in it. Under `insight` the PreToolUse event is not an intent line at all: it is the earliest
# moment the assistant's newest reasoning block can be seen, so a conclusion is spoken as the work
# starts instead of after the first step of it finishes.
INTENT=0
if [[ "$EVENT" == "PreToolUse" ]]; then
  if [[ "$SOURCE" == "facts" ]]; then
    voice_cfg_bool voice.autoplay.narrate_intent true \
      || { vlog "narrate skipped: voice.autoplay.narrate_intent is false"; exit 0; }
    INTENT=1
  fi
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

# ── the insight source: a CONCLUSION per reasoning block, not a line per tool call ──
# THE UNIT IS THE THING THAT WAS WORKED OUT. `facts` narrates every step — "รัน cd",
# "queue.sh อ่านแล้ว 260 บรรทัด" — which is mechanically true and worth nothing to listen to: the
# person is not asking which command is running, they are asking what it MEANT. A conclusion is
# what they would want said out loud ("root cause คือ submodule pointer ค้างที่ APP-631 เพราะ
# teardown.sql พัง จะ bump แล้วรัน scoped test ใหม่"), and conclusions are written into the
# assistant's own prose, roughly one block per five tool calls (measured: 314 blocks / 1 523 calls).
#
# So the block is the unit, and the summarizer's job is mostly to REFUSE — most blocks announce a
# step. Two gates, cheap one first:
#   1. length. A block under MIN_BLOCK characters is a preamble ("อ่าน queue.sh ก่อน"), never a
#      finding. Free, and it rejects the majority.
#   2. the model, which answers NONE when there is no conclusion in the text. Not "answer with an
#      empty string": measured on this codebase's other summarizer prompts, an instruction to say
#      nothing produces a plausible invented sentence instead, while a token to emit does not.
# Deduped on the BLOCK's hash rather than the spoken line, because the same block is seen again by
# every tool call that follows it and the summarizer would paraphrase it differently each time.
MIN_BLOCK=100
_try_insight() {
  [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || return 1
  local block clean hash out
  block="$(_last_prose)"
  [[ -n "$block" ]] || return 1
  # A `VOICE[...]` tag marks the CLOSING line's own text — speaking it mid-turn would announce the
  # result before the work is done, and then again at the end.
  case "$block" in *VOICE\[*|*VOICE:*) return 1 ;; esac
  clean="$(_speakable "$block")"
  [[ -n "$clean" ]] || return 1
  if [[ "$(printf '%s' "$clean" | wc -m | tr -d ' ')" -lt "$MIN_BLOCK" ]]; then
    vlog "insight: the block is $(printf '%s' "$clean" | wc -m | tr -d ' ') chars — a step, not a conclusion"
    return 1
  fi
  hash="$(voice_sha "$(voice_normalize_text "$clean")")"
  if [[ "$hash" == "$(voice_narrate_get "$SESSION" iblk)" ]]; then
    vlog "insight: this block already spoke"
    return 1
  fi
  # Recorded BEFORE the call, not after: several tool calls follow one block and each spawns its own
  # narrate.sh, so the losers of that race must see the winner's mark rather than all paying for the
  # same summary. This is the one place where a duplicate costs money and not just noise.
  voice_narrate_put "$SESSION" iblk "$hash"
  # The particle is pinned to the VOICE's gender (a male voice saying ค่ะ is a real bug), and
  # `voice_tts_gender` is defined by the PROVIDER file, not by lib.sh — so it has to be loaded
  # first. Without this the call resolves to nothing, `variety_particle` takes its default, and
  # every line ends in ค่ะ no matter whose voice is configured. Loaded here rather than at the top
  # of the script because only this source needs it: the step sources speak no particle at all.
  command -v voice_tts_gender >/dev/null 2>&1 || voice_load_tts_provider
  out="$("$VOICE_SELF_DIR/summarize.sh" --kind insight \
           --particle "$(variety_particle "$(voice_tts_gender)")" "$clean" 2>/dev/null || true)"
  out="$(printf '%s' "$out" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$out" in
    ""|NONE|NONE.|none|"NONE "*) vlog "insight: no conclusion in the block (${out:-empty})"; return 1 ;;
  esac
  LINE="$out"
  SRC=insight
  return 0
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

# `insight` (the default) has NO fallback to the step sources, and that is the point rather than an
# omission: falling back to `facts` when a block carries no conclusion would put "รัน cd" back in the
# channel one silence at a time, which is exactly what this source replaced. Nothing to conclude ⇒
# nothing said. The other two keep each other company as before: `facts` goes quiet on a step whose
# response carries no figure (SKIP_TOOLS), `prose` on the four-in-five calls with no sentence of
# their own in front of them.
case "$SOURCE" in
  insight) _try_insight || true ;;
  facts)   _try_fact || _try_prose || true ;;
  *)       _try_prose || _try_fact || true ;;
esac
[[ -n "$LINE" ]] || { vlog "narrate: nothing to say (no fact, no usable prose)"; exit 0; }
CHAR_CAP="$MAX_CHARS"
[[ "$SRC" == "prose" ]] && CHAR_CAP="$PROSE_CHARS"
[[ "$SRC" == "insight" ]] && CHAR_CAP="$INSIGHT_CHARS"
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
