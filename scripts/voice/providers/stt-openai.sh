#!/usr/bin/env bash
# STT provider — OpenAI. The shipped default (decision #2).
#
# Measured on five Thai+English dev clips with known ground truth: `gpt-4o-transcribe` scored
# 0.915 char-similarity at 1.37 s, the best of the eleven engines tried, and — the part that
# matters for dictation into a terminal — it KEEPS English technical terms in Latin script
# (`SonarQube`, `null check`, `pricing calculator` all survived). Every rejected engine
# transliterated them into Thai, which is unusable as a prompt.
#
#   gpt-4o-transcribe       0.915 / 1.37 s / $0.006 per min   ← default
#   gpt-4o-mini-transcribe  0.870 / 0.94 s / $0.003 per min   ← faster + half price, for previews
#   whisper-1               0.884 / 1.56 s / $0.006 per min
#
# The `prompt` field carries the domain hint (scripts/voice/stt-hint.txt). It is not decoration:
# without it `null check` comes back as "now check" — the model has no way to know this is a
# codebase conversation.

# shellcheck source=./common.sh
. "$VOICE_DIR/providers/common.sh"

voice_stt_describe() { printf '%s %s' openai "$(voice_cfg voice.stt.model gpt-4o-transcribe)"; }

voice_stt_transcribe() {   # AUDIO_FILE [MODEL_OVERRIDE] → text on stdout
  local f="$1" model="${2:-}" key hint out
  [[ -s "$f" ]] || { vlog "stt: no audio at $f"; return 1; }
  [[ -n "$model" ]] || model="$(voice_cfg voice.stt.model gpt-4o-transcribe)"
  key="$(voice_need_key OPENAI_API_KEY)"
  hint="$(voice_stt_hint)"
  out="$(curl -sS --max-time 120 -X POST "https://api.openai.com/v1/audio/transcriptions" \
          -H "Authorization: Bearer $key" \
          -F "file=@$f" -F "model=$model" -F "language=th" -F "prompt=$hint")" \
    || { vlog "stt/openai: request failed"; return 1; }
  local text; text="$(printf '%s' "$out" | jq -r '.text // empty')"
  if [[ -z "$text" ]]; then
    vlog "stt/openai: no text — $(printf '%s' "$out" | head -c 200)"
    return 1
  fi
  printf '%s' "$text"
}
