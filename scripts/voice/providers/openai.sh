#!/usr/bin/env bash
# TTS provider — OpenAI `gpt-4o-mini-tts`.
#
# Measured (all 13 voices, five Thai+English dev sentences, median of 5 transcription passes):
# `sage` kept 42 of 43 English technical tokens in Latin script — the BEST Thai result of any
# vendor tried, and 2.3 s. It is the default here for that reason. `nova`, the earlier default,
# scored 35; `coral` 37; `cedar` 34. Mood is a free-text `instructions` field rather than
# inline tags, which is more reliable than ElevenLabs' audio tags — the instruction is prefixed
# with "Speak in Thai" because the model otherwise reads Thai with an English accent.
#
# ⚠ `marin` and `cedar` exist on this endpoint but are NOT in the older docs' list of 11 —
# the authoritative roster is the 400 error from an invalid `voice` value.
#
# Price ≈ $45/1M chars — between ElevenLabs ($100) and Gemini ($16.7).

# shellcheck source=./common.sh
. "$VOICE_DIR/providers/common.sh"

voice_tts_describe() {
  printf '%s %s %s' openai "$(voice_pick sage)" "$(voice_cfg voice.tts.model gpt-4o-mini-tts)"
}

voice_tts_gender() {
  voice_pick_gender "$(voice_pick sage)" \
    sage:f nova:f shimmer:f coral:f alloy:f marin:f fable:f \
    onyx:m echo:m ash:m cedar:m verse:m ballad:m
}

voice_tts_synth() {   # TEXT OUT_MP3
  local text="$1" out="$2" voice model key instr
  voice="$(voice_pick sage)"
  model="$(voice_cfg voice.tts.model gpt-4o-mini-tts)"
  key="$(voice_need_key OPENAI_API_KEY)"
  # VOICE_MOOD is set by the caller (ack/milestone) in Phase 2; plain speech has no mood.
  instr="Speak in Thai${VOICE_MOOD:+, $VOICE_MOOD}."
  jq -nc --arg t "$text" --arg v "$voice" --arg m "$model" --arg i "$instr" \
      '{model: $m, voice: $v, input: $t, instructions: $i, response_format: "mp3"}' \
    | voice_http_post_binary \
        "https://api.openai.com/v1/audio/speech" \
        "$out" \
        "Authorization: Bearer $key" \
        "Content-Type: application/json"
}
