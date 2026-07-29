#!/usr/bin/env bash
#
# Speak a line of Thai. The one entry point every other piece of the voice feature goes
# through: hooks, milestones, the Slack notifier and the CLI all call this.
#
# Usage:
#   speak.sh [-v] [options] "ข้อความ"
#
#   --provider NAME              audition another TTS provider without editing config
#   --voice ID                   audition another voice on that provider
#   --kind ack|milestone|manual  queue priority (default: manual — never dropped)
#   --cue NAME                   mix a cue from the catalog under/around the line
#   --mix under|sting|duck|tail  how the cue sits against the voice (default: under)
#   --cue-volume N               cue level for `under`/`tail` (default 0.22; 0.15 for bad news)
#   --mood TEXT                  style hint passed to the provider ("cheerfully", "urgently")
#   --no-prefix                  do not attach this worktree's identity prefix
#   --out FILE                   also copy the finished audio to FILE (for a Slack upload)
#   --print-path                 print the cached audio path on stdout
#   --no-play                    synthesize and cache only; queue nothing
#   --sync                       play in the foreground (blocks); for tests and the CLI
#   --dry-run                    resolve + report, call no API, write nothing
#
# EVERYTHING IS CONTENT-ADDRESSED. The cache key is provider|voice|model|cue|mix|normalized
# text and the cached file is the FINISHED (already mixed) audio, so the second time a
# sentence is needed — the next ticket's identical Slack line, a repeated milestone, the same
# identity prefix — it costs nothing and plays instantly. The cache is machine-global, so
# worktrees share it: running five at once makes speech cheaper per utterance, not dearer.
#
# It never blocks the caller: synthesis happens here (that is the unavoidable network step),
# but playback is handed to queue.sh and drained in a detached process unless --sync.

set -euo pipefail
# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

KIND=manual CUE="" MIX=under CUE_VOL=0.22 MOOD="" WANT_PREFIX=1
OUT_COPY="" PRINT_PATH=0 NO_PLAY=0 SYNC=0 DRY=0 TEXT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) export VOICE_VERBOSE=1; shift ;;
    --provider)   export VOICE_TTS_PROVIDER_FORCE="${2:?}"; shift 2 ;;
    --voice)      export VOICE_TTS_VOICE_FORCE="${2:?}"; shift 2 ;;
    --kind)       KIND="${2:?}"; shift 2 ;;
    --cue)        CUE="${2:?}"; shift 2 ;;
    --mix)        MIX="${2:?}"; shift 2 ;;
    --cue-volume) CUE_VOL="${2:?}"; shift 2 ;;
    # `${2-}`, not `${2:?}`: an EMPTY mood is legitimate (variety_mood returns nothing for a
    # generic request) and `${2:?}` treats empty as unset, so `--mood ""` aborted the script.
    # That killed every generic-intent ack, silently, because the hook discards stderr.
    --mood)       MOOD="${2-}"; shift 2 ;;
    --no-prefix)  WANT_PREFIX=0; shift ;;
    --out)        OUT_COPY="${2:?}"; shift 2 ;;
    --print-path) PRINT_PATH=1; shift ;;
    --no-play)    NO_PLAY=1; shift ;;
    --sync)       SYNC=1; shift ;;
    --dry-run)    DRY=1; shift ;;
    -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; exit 0 ;;
    -*)           vdie "unknown option $1 (see -h)" ;;
    *)            TEXT="${TEXT:+$TEXT }$1"; shift ;;
  esac
done

[[ -n "$TEXT" ]] || vdie "nothing to say — pass the text as an argument"
case "$KIND" in ack|milestone|manual) ;; *) vdie "--kind must be ack|milestone|manual" ;; esac
case "$MIX" in under|sting|duck|tail) ;; *) vdie "--mix must be under|sting|duck|tail" ;; esac

voice_gate_or_exit "speak"

# Muted ⇒ stop before the synthesis call, not after: everything this machine was going to SAY is
# off, and off means it costs nothing rather than rendering audio into muted speakers.
#
# TWO EXEMPTIONS, both because nothing was going to be played HERE anyway:
#   --no-play / --out FILE   renders a file for SOMEWHERE ELSE — the Slack voice note. Mute is
#                            about this machine's speakers; whether the team's channel gets audio
#                            is `voice.notify_voice.enabled`, a standing decision in workspace
#                            config, and a muted laptop is not a reason to send the team less.
#   --dry-run                the diagnostic: calls no API, writes nothing, so there is no spend to
#                            save — and going quiet here would hide the report you ran it for. It
#                            prints the mute state instead.
if voice_is_muted && [[ "$NO_PLAY" -eq 0 && "$DRY" -eq 0 ]]; then
  vlog "speak skipped: muted — nothing summarized, synthesized or played (--no-play still renders)"
  exit 0
