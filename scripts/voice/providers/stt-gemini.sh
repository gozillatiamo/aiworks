#!/usr/bin/env bash
# STT provider — Gemini `2.5-flash` with inline audio.
#
# Measured: 0.837 / 2.5–3.2 s — the least accurate of the three shipped options, and by far the
# CHEAPEST at ~$0.115 per hour of audio (vs $0.36 for OpenAI, $0.22 for ElevenLabs). Worth it
# for bulk transcription, not for dictation you are about to send as a prompt.
#
# ⚠ There is no transcription endpoint: this is a normal generateContent call with the audio as
#   inline base64 and an instruction to transcribe. So the "prompt" is the whole instruction,
#   and it must say to keep English terms in Latin script — without that Gemini transliterates
#   them into Thai, which is exactly what made the rejected engines unusable.
# ⚠ Inline data caps the request at ~20 MB. A minute of 16 kHz mono wav is ~2 MB, so a dictation
#   utterance is fine; a long recording needs the Files API instead.

# shellcheck source=./common.sh
. "$VOICE_DIR/providers/common.sh"

voice_stt_describe() { printf '%s %s' gemini "$(voice_cfg voice.stt.model gemini-2.5-flash)"; }

voice_stt_transcribe() {   # AUDIO_FILE [MODEL_OVERRIDE] → text on stdout
  local f="$1" model="${2:-}" key hint mime out text b64
  [[ -s "$f" ]] || { vlog "stt: no audio at $f"; return 1; }
  [[ -n "$model" ]] || model="$(voice_cfg voice.stt.model gemini-2.5-flash)"
  key="$(voice_need_key GEMINI_VOICE_API_KEY)"
  hint="$(voice_stt_hint)"
  case "$f" in
    *.wav) mime='audio/wav' ;;
    *.mp3) mime='audio/mpeg' ;;
    *.m4a) mime='audio/mp4' ;;
    *)     mime='audio/wav' ;;
  esac
  b64="$(base64 -i "$f" | tr -d '\n')" || { vlog "stt/gemini: base64 failed"; return 1; }

  out="$(jq -nc --arg t "Transcribe this Thai speech verbatim. Keep every English technical term, identifier, ticket key and file name in LATIN script exactly as spoken — never transliterate them into Thai. Output the transcript only, no preamble. Domain vocabulary: $hint" \
             --arg m "$mime" --arg d "$b64" '
          {contents: [{parts: [{text: $t}, {inline_data: {mime_type: $m, data: $d}}]}],
           generationConfig: {thinkingConfig: {thinkingBudget: 0}}}' \
        | curl -sS --max-time 120 -X POST \
            "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent" \
            -H "x-goog-api-key: $key" -H "Content-Type: application/json" --data-binary @-)" \
    || { vlog "stt/gemini: request failed"; return 1; }
  text="$(printf '%s' "$out" | jq -r '.candidates[0].content.parts[0].text // empty')"
  if [[ -z "$text" ]]; then
    vlog "stt/gemini: no text — $(printf '%s' "$out" | head -c 200)"
    return 1
  fi
  printf '%s' "$text" | tr '\n' ' ' | sed -E 's/^ +//; s/ +$//'
}
