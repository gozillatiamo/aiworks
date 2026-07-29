#!/usr/bin/env bash
# TTS provider — ElevenLabs. The shipped default (decision #1).
#
# Measured over ALL 24 voices on this account, five Thai+English dev sentences, median of five
# transcription passes: Sarah kept 37 of 43 English technical tokens in Latin script — tied for
# best here, and with a spread of ±1 the single steadiest voice of any vendor measured. Which
# is why it is still the default; the sweep confirmed the original pick rather than replacing
# it. See `scripts/voice/README.md` § Thai voice selection.
#
# ⚠ FIVE of the 24 cannot really do Thai: Roger, Brian, Daniel, Liam and Will transliterate
# every English term into Thai script ("คอมมิชชั่นแคลคูเลเตอร์"), scoring 0/11 on the screening
# line. River is worse — it romanizes the Thai itself ("Review tit lau mih khṳ̀…").
# ⚠ Laura tops a ONE-PASS screen (11/11) and falls to 31/43 over five, with the widest spread
# in the study (±21) — and on one line it TRANSLATED `develop` into Thai ("เข้าพัฒนาแล้ว").
# A one-sentence audition cannot see any of that.
#
# ⚠ MODEL: only `eleven_v3` lists Thai (74 locales). `eleven_flash_v2_5` and `turbo_v2_5`
# cover 32 locales and Thai is NOT among them, so do not "optimize" onto flash for latency.
# ⚠ Audio tags (`[cheerfully]`, `[urgently]`) land maybe half the time — a nudge, not a
# guarantee. Never make correctness depend on one.
# ⚠ The shared voice library has ZERO Thai voices, and an IVC clone of a native Thai
# reference measured WORSE than stock Sarah (89 % vs 96 %) — the stock voices are the answer.

# shellcheck source=./common.sh
. "$VOICE_DIR/providers/common.sh"

EL_SARAH='EXAVITQu4vr4xnSDxMaL'   # female — 37/43, spread ±1
EL_GEORGE='JBFqnCBsd6RMkjVDRZzb'  # male
EL_JESSICA='cgSgspJ2msm6clMCkdW9' # female — 35/43, the runner-up
EL_CHRIS='iP95p4xoKVk53GoZ742B'   # male   — 37/43 but ±11; the best male on Thai here

voice_tts_describe() {
  printf '%s %s %s' elevenlabs "$(voice_pick "$EL_SARAH")" "$(voice_cfg voice.tts.model eleven_v3)"
}

voice_tts_gender() {
  voice_pick_gender "$(voice_pick "$EL_SARAH")" \
    "$EL_SARAH:f" "$EL_JESSICA:f" "$EL_GEORGE:m" "$EL_CHRIS:m"
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
