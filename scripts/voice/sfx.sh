#!/usr/bin/env bash
#
# The cue catalog — eight short sounds, generated ONCE and then free forever.
#
# Usage:
#   sfx.sh generate [--force] [NAME…]    build the catalog (default: everything missing)
#   sfx.sh list                          what exists, how long, how loud
#   sfx.sh play NAME                     hear one
#
# WHY CUES AT ALL
#   A cue answers "did it hear me?" in 400 ms, which is the one question speech is too slow to
#   answer. It is also the only part of this feature with no running cost: generated once,
#   cached, played by afplay for the rest of time.
#
# PROVIDERS (voice.sfx.provider)
#   elevenlabs  /v1/sound-generation from a text prompt. On the Starter plan this moved the
#               credit counter by ZERO in measurement, so the whole catalog is effectively free.
#   system      macOS /System/Library/Sounds. No network, no key, no account — the fallback
#               that always works, and the right choice on a machine with no ElevenLabs key.
#   Noiz is deliberately NOT a provider: its skills are being removed (its Thai was unusable
#   and it shipped six bugs), and /v1/text-to-sound rate-limited rapid calls at 429. Keeping a
#   provider for a vendor we are cancelling would be dead code with a maintenance cost.
#
# EVERY CUE IS PEAK-NORMALIZED to the same level at generation time. Without it one generated
# cue comes back twice as loud as the others and startles you at 1am. Peak normalization, not
# loudnorm: these clips are 0.4–1.8 s and loudnorm's dynamic analysis needs seconds of audio
# to settle.

set -euo pipefail
# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TARGET_PEAK_DB=-6      # every cue ends up here, so no cue is ever the loud one

# name | seconds | elevenlabs prompt | macOS system sound
CATALOG=(
  "ack|0.5|a single very short soft digital blip, a quiet message-received notification, clean, no music, no reverb|Tink"
  "attention|0.9|a short neutral two-note attention chime, a gentle notification asking someone to look, neither success nor error|Ping"
  "ptt_start|0.5|a short rising two-tone digital blip, a microphone switching on, clean UI sound, no music|Pop"
  "ptt_stop|0.5|a short falling two-tone digital blip, a microphone switching off, clean UI sound, no music|Purr"
  "green|1.0|a short bright friendly chime of two ascending notes, a success confirmation, gentle, no music bed|Glass"
  "red|0.9|a short soft low buzz, a gentle error notification, not harsh, not an alarm, no music|Basso"
  "ship|1.8|a short celebratory fanfare, bright and playful, a level-up sound|Hero"
  "incident|1.0|an urgent double beep alert, serious on-call notification, attention-getting but not painful|Sosumi"
)

_entry() {   # NAME → the catalog row, or nothing
  local row
  for row in "${CATALOG[@]}"; do [[ "${row%%|*}" == "$1" ]] && { printf '%s' "$row"; return 0; }; done
  return 1
}

_names() { local row; for row in "${CATALOG[@]}"; do printf '%s\n' "${row%%|*}"; done; }

# ── peak normalization ────────────────────────────────────────────────────────────
_normalize() {   # IN OUT SECONDS — trim to length, fade the tail, level it
  local in="$1" out="$2" secs="$3" peak gain fade_at
  peak="$(ffmpeg -hide_banner -i "$in" -af volumedetect -f null - 2>&1 \
          | sed -nE 's/.*max_volume: (-?[0-9.]+) dB.*/\1/p' | head -1)"
  if [[ -z "$peak" ]]; then
    vlog "could not measure $in — copying without normalization"
    cp "$in" "$out"; return 0
  fi
  gain="$(python3 -c "print(round($TARGET_PEAK_DB - ($peak), 2))")"
  # An abrupt cut on a synthesized clip clicks; 80 ms of fade is inaudible and fixes it.
  fade_at="$(python3 -c "print(max(0.0, round($secs - 0.08, 3)))")"
  ffmpeg -y -loglevel error -i "$in" -t "$secs" \
    -af "volume=${gain}dB,afade=t=out:st=$fade_at:d=0.08" \
    -c:a libmp3lame -b:a 128k "$out"
  vlog "normalized $(basename "$out"): peak ${peak}dB ${gain:+${gain}dB gain}"
}

# ── providers ─────────────────────────────────────────────────────────────────────
_gen_elevenlabs() {   # PROMPT SECONDS OUT_RAW
  local prompt="$1" secs="$2" out="$3" key code msg
  key="$(voice_need_key ELEVENLABS_API_KEY)"
  code="$(jq -nc --arg t "$prompt" --argjson d "$secs" \
            '{text: $t, duration_seconds: $d, prompt_influence: 0.4}' \
          | curl -sS --max-time 180 -o "$out" -w '%{http_code}' -X POST \
              "https://api.elevenlabs.io/v1/sound-generation" \
              -H "xi-api-key: $key" -H "Content-Type: application/json" --data-binary @-)"
  if [[ "$code" != 2* ]]; then
    msg="$(head -c 200 "$out" 2>/dev/null | tr -d '\n')"; rm -f "$out"
    vdie "elevenlabs sound-generation: HTTP $code — $msg"
  fi
}

