#!/usr/bin/env bash
# STT provider — ElevenLabs Scribe.
#
# Measured: `scribe_v1` 0.889 / 2.05 s, `scribe_v2` 0.883 / 2.29 s — accurate, and it keeps
# English terms in Latin script, but it over-capitalizes ("Commission Calculator"). Priced per
# HOUR ($0.22) rather than per minute, so it is the cheaper choice for long dictation and the
# dearer one for a stream of two-second utterances.
#
# ⚠ The language field is `language_code`, not `language`, and the file field is `file` in a
#   multipart body — not the JSON shape the TTS side of this vendor uses.

# shellcheck source=./common.sh
. "$VOICE_DIR/providers/common.sh"

voice_stt_describe() { printf '%s %s' elevenlabs "$(voice_cfg voice.stt.model scribe_v1)"; }

voice_stt_transcribe() {   # AUDIO_FILE [MODEL_OVERRIDE] → text on stdout
  local f="$1" model="${2:-}" key out text
  [[ -s "$f" ]] || { vlog "stt: no audio at $f"; return 1; }
  [[ -n "$model" ]] || model="$(voice_cfg voice.stt.model scribe_v1)"
  key="$(voice_need_key ELEVENLABS_API_KEY)"
  out="$(curl -sS --max-time 120 -X POST "https://api.elevenlabs.io/v1/speech-to-text" \
          -H "xi-api-key: $key" \
          -F "file=@$f" -F "model_id=$model" -F "language_code=th")" \
    || { vlog "stt/elevenlabs: request failed"; return 1; }
  text="$(printf '%s' "$out" | jq -r '.text // empty')"
  if [[ -z "$text" ]]; then
    vlog "stt/elevenlabs: no text — $(printf '%s' "$out" | head -c 200)"
    return 1
  fi
  printf '%s' "$text"
}
