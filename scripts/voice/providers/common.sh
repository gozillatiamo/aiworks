#!/usr/bin/env bash
# Shared helpers for the TTS providers. Sourced by each providers/<name>.sh.
#
# The voice id is read per-provider so switching voice.tts.provider does not carry a voice
# id from the wrong vendor:
#   voice.tts.voice.<provider>   preferred (block form, one line per vendor)
#   voice.tts.voice             scalar form, for a single-vendor setup
#   <the provider's default>    last resort
#
# Gender comes from the same chain plus a per-provider table, and it is not cosmetic: the
# summarizer must pin the Thai sentence-final particle to the voice (`ครับ` male / `ค่ะ`
# female). A male voice saying "ได้เลยค่ะ" was a real bug in the demo round.

# voice_pick VOICE_DEFAULT — the resolved voice id for the current provider.
voice_pick() {
  local def="$1" v
  if [[ -n "${VOICE_TTS_VOICE_FORCE:-}" ]]; then printf '%s' "$VOICE_TTS_VOICE_FORCE"; return 0; fi
  v="$(voice_cfg "voice.tts.voice.$VOICE_TTS_PROVIDER" "")"
  [[ -n "$v" ]] || v="$(voice_cfg voice.tts.voice "")"
  [[ -n "$v" ]] || v="$def"
  printf '%s' "$v"
}

# voice_pick_gender VOICE_ID TABLE… — TABLE entries are "<id-or-name>:<f|m>".
voice_pick_gender() {
  local id="$1"; shift
  local g row
  g="$(voice_cfg "voice.tts.gender.$VOICE_TTS_PROVIDER" "")"
  if [[ -n "$g" ]]; then printf '%s' "$g"; return 0; fi
  for row in "$@"; do
    [[ "${row%%:*}" == "$id" ]] && { printf '%s' "${row##*:}"; return 0; }
  done
  printf 'f'   # the shipped default voice is female on every provider below
}

# voice_http_post_binary URL OUT_FILE HEADER… — POST the body on stdin, write the response
# body to OUT_FILE, and fail loudly on a non-2xx. The response body is only surfaced on
# error (first 300 chars), where it is the vendor's JSON error, never a credential.
voice_http_post_binary() {
  local url="$1" out="$2"; shift 2
  local args=() h code
  for h in "$@"; do args+=(-H "$h"); done
  code="$(curl -sS --max-time 180 -o "$out" -w '%{http_code}' -X POST "${args[@]}" --data-binary @- "$url")" \
    || { rm -f "$out"; vdie "$VOICE_TTS_PROVIDER: curl failed for $url"; }
  if [[ "$code" != 2* ]]; then
    local msg; msg="$(head -c 300 "$out" 2>/dev/null | tr -d '\n')"
    rm -f "$out"
    vdie "$VOICE_TTS_PROVIDER: HTTP $code — $msg"
  fi
  [[ -s "$out" ]] || { rm -f "$out"; vdie "$VOICE_TTS_PROVIDER: empty audio response"; }
}
