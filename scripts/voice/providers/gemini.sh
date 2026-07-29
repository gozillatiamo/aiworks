#!/usr/bin/env bash
# TTS provider — Gemini `gemini-2.5-flash-preview-tts`.
#
# Measured: 93 % term survival / 0.962 similarity, natively good at Thai, and it reads bare
# digits correctly ("บรรทัด 142") so no number normalizer is needed. ~6× cheaper than
# ElevenLabs (≈$16.7 vs $100 per 1M chars) — the switch to make when the bill matters.
#
# ⚠ LATENCY IS VARIABLE: 4.5 s to 15.9 s observed on identical-length input. Fine for a
# milestone, risky for anything the user is waiting on.
# ⚠ IT DOES NOT RETURN A CONTAINER. The response is base64 raw PCM (`audio/L16;codec=pcm;
# rate=24000`); writing it to an .mp3 yields a file nothing will play. ffmpeg wraps it below.
# ⚠ CREDENTIAL: GEMINI_VOICE_API_KEY, deliberately NOT the image-generator's GEMINI_API_KEY
# (decision #3) — one key per feature keeps a voice quota problem out of the design pipeline.

# shellcheck source=./common.sh
. "$VOICE_DIR/providers/common.sh"

voice_tts_describe() {
  printf '%s %s %s' gemini "$(voice_pick Kore)" "$(voice_cfg voice.tts.model gemini-2.5-flash-preview-tts)"
}

voice_tts_gender() {
  voice_pick_gender "$(voice_pick Kore)" Kore:f Leda:f Aoede:f Puck:m Charon:m Enceladus:m Fenrir:m
}

voice_tts_synth() {   # TEXT OUT_MP3
  local text="$1" out="$2" voice model key tmp pcm rate
  voice="$(voice_pick Kore)"
  model="$(voice_cfg voice.tts.model gemini-2.5-flash-preview-tts)"
  key="$(voice_need_key GEMINI_VOICE_API_KEY)"
  voice_require ffmpeg

  tmp="$(mktemp -t voice-gemini.XXXXXX)" || vdie "mktemp failed"
  # VOICE_MOOD (Phase 2) is a style instruction, and Gemini takes it as plain prose in the
  # prompt — this model has no separate style field.
  jq -nc --arg t "${VOICE_MOOD:+Say this ${VOICE_MOOD}: }$text" --arg v "$voice" '
      {contents: [{parts: [{text: $t}]}],
       generationConfig: {responseModalities: ["AUDIO"],
                          speechConfig: {voiceConfig: {prebuiltVoiceConfig: {voiceName: $v}}}}}' \
    | voice_http_post_binary \
        "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent" \
        "$tmp" \
        "x-goog-api-key: $key" \
        "Content-Type: application/json"

  # rate comes from the response's own mimeType, not a constant — the model has changed it
  # before, and a wrong rate does not fail, it just plays at the wrong pitch.
  rate="$(jq -r '.candidates[0].content.parts[0].inlineData.mimeType // ""' "$tmp" \
          | sed -nE 's/.*rate=([0-9]+).*/\1/p')"
  [[ -n "$rate" ]] || rate=24000

  pcm="$tmp.pcm"
  if ! jq -r '.candidates[0].content.parts[0].inlineData.data // empty' "$tmp" \
       | base64 --decode > "$pcm" 2>/dev/null || [[ ! -s "$pcm" ]]; then
    local msg; msg="$(head -c 300 "$tmp" | tr -d '\n')"
    rm -f "$tmp" "$pcm"
    vdie "gemini: no inline audio in the response — $msg"
  fi
  ffmpeg -y -loglevel error -f s16le -ar "$rate" -ac 1 -i "$pcm" -c:a libmp3lame -b:a 128k "$out" \
    || { rm -f "$tmp" "$pcm" "$out"; vdie "gemini: ffmpeg could not wrap the PCM"; }
  rm -f "$tmp" "$pcm"
}
