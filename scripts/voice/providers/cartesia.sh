#!/usr/bin/env bash
# TTS provider — Cartesia `sonic-3`, with native Thai voices.
#
# Measured: the FASTEST accurate engine (1.6–2.3 s) and the only vendor whose voices are
# NATIVE Thai — which shows up exactly where it matters. On a line that packs English terms
# into dense Thai with no pauses ("query นี้ใช้เวลา 450 ms ที่ index scan…"), these voices kept
# 5–6 of 6 terms in Latin script while ElevenLabs Sarah kept 1 and Gemini and OpenAI's nova
# kept 0 — everyone else transliterates ("อินเด็กซ์สแกน", "เรดิส", "เลเทนซี").
#
# Quality is still PER VOICE, not per vendor: three of the seven tie at the top (41/43) and
# Narin is the worst of the field. Audition before configuring; do not assume a Thai voice id
# inherits its neighbour's numbers.
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

# All seven native Thai voices the vendor lists, with the gender the API itself reports
# (`GET /voices/` → `.gender`) and the measured score: English technical tokens kept in Latin
# script out of 43, median of five transcription passes over five Thai+English dev sentences.
CART_SUDA='ccc7bb22-dcd0-42e4-822e-0731b950972f'      # f — 41/43, the default here
CART_THAKSIN='db938869-18b5-4c21-be8b-2ffdfba6d8d4'   # m — 41/43, steadiest on the hardest line
CART_SOMCHAI='5de076e9-7b28-4442-b279-e7d80d573505'   # m — 41/43, the previous default
CART_CHAKRIT='aaa0bf6d-bc07-40f2-bc6b-66afc5fd42f6'   # m — 38/43
CART_NARIN='273193f7-dbff-438e-b8af-fcc499200b1c'     # f — worst of the seven on the screen
CART_KANYA='8810fbfa-b317-4503-9974-9774d08b5897'     # f
CART_KRIT='a50a04b8-35ee-487e-8b87-97f0eee68a64'      # m

voice_tts_describe() {
  printf '%s %s %s' cartesia "$(voice_pick "$CART_SUDA")" "$(voice_cfg voice.tts.model sonic-3)"
}

voice_tts_gender() {
  voice_pick_gender "$(voice_pick "$CART_SUDA")" \
    "$CART_SUDA:f" "$CART_NARIN:f" "$CART_KANYA:f" \
    "$CART_THAKSIN:m" "$CART_SOMCHAI:m" "$CART_CHAKRIT:m" "$CART_KRIT:m"
}

voice_tts_synth() {   # TEXT OUT_MP3
  local text="$1" out="$2" voice model key
  voice="$(voice_pick "$CART_SUDA")"
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
