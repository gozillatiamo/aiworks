#!/usr/bin/env bash
# TTS provider — Cartesia `sonic-3`, with native Thai voices.
#
# Measured: the FASTEST accurate engine (1.7–3.1 s) — but quality here is PER VOICE, not per
# vendor: Somchai scored 89 % term survival / 0.950 similarity while Narin, same model same
# request, scored 63 % / 0.805. Audition a voice before configuring it; do not assume the
# vendor's other Thai voices inherit Somchai's numbers.
#
# ⚠ Three request-shape traps, all of them silent-ish failures:
#     the `Cartesia-Version: 2025-04-16` header is REQUIRED
#     the text field is `transcript`, not `text`
#     `output_format` is an object, and mp3 needs container + sample_rate + bit_rate
# ⚠ Pricing is plan-based (credits/month), not per-request: free 20K credits, Pro $5 = 100K
#   ≈ 133 min of TTS. A busy day can exhaust a plan in a way a per-char vendor cannot.
#
# Only two voice ids were captured in full during the benchmark (below). The other five Thai
# voices (Suda, Chakrit, Kanya, Krit, Thaksin) are listed by
# `agent_logs/voice/bench/list_voices.py` — re-run it rather than guessing an id.

# shellcheck source=./common.sh
. "$VOICE_DIR/providers/common.sh"

CART_SOMCHAI='5de076e9-7b28-4442-b279-e7d80d573505'   # male, the measured-good one
CART_NARIN='273193f7-dbff-438e-b8af-fcc499200b1c'     # male, measured 63 % — kept as a warning

voice_tts_describe() {
  printf '%s %s %s' cartesia "$(voice_pick "$CART_SOMCHAI")" "$(voice_cfg voice.tts.model sonic-3)"
}

voice_tts_gender() {
  voice_pick_gender "$(voice_pick "$CART_SOMCHAI")" "$CART_SOMCHAI:m" "$CART_NARIN:m"
}

voice_tts_synth() {   # TEXT OUT_MP3
  local text="$1" out="$2" voice model key
  voice="$(voice_pick "$CART_SOMCHAI")"
  model="$(voice_cfg voice.tts.model sonic-3)"
  key="$(voice_need_key CARTESIA_API_KEY)"
  jq -nc --arg t "$text" --arg v "$voice" --arg m "$model" '
      {model_id: $m, transcript: $t, voice: {mode: "id", id: $v}, language: "th",
       output_format: {container: "mp3", sample_rate: 44100, bit_rate: 128000}}' \
    | voice_http_post_binary \
        "https://api.cartesia.ai/tts/bytes" \
        "$out" \
        "X-API-Key: $key" \
        "Cartesia-Version: 2025-04-16" \
        "Content-Type: application/json"
}
