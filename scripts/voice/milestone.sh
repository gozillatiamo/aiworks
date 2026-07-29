#!/usr/bin/env bash
#
# Milestones — the line spoken when something actually HAPPENED, as opposed to the ack that
# fires when you ask for something. Runs detached, spawned by .claude/hooks/voice-milestone.sh
# on `Stop`.
#
# Usage:
#   milestone.sh [-v] --session ID --transcript PATH
#   milestone.sh [-v] [--session ID] --text "the reply text"
#   milestone.sh [-v] --say '[ship] APP-1952 merged เข้า develop แล้วครับ'   # bypass detection
#
# ── A FINISHED TURN ALWAYS SPEAKS ──────────────────────────────────────────────────
# The result is the thing worth hearing. You asked for something, you looked away, and the one
# sentence you actually need is "here is what came out of it" — so every turn that ends with a
# reply gets a closing line, not only the ones that happened to declare an event.
#
# This is the REVERSE of how it shipped (silence unless a tag or a narrow keyword match), changed
# after use: staying quiet on most turns meant the feature spoke at the START of the work and then
# never told you it was done, which is the half you cannot get from glancing at the screen.
#
# WHAT IT COSTS: one summarizer call plus one TTS call per turn, and a finish summary is unique
# text every time so it never hits the audio cache — about $0.01 a turn. Turn it back down with
# `voice.autoplay.milestone_every_turn: false` (then only a tagged turn speaks) or
# `voice.autoplay.milestones: false` (then none do).
#
# THE LINE MUST CARRY THE RESULT, not the fact of finishing. "อธิบายให้ฟังแล้วครับ" is noise —
# the summarizer is told to state the outcome, the number, the name, the verdict.
#
# ── HOW AN EVENT IS DECLARED (two mechanisms, in this order) ───────────────────────
#
# 1. AN EXPLICIT TAG in the reply — the primary mechanism, and the one to reach for:
#
#        VOICE[ship]: APP-1952 merged เข้า develop แล้วครับ MR !12 ปิดแล้ว
#
#    Costs nothing (no summarizer call), says exactly what you meant, and picks the cue. The
#    group in brackets is optional; bare `VOICE:` speaks plainly with no cue.
#
#      [green]     a good outcome — tests pass, review approved, QA verdict good
#      [red]       a bad one — must-fixes, failures. The cue sits UNDER the words, quietly
#      [ship]      delivery — MR/PR opened, merged, ticket Done. Cue first, then talk
#      [needs-you] a plan waiting for approval, a question, a blocked gate
#      [incident]  production is unhappy. Urgent register, cue under the words
#
#    Only the FIRST tag in a reply is used: a reply with several is one turn with one outcome,
#    and the first is where a writer states it.
#
# 2. THE SUMMARIZED CLOSING LINE, for every turn that ends without one — the reply's own last
#    text block, rewritten by the summarizer into one past-tense sentence. Grounded in the
#    reply's words and forbidden from inventing anything.
#
#    A narrow keyword match still runs, but it no longer decides WHETHER to speak — only which
#    CUE to play, and it stays narrow for the same reason as before: attaching a fanfare to a
#    merge that did not happen is worse than attaching no cue at all. No match ⇒ words only.
#
# Slack is NOT this script's job. The workflow already posts the review-request/ship message,
# and posting from here as well would double-post; the voice note is attached by whoever sends
# that message (scripts/voice/notify-voice.sh).

set -euo pipefail
VOICE_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$VOICE_SELF_DIR/lib.sh"
# shellcheck source=./variety.sh
. "$VOICE_SELF_DIR/variety.sh"

SESSION="" TRANSCRIPT="" TEXT="" SAY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) export VOICE_VERBOSE=1; shift ;;
    --session)    SESSION="${2:-}"; shift 2 ;;
    --transcript) TRANSCRIPT="${2:?}"; shift 2 ;;
    --text)       TEXT="${2:-}"; shift 2 ;;
    --say)        SAY="${2:?}"; shift 2 ;;
    -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; exit 0 ;;
    -*)           vdie "unknown option $1 (see -h)" ;;
    *)            TEXT="${TEXT:+$TEXT }$1"; shift ;;
  esac
done

voice_gate_or_exit "milestone"
if ! voice_cfg_bool voice.autoplay.enabled false; then
  vlog "milestone skipped: voice.autoplay.enabled is false"
  exit 0
fi
if ! voice_cfg_bool voice.autoplay.milestones true; then
  vlog "milestone skipped: voice.autoplay.milestones is false"
  exit 0
fi
if voice_is_muted; then
  vlog "milestone: muted — nothing synthesized"
  exit 0
fi
[[ -n "$SESSION" ]] || SESSION="$VOICE_ROOT"

