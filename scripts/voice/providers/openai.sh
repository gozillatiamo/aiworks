#!/usr/bin/env bash
# TTS provider — OpenAI `gpt-4o-mini-tts`.
#
# Measured: nova 93 % term survival / 0.950 similarity, and the FASTEST of the accurate
# engines at 2.0–2.8 s. Mood is a free-text `instructions` field rather than inline tags,
# which is more reliable than ElevenLabs' audio tags — the instruction is prefixed with
# "Speak in Thai" because the model otherwise reads Thai with an English accent.
#
# Price ≈ $45/1M chars — between ElevenLabs ($100) and Gemini ($16.7).

# shellcheck source=./common.sh
. "$VOICE_DIR/providers/common.sh"

voice_tts_describe() {
  printf '%s %s %s' openai "$(voice_pick nova)" "$(voice_cfg voice.tts.model gpt-4o-mini-tts)"
}

voice_tts_gender() {
  voice_pick_gender "$(voice_pick nova)" nova:f shimmer:f coral:f alloy:f onyx:m echo:m ash:m
}

voice_tts_synth() {   # TEXT OUT_MP3
  local text="$1" out="$2" voice model key instr
  voice="$(voice_pick nova)"
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