_gen_system() {   # SOUND_NAME OUT_RAW
  local src="/System/Library/Sounds/$1.aiff" out="$2"
  [[ -f "$src" ]] || vdie "no system sound named $1 (looked in /System/Library/Sounds)"
  ffmpeg -y -loglevel error -i "$src" -c:a libmp3lame -b:a 128k "$out"
}

# ── commands ──────────────────────────────────────────────────────────────────────
cmd_generate() {
  local force=0 wanted=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      -*) vdie "generate: unknown option $1" ;;
      *) wanted+=("$1"); shift ;;
    esac
  done
  [[ "${#wanted[@]}" -gt 0 ]] || while IFS= read -r n; do wanted+=("$n"); done < <(_names)

  voice_require ffmpeg jq curl python3
  voice_mkdirs
  voice_load_credentials
  local provider; provider="$(voice_cfg voice.sfx.provider elevenlabs)"
  case "$provider" in elevenlabs|system) ;; *) vdie "unknown voice.sfx.provider '$provider' — use elevenlabs|system" ;; esac

  local name row secs prompt sysname out raw made=0 kept=0
  for name in "${wanted[@]}"; do
    row="$(_entry "$name")" || vdie "no cue named '$name' — one of: $(_names | tr '\n' ' ')"
    IFS='|' read -r _ secs prompt sysname <<< "$row"
    out="$VOICE_CUE_DIR/$name.mp3"
    if [[ -s "$out" && "$force" -ne 1 ]]; then
      vlog "keep $name (already generated; --force to rebuild)"
      kept=$((kept + 1)); continue
    fi
    raw="$out.raw.$$.mp3"
    case "$provider" in
      elevenlabs) vlog "generate $name via elevenlabs (${secs}s)"; _gen_elevenlabs "$prompt" "$secs" "$raw" ;;
      system)     vlog "generate $name from the system sound $sysname"; _gen_system "$sysname" "$raw" ;;
    esac
    _normalize "$raw" "$out.tmp.$$.mp3" "$secs"
    rm -f "$raw"; mv "$out.tmp.$$.mp3" "$out"
    made=$((made + 1))
  done
  vlog "catalog: $made generated, $kept kept, in $VOICE_CUE_DIR"
  [[ "$made" -gt 0 || "$kept" -gt 0 ]] || vdie "nothing generated"
}

cmd_list() {
  voice_require ffprobe
  printf '%-11s %-6s %-9s %s\n' CUE SECS PEAK FILE
  local n f dur peak
  while IFS= read -r n; do
    f="$VOICE_CUE_DIR/$n.mp3"
    if [[ -s "$f" ]]; then
      dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | cut -c1-4)"
      peak="$(ffmpeg -hide_banner -i "$f" -af volumedetect -f null - 2>&1 \
              | sed -nE 's/.*max_volume: (-?[0-9.]+) dB.*/\1/p' | head -1)"
      printf '%-11s %-6s %-9s %s\n' "$n" "$dur" "${peak}dB" "$f"
    else
      printf '%-11s %-6s %-9s %s\n' "$n" '-' '-' '(not generated)'
    fi
  done < <(_names)
}

cmd_play() {
  local n="${1:?usage: sfx.sh play NAME}" f="$VOICE_CUE_DIR/$1.mp3"
  _entry "$n" >/dev/null || vdie "no cue named '$n' — one of: $(_names | tr '\n' ' ')"
  [[ -s "$f" ]] || vdie "cue '$n' is not generated yet — run: sfx.sh generate $n"
  # A cue is OUTPUT, so mute covers it — by hand or by the OS. It says so out loud rather than
  # doing nothing: you asked to hear a sound, and silence with no reason reads as a broken cue
  # file. `generate` above is deliberately NOT gated — that is a setup step you ran on purpose,
  # and its output is a file, not a sound.
  if voice_is_muted; then
    printf 'muted (%s) — not playing %s\n' "$(voice_mute_reason)" "$n" >&2
    return 0
  fi
  afplay "$f"
}

if [[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]]; then export VOICE_VERBOSE=1; shift; fi
case "${1:-}" in
  generate) shift; voice_gate_or_exit "sfx generate"; cmd_generate "$@" ;;
  list)     cmd_list ;;
  play)     shift; cmd_play "$@" ;;
  -h|--help|"") sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d' ;;
  *) vdie "unknown command '$1' (see -h)" ;;
esac