# ── group → cue, mix, mood, voice ──────────────────────────────────────────────────
# Echoes "<cue>|<mix>|<volume>". PIPE-separated, not space: the no-cue case has an EMPTY first
# field, and a space-split `read` collapses it — which silently shifted `mix` into `cue` and
# fed speak.sh `--mix 0.22`, killing the plain path. A non-whitespace IFS keeps empties.
#
# Bad news gets the cue UNDER the words at low volume so the words stay the loudest thing;
# delivery gets the cue FIRST because a fanfare beneath a sentence is just noise; a good
# outcome gets it at the tail, landing as the sentence does.
_cue_for() {
  case "$1" in
    green)     printf '%s|%s|%s' green tail 0.40 ;;
    red)       printf '%s|%s|%s' red under 0.15 ;;
    ship)      printf '%s|%s|%s' ship sting 0.50 ;;
    needs-you) printf '%s|%s|%s' attention tail 0.40 ;;
    incident)  printf '%s|%s|%s' incident under 0.15 ;;
    *)         printf '%s|%s|%s' '' under 0.22 ;;   # bare VOICE: — words only, no cue
  esac
}

_mood_for() {
  case "$1" in
    green)     printf 'cheerfully, like good news to the team' ;;
    red)       printf 'calmly and matter-of-factly, not alarmed' ;;
    ship)      printf 'cheerfully and a little pleased' ;;
    needs-you) printf 'politely, asking for attention' ;;
    incident)  printf 'urgently and seriously, like an on-call alert' ;;
    *)         printf '' ;;
  esac
}

# ── where the text comes from ──────────────────────────────────────────────────────
if [[ -z "$TEXT" && -z "$SAY" ]]; then
  [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || { vlog "milestone: no --text and no readable transcript"; exit 0; }
  voice_require jq
  # The last assistant TEXT block of the turn. Tool calls and thinking are not what was said.
  TEXT="$(jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // ""' \
          "$TRANSCRIPT" 2>/dev/null || printf '')"
  [[ -n "$TEXT" ]] || { vlog "milestone: the turn ended with no assistant text"; exit 0; }
fi

# ── 1. the explicit tag ────────────────────────────────────────────────────────────
GROUP="" SPOKEN=""
if [[ -n "$SAY" ]]; then
  # --say takes the same shape as the tag body, so a caller and a reply say it the same way.
  if [[ "$SAY" =~ ^\[([a-z-]+)\][[:space:]]*(.*)$ ]]; then
    GROUP="${BASH_REMATCH[1]}"; SPOKEN="${BASH_REMATCH[2]}"
  else
    SPOKEN="$SAY"
  fi
else
  # `VOICE[group]: text` or `VOICE: text`, first occurrence, anywhere in the reply.
  TAG_LINE="$(printf '%s\n' "$TEXT" | grep -m1 -E '(^|[[:space:]>*_`-])VOICE(\[[a-z-]+\])?:[[:space:]]*.' || true)"
  if [[ -n "$TAG_LINE" ]]; then
    GROUP="$(printf '%s' "$TAG_LINE" | sed -nE 's/.*VOICE\[([a-z-]+)\]:.*/\1/p')"
    SPOKEN="$(printf '%s' "$TAG_LINE" | sed -E 's/^.*VOICE(\[[a-z-]+\])?:[[:space:]]*//')"
    vlog "milestone: explicit tag${GROUP:+ [$GROUP]} — no summarizer call"
  fi
fi

# ── 2. the summarized closing line ─────────────────────────────────────────────────
# Which CUE, if any. This used to decide whether to speak at all; now it only decorates, so a
# no-match is a plain sentence rather than silence.
#
# STILL DELIBERATELY HARD TO TRIGGER. An earlier version matched bare words (`merged`, `must-fix`,
# `blocked`) and fired on any reply that merely DISCUSSED those things — including a status summary
# about this very feature. Each pattern needs corroborating structure: an actual MR/PR URL beside a
# merge word, a COUNT beside must-fix, a verdict beside a test word. A false cue announces something
# that did not happen.
_group_from_keywords() {
  local low; low="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  m() { printf '%s' "$low" | grep -qE "$1"; }
  if   m '(merge_requests|/pull/)/[0-9]+' && m '(merged|merge เข้า|ship แล้ว|deploy แล้ว)'; then printf ship
  elif m '[0-9]+ *must-fix|must-fix *[0-9]+'                                            ; then printf red
  elif m '(test|tests|suite|pipeline)[^.]{0,40}(ไม่ผ่าน|failed|แดง)'                       ; then printf red
  elif m '(test|tests|suite|pipeline)[^.]{0,40}(ผ่านหมด|ผ่านทั้งหมด|green|เขียวหมด)'         ; then printf green
  elif m '(review|mr|pr)[^.]{0,30}(approved|อนุมัติแล้ว)'                                  ; then printf green
  elif m '(รออนุมัติ|รอ approve|awaiting approval|รอคุณ approve|รอคุณอนุมัติ)'                ; then printf needs-you
  # An incident needs a FIGURE or a spike word as well as the words: "อธิบายเรื่อง production
  # error rate ให้ฟัง" is a conversation about monitoring, and it tripped the pattern without this.
  elif m '(production|prod)[^.]{0,40}(error rate|พัง|ล่ม|down)' \
    && m '([0-9]+ *(%|เปอร์เซ็นต์)|พุ่ง|spike|สูงขึ้น)'                                        ; then printf incident
  fi
}

# Does an untagged turn speak? Default YES — the result is the point. `false` returns the old
# conservative mode: only a turn that declares a `VOICE:` tag says anything.
#
# The pre-rename key `milestone_backstop` is honoured as a fallback because it meant exactly this
# in its `false` position ("no tag ⇒ nothing"), so a config that already set it keeps working.
_speaks_untagged() {
  local v
  v="$(voice_cfg voice.autoplay.milestone_every_turn "")"
  [[ -n "$v" ]] || v="$(voice_cfg voice.autoplay.milestone_backstop "")"
  [[ -n "$v" ]] || v=true
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in true|yes|1|on) return 0 ;; *) return 1 ;; esac
}

