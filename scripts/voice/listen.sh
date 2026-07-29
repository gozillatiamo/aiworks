#!/usr/bin/env bash
#
# Audio file → text. The speech-to-text half of the adapter, and the only thing that talks to an
# STT vendor.
#
# Usage:
#   listen.sh [-v] [--provider openai|gemini|elevenlabs] [--model M] [--fast] FILE
#
#   --fast   use the provider's cheaper/faster model — for an interim preview, where being 4 %
#            less accurate a second sooner is the right trade. The text that actually gets sent
#            is always transcribed by the accurate model.
#
# Prints the transcript on stdout, nothing on failure. No cache: two recordings are never the
# same bytes, so a content-addressed cache would be a pure miss.
#
# ⚠ NOT gated on mute. Mute disables the OUTPUT half of the feature (and so its spend); this is
#   INPUT, it happens only because you held a key, and refusing to transcribe what you just said
#   into the microphone because the speakers are silent would be the switch breaking something you
#   explicitly asked for. See the mute note in lib.sh.

set -euo pipefail
# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PROVIDER="" MODEL="" FAST=0 FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) export VOICE_VERBOSE=1; shift ;;
    --provider)   PROVIDER="${2:?}"; shift 2 ;;
    --model)      MODEL="${2:?}"; shift 2 ;;
    --fast)       FAST=1; shift ;;
    -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; exit 0 ;;
    -*)           vdie "unknown option $1 (see -h)" ;;
    *)            FILE="$1"; shift ;;
  esac
done

[[ -n "$FILE" ]] || vdie "usage: listen.sh [options] FILE"
[[ -s "$FILE" ]] || vdie "no audio at $FILE"

voice_gate_or_exit "listen"
voice_require jq curl
voice_load_credentials
[[ -z "$PROVIDER" ]] || export VOICE_STT_PROVIDER_FORCE="$PROVIDER"
voice_load_stt_provider

# --fast picks the cheap model per vendor rather than a config key: it is a per-CALL decision
# (preview vs final), not a machine preference, and hard-coding the pairing keeps the two from
# drifting apart in config.
if [[ "$FAST" -eq 1 && -z "$MODEL" ]]; then
  case "$VOICE_STT_PROVIDER" in
    openai)     MODEL='gpt-4o-mini-transcribe' ;;   # 0.870 / 0.94 s / half price
    elevenlabs) MODEL='scribe_v1' ;;
    gemini)     MODEL='gemini-2.5-flash' ;;
  esac
fi

t0="$(voice_now)"
TEXT="$(voice_stt_transcribe "$FILE" "$MODEL" || true)"
[[ -n "$TEXT" ]] || { vlog "listen: no transcript"; exit 1; }

# ── the prompt-echo guard ─────────────────────────────────────────────────────────
# Handed near-silence, these models return their own `prompt` as the transcript. Measured: a
# 7 s hold with nothing said came back as the whole domain hint. ptt.sh screens for silence
# BEFORE calling, but the guard belongs here too — every caller of listen.sh is exposed, the
# silence threshold cannot be perfect, and injecting the hint into a session as if it were
# something the user said is the worst failure this feature has.
HINT="$(voice_stt_hint)"
if [[ -n "$HINT" ]]; then
  head_of_hint="$(printf '%s' "$HINT" | cut -c1-40)"
  if [[ "$TEXT" == *"$head_of_hint"* ]]; then
    vlog "listen: the transcript is the domain hint echoed back (silence) — discarding"
    exit 1
  fi
  # A partial echo: mostly hint terms and little else. Compare on comma-separated terms rather
  # than words, since the hint is a term list and real speech is prose.
  n_terms="$(printf '%s' "$TEXT" | tr ',' '\n' | grep -c . || printf 0)"
  if [[ "$n_terms" -ge 6 ]]; then
    hits=0
    while IFS= read -r term; do
      term="$(printf '%s' "$term" | sed -E 's/^ +//; s/ +$//')"
      [[ ${#term} -ge 3 ]] || continue
      [[ "$HINT" == *"$term"* ]] && hits=$((hits + 1))
    done < <(printf '%s' "$TEXT" | tr ',' '\n')
    if [[ "$hits" -ge $(( n_terms * 2 / 3 )) ]]; then
      vlog "listen: $hits of $n_terms comma-separated terms are hint entries — discarding as an echo"
      exit 1
    fi
  fi
fi

# A near-silent recording that produced one or two words is a hallucination, not a short
# sentence: measured, a hold with nothing said came back as the single word "context". Discard
# when the audio is quiet AND the transcript is tiny — both conditions, so a genuinely short
# utterance ("ต่อ") spoken at normal volume survives.
if command -v ffmpeg >/dev/null 2>&1; then
  mean="$(ffmpeg -hide_banner -i "$FILE" -af volumedetect -f null - 2>&1 \
          | sed -nE 's/.*mean_volume: (-?[0-9.]+) dB.*/\1/p' | head -1)"
  chars="$(printf '%s' "$TEXT" | wc -m | tr -d ' ')"
  if [[ -n "$mean" ]] && [[ "$chars" -le 12 ]] \
     && python3 -c "import sys; sys.exit(0 if float('$mean') < -40 else 1)"; then
    vlog "listen: ${chars} chars from ${mean}dB audio — hallucination, discarding"
    exit 1
  fi
fi

vlog "listen ($(voice_stt_describe)${MODEL:+ → $MODEL}, $(( $(voice_now) - t0 ))s): $TEXT"
printf '%s\n' "$TEXT"