fi

voice_require jq curl shasum
voice_mkdirs
voice_load_credentials
voice_load_tts_provider

# What gets SAID, not what was written: ticket ids digit by digit, MR/PR expanded, branch
# separators dropped (see voice_spoken_form in lib.sh). Done BEFORE the cache key so the key
# addresses the audio's real content — two callers who write "OFB-1598" and "feature/OFB-1598"
# then share one file.
WRITTEN="$TEXT"
TEXT="$(voice_spoken_form "$TEXT")"
[[ "$TEXT" == "$WRITTEN" ]] || vlog "spoken form: $TEXT"

VOICE_MOOD="$MOOD"; export VOICE_MOOD    # providers read this; empty means "no style hint"

read -r P_NAME P_VOICE P_MODEL <<< "$(voice_tts_describe)"
CUE_FILE=""
if [[ -n "$CUE" ]]; then
  CUE_FILE="$VOICE_CUE_DIR/$CUE.mp3"
  if [[ ! -s "$CUE_FILE" ]]; then
    # Not fatal: a missing cue must degrade to a plain spoken line, never to silence. The
    # catalog is generated by sfx.sh, and a cue that was never generated is a setup gap.
    vlog "cue '$CUE' not in the catalog ($CUE_FILE) — speaking without it"
    CUE_FILE=""; CUE=""
  fi
fi

KEY="$(voice_cache_key "$TEXT" "$P_NAME" "$P_VOICE" "$P_MODEL" "$CUE" "${CUE:+$MIX:$CUE_VOL}")"
AUDIO="$VOICE_AUDIO_DIR/$KEY.mp3"

# ── the four cue-mix patterns (local ffmpeg, no API, no cost) ──────────────────────
# amix normalises its inputs, so `volume` is what actually sets the bed level.
_mix_audio() {   # VOICE_FILE CUE_FILE OUT_FILE
  local v="$1" c="$2" o="$3" dur tail_ms
  case "$MIX" in
    under)   # cue sits under the whole line, nudged 200 ms in
      ffmpeg -y -loglevel error -i "$v" -i "$c" -filter_complex \
        "[1]volume=$CUE_VOL,adelay=200|200[x];[0][x]amix=inputs=2:duration=first:dropout_transition=0" "$o" ;;
    sting)   # cue alone first, voice in at 900 ms, cue fades out underneath
      ffmpeg -y -loglevel error -i "$v" -i "$c" -filter_complex \
        "[0]adelay=900|900[a];[1]volume=0.5,afade=t=out:st=1.2:d=1.8[x];[a][x]amix=inputs=2:duration=longest" "$o" ;;
    duck)    # real ducking: the VOICE is the sidechain trigger, so the cue swells in the gaps
      ffmpeg -y -loglevel error -i "$v" -i "$c" -filter_complex \
        "[1]volume=0.9,apad[m];[0]asplit=2[a][k];[m][k]sidechaincompress=threshold=0.02:ratio=8:attack=5:release=250[d];[a][d]amix=inputs=2:duration=first" "$o" ;;
    tail)    # cue arrives as the sentence lands
      dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$v")"
      tail_ms="$(python3 -c "import sys; print(max(0, int((float(sys.argv[1]) - 1.2) * 1000)))" "$dur")"
      ffmpeg -y -loglevel error -i "$v" -i "$c" -filter_complex \
        "[1]volume=$CUE_VOL,adelay=$tail_ms|$tail_ms[x];[0][x]amix=inputs=2:duration=longest" "$o" ;;
  esac
}

if [[ "$DRY" -eq 1 ]]; then
  printf 'provider   %s / %s / %s (gender %s)\n' "$P_NAME" "$P_VOICE" "$P_MODEL" "$(voice_tts_gender)"
  [[ "$TEXT" == "$WRITTEN" ]] || printf 'written    %s\n' "$WRITTEN"
  printf 'text       %s\n' "$TEXT"
  printf 'cue        %s\n' "${CUE:-none}${CUE:+ ($MIX @ $CUE_VOL)}"
  printf 'kind       %s\n' "$KIND"
  voice_is_muted && printf 'mute       ON — a real call would stop here (unless --no-play)\n'
  printf 'cache      %s (%s)\n' "$AUDIO" "$([[ -s "$AUDIO" ]] && echo hit || echo miss)"
  if [[ "$WANT_PREFIX" -eq 1 ]]; then
    if voice_is_focused; then
      printf 'prefix     (suppressed — this worktree is the one you are prompting in)\n'
    else
      printf 'prefix     %s\n' "$(voice_spoken_form "$("$VOICE_DIR/identity.sh" text)")"
    fi
  fi
  exit 0
