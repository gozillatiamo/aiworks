#!/usr/bin/env bash
#
# The acknowledgement: "I heard you, and here is the concrete thing I am about to do."
# Runs DETACHED, spawned by .claude/hooks/voice-ack.sh — never on the turn's critical path.
#
# Usage:
#   ack.sh [-v] --file PROMPT_FILE [--session ID]
#   ack.sh [-v] [--session ID] "the prompt text"
#
# THE FIXED PATTERN (decision #18 — no config, on purpose)
#   t=0 ms     the `ack` cue, straight from cache. The hook plays this, not us: it must land
#              before anything can go wrong, and it is the only part that must be instant.
#   t≈1.3 s    the summarizer turns the prompt into one Thai sentence (measured, openai)
#   t≈4.5 s    that sentence is spoken (measured end to end)
#
# WHEN IT STAYS QUIET, and why each rule exists
#   prompt under 12 characters   "go", "ต่อ", "yes" — the cue already said everything
#   a session-management command /clear, /compact, /model … — not work, just housekeeping
#   the turn already ended       the answer has landed; "กำลังไปดู X" after it is worse
#                                than silence
#   a newer prompt arrived       this ack would describe the previous request
#   the machine is muted         `aiworks voice mute on` — checked before spending anything
#   the summarizer returned      speak nothing rather than a canned "รับทราบครับ" — filler
#   nothing                      on every failure is exactly what this feature must not be

set -euo pipefail
VOICE_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$VOICE_SELF_DIR/lib.sh"
# shellcheck source=./variety.sh
. "$VOICE_SELF_DIR/variety.sh"

MIN_CHARS=12
# Commands that manage the session rather than ask for work. An explicit list, not a heuristic:
# `/dev-cycle APP-1952` deserves an ack, `/compact` does not, and guessing from length would
# get both wrong.
HOUSEKEEPING='clear compact caveman help cost model status resume exit config fast loop mcp memory hooks vim terminal-setup doctor login logout upgrade release-notes bug ide install-github-app privacy-settings todos output-style agents rewind context usage sandbox'

SESSION="" FILE="" TEXT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) export VOICE_VERBOSE=1; shift ;;
    --session)    SESSION="${2:-}"; shift 2 ;;
    --file)       FILE="${2:?}"; shift 2 ;;
    -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; exit 0 ;;
    -*)           vdie "unknown option $1 (see -h)" ;;
    *)            TEXT="${TEXT:+$TEXT }$1"; shift ;;
  esac
done

voice_gate_or_exit "ack"
if ! voice_cfg_bool voice.autoplay.enabled false; then
  vlog "ack skipped: voice.autoplay.enabled is false"
  exit 0
fi
if ! voice_cfg_bool voice.autoplay.ack true; then
  vlog "ack skipped: voice.autoplay.ack is false (milestones may still speak)"
  exit 0
fi

if [[ -n "$FILE" ]]; then
  [[ -f "$FILE" ]] || { vlog "ack: no prompt file at $FILE"; exit 0; }
  TEXT="$(cat "$FILE")"
fi
[[ -n "$TEXT" ]] || { vlog "ack: empty prompt"; exit 0; }
[[ -n "$SESSION" ]] || SESSION="$VOICE_ROOT"

# The turn we are acking. Captured NOW so a prompt that arrives while the summarizer is
# thinking can be detected below.
MY_TURN="$(voice_turn_get "$SESSION" turn)"

# ── the quiet rules ───────────────────────────────────────────────────────────────
# wc -m, not ${#TEXT}: Thai is multibyte and ${#} counts bytes in a non-UTF-8 locale, which
# would make every Thai prompt look three times longer than it is.
CHARS="$(printf '%s' "$TEXT" | wc -m | tr -d ' ')"
if [[ "$CHARS" -lt "$MIN_CHARS" ]]; then
  vlog "ack: $CHARS chars — cue only"
  exit 0
fi

case "$TEXT" in
  /*)
    cmd="${TEXT#/}"; cmd="${cmd%% *}"; cmd="${cmd%%:*}"
    case " $HOUSEKEEPING " in
      *" $cmd "*) vlog "ack: /$cmd is session housekeeping — cue only"; exit 0 ;;
    esac
    ;;
esac

# Checked HERE as well as at drain time, so a muted machine spends nothing: everything below
# this line costs a summarizer call and a TTS call.
if voice_is_muted; then
  vlog "ack: muted — nothing synthesized"
  exit 0
fi

# ── variety: pick the register before spending anything ───────────────────────────
voice_load_credentials
voice_load_tts_provider

INTENT="$(variety_intent "$TEXT")"
MOOD="$(variety_mood "$INTENT")"
SEED="$(variety_seed)"
TOD="$(variety_timeofday)"

# An incident or a verdict in the alternate voice, when one is configured. Set BEFORE reading
# the gender, or the particle would be pinned to the voice we are not going to use.
ALT="$(variety_alt_voice_for "$INTENT")"
[[ -n "$ALT" ]] && { export VOICE_TTS_VOICE_FORCE="$ALT"; vlog "ack: alt voice for $INTENT"; }
PARTICLE="$(variety_particle "$(voice_tts_gender)")"

# Bad news gets no warm register, at any chattiness level — the same ruling that keeps quips out
# (a warm turn of phrase lands the third time and grates on the fiftieth, and it will eventually
# fire mid-incident). The level is a set-once preference; nobody turns it down before prod breaks.
PLAIN=""
case "$INTENT" in prod|error) PLAIN=--plain ;; esac

CHAT="$(voice_chattiness)"
vlog "ack: intent=$INTENT chattiness=$CHAT particle=$PARTICLE seed='$SEED'${TOD:+ tod='$TOD'}${PLAIN:+ (plain register)}"

# No --max-chars: the budget belongs to the level, and it lives in ONE table in summarize.sh.
# This file used to hard-code 90 while milestone.sh hard-coded 120, with nothing tying them.
LINE="$("$VOICE_SELF_DIR/summarize.sh" --particle "$PARTICLE" --seed "$SEED" \
          ${TOD:+--extra "$TOD"} --chattiness "$CHAT" ${PLAIN:+$PLAIN} "$TEXT" 2>/dev/null || true)"
if [[ -z "$LINE" ]]; then
  vlog "ack: summarizer produced nothing — staying quiet"
  exit 0
fi

# ── is this ack still wanted? (re-checked AFTER the summarizer, not before) ────────
NOW_TURN="$(voice_turn_get "$SESSION" turn)"
ENDED="$(voice_turn_get "$SESSION" ended)"
if [[ "$NOW_TURN" != "$MY_TURN" ]]; then
  vlog "ack: a newer prompt arrived (turn $MY_TURN → $NOW_TURN) — dropping"
  exit 0
fi
if [[ "$ENDED" -ge "$MY_TURN" && "$MY_TURN" -gt 0 ]]; then
  vlog "ack: the turn already ended — dropping (the answer beat us to it)"
  exit 0
fi

# No cue here: the hook already played it at t=0, and a second one under the sentence would
# make one prompt sound like two events.
# --mood is omitted rather than passed empty when the intent carries no mood: an empty flag
# value is a shape every caller has to special-case, and not passing it says the same thing.
exec "$VOICE_SELF_DIR/speak.sh" --kind ack ${MOOD:+--mood "$MOOD"} "$LINE"
