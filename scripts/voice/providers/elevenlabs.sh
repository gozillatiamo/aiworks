#!/usr/bin/env bash
# TTS provider — ElevenLabs. The shipped default (decision #1).
#
# Measured on this workspace's Thai+English dev sentences: Sarah kept 96 % of the English
# technical tokens in Latin script at 0.958 char-similarity, the best of the nine voices
# tried — see agent_logs/voice/implementation-plan.md §3.
#
# ⚠ MODEL: only `eleven_v3` lists Thai (74 locales). `eleven_flash_v2_5` and `turbo_v2_5`
# cover 32 locales and Thai is NOT among them, so do not "optimize" onto flash for latency.
# ⚠ Audio tags (`[cheerfully]`, `[urgently]`) land maybe half the time — a nudge, not a
# guarantee. Never make correctness depend on one.
# ⚠ The shared voice library has ZERO Thai voices, and an IVC clone of a native Thai
# reference measured WORSE than stock Sarah (89 % vs 96 %) — the stock voices are the answer.

# shellcheck source=./common.sh
. "$VOICE_DIR/providers/common.sh"

EL_SARAH='EXAVITQu4vr4xnSDxMaL'   # female
EL_GEORGE='JBFqnCBsd6RMkjVDRZzb'  # male

voice_tts_describe() {
  printf '%s %s %s' elevenlabs "$(voice_pick "$EL_SARAH")" "$(voice_cfg voice.tts.model eleven_v3)"
}

voice_tts_gender() {
  voice_pick_gender "$(voice_pick "$EL_SARAH")" "$EL_SARAH:f" "$EL_GEORGE:m"
}

voice_tts_synth() {   # TEXT OUT_MP3
  local text="$1" out="$2" voice model key
  voice="$(voice_pick "$EL_SARAH")"
  model="$(voice_cfg voice.tts.model eleven_v3)"
  key="$(voice_need_key ELEVENLABS_API_KEY)"
  jq -nc --arg t "$text" --arg m "$model" '{text: $t, model_id: $m}' \
    | voice_http_post_binary \
        "https://api.elevenlabs.io/v1/text-to-speech/$voice?output_format=mp3_44100_128" \
        "$out" \
        "xi-api-key: $key" \
        "Content-Type: application/json"
}