fi

# ── synthesize (only on a cache miss) ─────────────────────────────────────────────
if [[ -s "$AUDIO" ]]; then
  vlog "cache hit: $AUDIO"
else
  vlog "synth ($P_NAME/$P_VOICE${MOOD:+, mood: $MOOD}): $TEXT"
  # The .mp3 suffix on the temporaries is load-bearing, not tidiness: ffmpeg picks the OUTPUT
  # muxer from the file extension, and a name ending in `.mix.12345` fails with "Unable to
  # choose an output format" — which cost a mix on the first run of this code.
  RAW="$AUDIO.raw.$$.mp3"
  voice_tts_synth "$TEXT" "$RAW"
  # Loudness BEFORE the mix, not after: the cue's bed gain is a fixed number, so it can only
  # mean the same thing on every provider if the voice under it is already at one level.
  NORM="$AUDIO.norm.$$.mp3"
  if voice_loudnorm "$RAW" "$NORM"; then mv "$NORM" "$RAW"; else rm -f "$NORM"; fi
  if [[ -n "$CUE_FILE" ]]; then
    voice_require ffmpeg ffprobe
    vlog "mix: $CUE ($MIX @ $CUE_VOL)"
    MIXED="$AUDIO.mix.$$.mp3"
    if _mix_audio "$RAW" "$CUE_FILE" "$MIXED"; then
      rm -f "$RAW"; mv "$MIXED" "$AUDIO"
    else
      # A broken filter graph must cost the cue, never the sentence we already paid for — and
      # it must NOT be cached under the cue's key, or the mix would never be retried for this
      # line again. Park it under the no-cue key instead, which is honestly what it is.
      rm -f "$MIXED"
      AUDIO="$VOICE_AUDIO_DIR/$(voice_cache_key "$TEXT" "$P_NAME" "$P_VOICE" "$P_MODEL" "" "").mp3"
      vlog "mix failed — speaking unmixed, cached under the no-cue key so the mix retries"
      mv "$RAW" "$AUDIO"
    fi
  else
    mv "$RAW" "$AUDIO"    # atomic: a concurrent reader never sees a partial file
  fi
fi

[[ -n "$OUT_COPY" ]] && { cp "$AUDIO" "$OUT_COPY"; vlog "copied to $OUT_COPY"; }
[[ "$PRINT_PATH" -eq 1 ]] && printf '%s\n' "$AUDIO"

if [[ "$NO_PLAY" -eq 1 ]]; then
  vlog "--no-play: cached only, nothing queued"
  exit 0
fi

# ── queue + play ──────────────────────────────────────────────────────────────────
PREFIX=""
# THE SESSION YOU ARE PROMPTING IN NEVER INTRODUCES ITSELF. You know which worktree you just
# typed in; "OFB หนึ่ง ห้า เก้า แปด" in front of every sentence there is pure noise. The prefix
# earns its keep only when a worktree you are NOT in speaks up — a background dev-cycle, a
# slack-dispatch job, the other window. Decided here rather than at drain time so a suppressed
# prefix also skips its synthesis call.
if [[ "$WANT_PREFIX" -eq 1 ]] && voice_is_focused; then
  vlog "prefix: suppressed — this worktree is the one being prompted in"
  WANT_PREFIX=0
fi
if [[ "$WANT_PREFIX" -eq 1 ]]; then
  # A failure here (unreachable tracker, TTS hiccup) must cost the prefix, not the sentence —
  # but under -v the whole point is to see the failure, so stderr survives there.
  if [[ "$VOICE_VERBOSE" == "1" ]]; then
    PREFIX="$("$VOICE_DIR/identity.sh" audio | tail -1)" || PREFIX=""
  else
    PREFIX="$("$VOICE_DIR/identity.sh" audio 2>/dev/null | tail -1)" || PREFIX=""
  fi
  [[ -f "$PREFIX" ]] || PREFIX=""
fi

"$VOICE_DIR/queue.sh" enqueue --kind "$KIND" --audio "$AUDIO" ${PREFIX:+--prefix "$PREFIX"} --text "$TEXT"
if [[ "$SYNC" -eq 1 ]]; then
  "$VOICE_DIR/queue.sh" drain
else
  "$VOICE_DIR/queue.sh" drain --background
fi
