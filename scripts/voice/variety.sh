#!/usr/bin/env bash
# Variety — the rules that keep spoken output from turning into a jingle.
# Sourced by ack.sh and (Phase 3) the milestone hook. Nothing here is configurable: these are
# taste decisions, and a config knob per knob would mean nobody ever tunes any of them.
#
# WHAT VARIES, AND WHY THAT LIST AND NOT A RANDOM QUIP GENERATOR
#   A joke lands the third time and grates on the fiftieth, and it will eventually fire in the
#   middle of an incident. So nothing here invents content. What rotates is PHRASING (six
#   shapes), and what tracks reality is MOOD, VOICE, CUE and TIME OF DAY — each derived from
#   the request itself. The sentence always names concrete facts (ticket, repo, count) because
#   the summarizer is told to; a line that could have been said about any request is filler
#   whichever wording it wears.
#
#   The one hard rule: the Thai sentence-final particle is pinned to the VOICE's gender.
#   A male voice saying "ได้เลยค่ะ" was a real bug in the demo round, and it is instantly
#   wrong to any Thai listener.

# ── intent, from the request itself ────────────────────────────────────────────────
# Deliberately keyword-based rather than a second LLM call: this runs before the summarizer,
# on the latency budget the user actually feels, and a wrong guess costs a mood, not meaning.
variety_intent() {   # TEXT → prod|error|ship|review|test|plan|question|generic
  local t; t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    *prod*|*production*|*incident*|*โปรดักชัน*|*พัง*|*ล่ม*|*ด่วน*|*urgent*) printf 'prod'; return ;;
  esac
  case "$t" in
    *error*|*fail*|*bug*|*crash*|*panic*|*ผิด*|*บั๊ก*|*error*) printf 'error'; return ;;
  esac
  case "$t" in
    *ship*|*deploy*|*merge*|*release*|*ปล่อย*|*ขึ้น*) printf 'ship'; return ;;
  esac
  case "$t" in
    *review*|*มร*|*" mr "*|*" pr "*|*รีวิว*) printf 'review'; return ;;
  esac
  case "$t" in
    *test*|*qa*|*cypress*|*เทส*|*ทดสอบ*) printf 'test'; return ;;
  esac
  case "$t" in
    *plan*|*วางแผน*|*ออกแบบ*|*design*|*architect*) printf 'plan'; return ;;
  esac
  case "$t" in
    *ทำไม*|*why*|*how*|*อย่างไร*|*ยังไง*|*"?"*) printf 'question'; return ;;
  esac
  printf 'generic'
}

# ── mood: a style hint the provider actually honours ───────────────────────────────
# ElevenLabs takes it as an audio tag (lands maybe half the time), OpenAI as free-text
# instructions (reliable), Gemini as prose in the prompt. So it is phrased as plain English
# that reads correctly in all three.
variety_mood() {   # INTENT → mood phrase (may be empty)
  case "$1" in
    prod)     printf 'urgently and seriously, like an on-call alert' ;;
    error)    printf 'calmly and matter-of-factly, not alarmed' ;;
    ship)     printf 'cheerfully, like good news to the team' ;;
    review)   printf 'calmly, like a senior reviewer' ;;
    test)     printf 'briskly and practically' ;;
    plan)     printf 'thoughtfully' ;;
    question) printf 'helpfully and curiously' ;;
    *)        printf '' ;;
  esac
}

# ── cue + mix per INTENT (a request's flavour) ─────────────────────────────────────
# Echoes "<cue>|<mix>|<volume>"; an empty cue means speak plain. PIPE-separated because the
# no-cue case has an empty first field and a space-split `read` would collapse it — that bug
# cost the plain path in milestone.sh once already, so both maps use the same shape.
#
# Note: milestone.sh has its OWN map keyed by the EVENT GROUP (green/red/ship/needs-you), not
# by request intent. They are different questions — "what was asked for" vs "what happened" —
# and collapsing them would tie a review request's cue to a review verdict's.
variety_cue() {   # INTENT
  case "$1" in
    prod)   printf '%s|%s|%s' incident under 0.15 ;;   # bad news sits UNDER the words, quietly
    error)  printf '%s|%s|%s' red under 0.15 ;;
    ship)   printf '%s|%s|%s' ship sting 0.5 ;;        # cue first, then talk over its tail
    review) printf '%s|%s|%s' green tail 0.4 ;;        # cue lands as the sentence does
    *)      printf '%s|%s|%s' '' under 0.22 ;;
  esac
}

# ── voice per role ────────────────────────────────────────────────────────────────
# One voice for everything makes every event sound like the same event. Incidents and verdicts
# get the alternate voice when one is configured (voice.tts.voice_alt.<provider>); everything
# else keeps the default. No alt configured ⇒ silently one voice, never a broken request.
variety_alt_voice_for() {   # INTENT → a voice id, or empty
  case "$1" in
    prod|error|review) voice_cfg "voice.tts.voice_alt.${VOICE_TTS_PROVIDER:-elevenlabs}" "" ;;
    *) printf '' ;;
  esac
}

# ── phrasing: six shapes, rotated ─────────────────────────────────────────────────
# A counter, not a random pick: random repeats itself visibly (two identical shapes in a row
# reads as "it only knows one phrasing"), and a cycle of six never does.
VOICE_SEED_FILE="$VOICE_CACHE_HOME/seed.count"

variety_seed() {   # → a phrasing instruction for the summarizer
  local n=0
  [[ -f "$VOICE_SEED_FILE" ]] && n="$(cat "$VOICE_SEED_FILE" 2>/dev/null || printf 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$(( (n + 1) % 6 ))" > "$VOICE_SEED_FILE" 2>/dev/null || true
  case "$(( n % 6 ))" in
    0) printf 'confirm, and name the concrete thing you will look at first' ;;
    1) printf 'confirm, and add where you think the cause probably is' ;;
    2) printf 'confirm, and say which repo or file you are opening' ;;
    3) printf 'confirm briefly, then say what you will report back' ;;
    4) printf 'restate the request in your own words, compressed to its essence' ;;
    5) printf 'confirm, and name the one thing that would make this quick' ;;
  esac
}

# ── time of day ───────────────────────────────────────────────────────────────────
# Not decoration: at 1am a long cheerful sentence is the wrong register, and the summarizer
# will shorten if told why.
variety_timeofday() {
  local h; h="$(date +%H)"; h="${h#0}"
  if   (( h >= 0 && h < 6 ));  then printf 'it is the small hours: be brief and low-key'
  elif (( h >= 6 && h < 11 )); then printf ''
  elif (( h >= 22 ));          then printf 'it is late: keep it short'
  else printf ''
  fi
}

# ── the particle, pinned to the voice ─────────────────────────────────────────────
variety_particle() {   # f|m → ค่ะ|ครับ
  case "$1" in m) printf 'ครับ' ;; *) printf 'ค่ะ' ;; esac
}