if [[ -z "$SPOKEN" ]]; then
  if ! _speaks_untagged; then
    vlog "milestone: no tag and milestone_every_turn is false — staying quiet"
    exit 0
  fi
  GROUP="$(_group_from_keywords "$TEXT")"
  vlog "milestone: summarizing the finished turn${GROUP:+ (cue: $GROUP)}"

  voice_load_credentials
  voice_load_tts_provider
  ALT="$(variety_alt_voice_for "$GROUP")"
  [[ -n "$ALT" ]] && export VOICE_TTS_VOICE_FORCE="$ALT"
  PARTICLE="$(variety_particle "$(voice_tts_gender)")"
  # Bad news keeps the plain register at every level: a softener under "must-fix 3 อัน" or a
  # cheerful reaction over an incident is the wrong voice for the news, and chattiness is a
  # set-once preference nobody turns down before prod breaks.
  PLAIN=""
  case "$GROUP" in red|incident) PLAIN=--plain ;; esac
  CHAT="$(voice_chattiness)"
  vlog "milestone: chattiness=$CHAT${PLAIN:+ (plain register — group $GROUP)}"
  # No --max-chars: the level owns the budget, in one table in summarize.sh.
  SPOKEN="$("$VOICE_SELF_DIR/summarize.sh" --kind report --particle "$PARTICLE" \
              --chattiness "$CHAT" ${PLAIN:+$PLAIN} "$TEXT" 2>/dev/null || true)"
  if [[ -z "$SPOKEN" ]]; then
    vlog "milestone: summarizer produced nothing — staying quiet"
    exit 0
  fi
  # ── the degenerate line ──────────────────────────────────────────────────────────
  # A turn with no reportable outcome ("แค่คุยเล่น") makes the model return the particle and
  # nothing else — measured: SPOKEN came back as the single word "ค่ะ", which was then queued and
  # spoken. That is a syllable of politeness announced as a result, and it is exactly the filler
  # this feature is not allowed to become.
  #
  # Checked on the OUTPUT rather than by refusing to summarize a short reply: "merged แล้วครับ" is
  # fifteen characters and a real result, so length on the way in proves nothing. wc -m, not ${#},
  # because Thai is multibyte.
  BODY="$(printf '%s' "$SPOKEN" | sed -E 's/(นะ)?(ครับ|ค่ะ|คะ|จ้า|ค่ะๆ)[[:space:]]*$//; s/[[:space:]]+$//')"
  if [[ "$(printf '%s' "$BODY" | wc -m | tr -d ' ')" -lt 10 ]]; then
    vlog "milestone: the summary is only a particle ('$SPOKEN') — nothing to report, staying quiet"
    exit 0
  fi
fi

IFS='|' read -r CUE MIX VOL <<< "$(_cue_for "${GROUP:-}")"
MOOD="$(_mood_for "${GROUP:-}")"
vlog "milestone[${GROUP:-plain}]: cue=${CUE:-none} mix=$MIX vol=$VOL — $SPOKEN"

exec "$VOICE_SELF_DIR/speak.sh" --kind milestone \
  ${CUE:+--cue "$CUE" --mix "$MIX" --cue-volume "$VOL"} \
  ${MOOD:+--mood "$MOOD"} "$SPOKEN"
