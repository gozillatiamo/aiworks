#!/usr/bin/env bash
#
# Push-to-talk — hold a key, speak, release, and what you said becomes the prompt.
#
# Usage:
#   ptt.sh start              begin recording (idempotent — a key repeat must not start two)
#   ptt.sh stop               stop, transcribe, PRINT the text on stdout
#   ptt.sh cancel             stop and throw the recording away
#   ptt.sh preview            print the current interim transcript (for the HUD)
#   ptt.sh status             recording? for how long? which microphone?
#   ptt.sh policy             print "autosend=0|1 preview=<provider|none>" for the key handler
#
# This half owns the MICROPHONE and the TRANSCRIPT. It never types: injection is the key
# handler's job (~/.hammerspoon/voice-ptt.lua), because deciding whether the frontmost window is
# your session — and pressing Enter — needs to see the window list, which a shell cannot.
#
# ── THE MICROPHONE IS RESOLVED BY NAME, NOT BY INDEX ───────────────────────────────
# avfoundation's device numbering is whatever is plugged in at the time. On this machine `:0`
# was the MacBook mic when the feature was planned and an Arctis headset by the time it was
# built — a hardcoded index silently records from the wrong input, and you only find out from a
# transcript full of nothing. So `voice.push_to_talk.mic` matches a device NAME (substring, case
# insensitive), and the resolved name is logged every time.
#
# ── THE PREVIEW IS CHUNKED, NOT STREAMED ───────────────────────────────────────────
# While you hold the key, the growing recording is re-transcribed every ~1.5 s with the CHEAP
# model and written to a file the HUD polls. No websocket, no realtime session, no unpublished
# per-minute price (the plan flagged `gpt-realtime-whisper` as unpriced — risk #3). The cost of
# a 10 s utterance is about six extra $0.003/min calls, i.e. fractions of a cent, and the text
# that actually gets INJECTED is always the final full-file pass through the accurate model.
# `preview.provider: none` turns the loop off — and then `auto_send` is forced to false, because
# pressing Enter on words you were never shown is not a feature.
#
# ── THE RECORDING IS DELETED THE MOMENT THE TRANSCRIPT EXISTS ──────────────────────
# Audio, wav, both preview snapshots and the interim text, on every path — success, silence,
# transcriber failure, cancel — and again at the start of the next hold. See _wipe_audio.
#
# ── MUTE DOES NOT STOP DICTATION ───────────────────────────────────────────────────
# It is INPUT, it runs only while you hold the key, and there is no background spend to save.
# `aiworks voice mute on` silences the two cues and nothing else here.

set -euo pipefail
VOICE_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$VOICE_SELF_DIR/lib.sh"

PTT_DIR="$VOICE_CACHE_HOME/ptt"
# RAW PCM while recording, wav only when handing audio to a transcriber.
#
# WHY: a wav is NOT streamable. ffmpeg writes its header last and buffers the audio, so a
# `rec.wav` being recorded into sits at ZERO BYTES until the process exits — measured, and it is
# why the live preview showed nothing at all: there was never anything to snapshot. Raw PCM has
# no header and no length field, so any prefix of the file is already valid audio; wrapping a
# copied prefix with `-f s16le -ar 16000 -ac 1` costs milliseconds and is always correct.
REC_RAW="$PTT_DIR/rec.pcm"
REC_WAV="$PTT_DIR/rec.wav"
RATE=16000            # what every STT engine wants, and a quarter the bytes of 44.1 kHz stereo
REC_PID="$PTT_DIR/rec.pid"
REC_STARTED="$PTT_DIR/started"
PREVIEW_TXT="$PTT_DIR/preview.txt"
PREVIEW_PID="$PTT_DIR/preview.pid"
# The preview's working files. Named up here, not inside the loop, because _wipe_audio has to be
# able to remove them from a DIFFERENT process — the loop is killed by `stop`, so its own cleanup
# cannot be the only one.
SNAP_RAW="$PTT_DIR/snap.pcm"
SNAP_WAV="$PTT_DIR/snap.wav"
MAX_SECONDS=120        # a stuck key must not fill the disk

# ── NOTHING YOU SAID SURVIVES THE TURN ─────────────────────────────────────────────
# Once the transcript has been handed over, the recording has served its entire purpose. Keeping
# it around is a recording of you sitting in a cache directory for no reason, and there are four
# files, not one: the raw capture, the wav wrapped for the transcriber, and the preview loop's two
# snapshots (a rolling 12 s of audio) — plus preview.txt, which holds the words themselves.
#
# Called on stop, on cancel and again at the start of the next hold, so a crash mid-flight cannot
# leave audio behind for longer than until the next time you speak.
_wipe_audio() {
  rm -f "$REC_RAW" "$REC_WAV" "$SNAP_RAW" "$SNAP_WAV" "$PREVIEW_TXT" "$REC_STARTED"
}

_gate() {
  voice_gate_or_exit "ptt"
  voice_cfg_bool voice.push_to_talk.enabled false || { vlog "ptt: voice.push_to_talk.enabled is false"; exit 0; }
}

# ── the microphone ────────────────────────────────────────────────────────────────
# The device macOS itself is set to record from — System Settings → Sound → Input. This is what
# `mic: default` follows, and it is the right default: you change your input device in one place
# (or by plugging in a headset) and dictation follows, instead of recording from a microphone
# you are not talking into. Measured at ~0.1 s, so it is affordable on every hold.
_default_input_name() {
  system_profiler SPAudioDataType -json 2>/dev/null | python3 -c '
import json, sys
def walk(items):
    for it in items:
        if it.get("coreaudio_default_audio_input_device") and it.get("_name"):
            print(it["_name"]); return True
        for v in it.values():
            if isinstance(v, list) and walk(v): return True
    return False
try: walk(json.load(sys.stdin).get("SPAudioDataType", []))
except Exception: pass
' 2>/dev/null
}

# Echoes "<index>|<name>". ffmpeg prints the device list on STDERR and exits non-zero by
# design (there is no input file), hence the `|| true`.
#
# ⚠ NEVER trust an avfoundation INDEX from config: the numbering is whatever is plugged in at
#   the time. Index 0 was the built-in mic when this was planned and a headset by the time it was
#   built. Everything here resolves by NAME.
_mic() {
  local want list line idx name src
  want="$(voice_cfg voice.push_to_talk.mic default)"
  case "$want" in
    ""|default|system)
      want="$(_default_input_name)"
      src="system default input"
      [[ -n "$want" ]] || vlog "ptt: could not read the system default input device"
      ;;
    *) src="voice.push_to_talk.mic" ;;
  esac

  list="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true)"
  list="$(printf '%s' "$list" | sed -n '/AVFoundation audio devices/,$p')"
  if [[ -n "$want" ]]; then
    while IFS= read -r line; do
      idx="$(printf '%s' "$line" | sed -nE 's/.*\[([0-9]+)\] .*/\1/p')"
      name="$(printf '%s' "$line" | sed -nE 's/.*\[[0-9]+\] (.*)$/\1/p')"
      [[ -n "$idx" && -n "$name" ]] || continue
      # -F: a device name is a literal, not a regex — "Arctis Nova Pro (Wireless)" would
      # otherwise be interpreted as a group and match nothing.
      if printf '%s' "$name" | grep -Fqi -- "$want"; then
        vlog "ptt: mic '$name' [$idx] (from $src)"
        printf '%s|%s' "$idx" "$name"
        return 0
      fi
    done <<< "$list"
    vlog "ptt: no audio device matching '$want' ($src) — falling back to device 0"
  fi
  name="$(printf '%s' "$list" | sed -nE 's/.*\[0\] (.*)$/\1/p' | head -1)"
  printf '0|%s' "${name:-unknown}"
}

_recording() { [[ -f "$REC_PID" ]] && kill -0 "$(cat "$REC_PID" 2>/dev/null || printf 0)" 2>/dev/null; }

# Is this recording just room noise?
#
# WHY THIS EXISTS, and why it is not an optimization: handed silence, `gpt-4o-transcribe`
# ECHOES ITS OWN PROMPT BACK as the transcript. Measured — a 7 s hold with nothing said
# returned the entire domain hint ("APP, your-app, shared-lib, …"), which would have been
# typed into the session and sent. So a hold with no speech should never reach the API.
#
# ⚠ THE THRESHOLDS NEED CALIBRATING TO YOUR VOICE AND ROOM. Two silent recordings on this
#   machine measured 17 dB apart (mean −59 dB and mean −42.5 dB — fan and keyboard), and the
#   loud one sailed past a −50 dB floor and came back with a hallucinated word. So this test is
#   deliberately CONSERVATIVE: it discards only when the recording is quiet by BOTH measures.
#   Losing a real utterance is worse than one wasted call, and listen.sh's echo guard is the
#   backstop that catches the dangerous failure. Run `aiworks voice mic-check` and put your own
#   numbers in voice.push_to_talk.{silence_db,silence_peak_db}.
_is_silent() {   # FILE → 0 when there is nothing worth transcribing
  local mean peak floor peak_floor dur
  floor="$(voice_cfg voice.push_to_talk.silence_db -50)"
  peak_floor="$(voice_cfg voice.push_to_talk.silence_peak_db -35)"

  # A tap on the key rather than a hold: too short to contain a word either way.
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null || printf 0)"
  if python3 -c "import sys; sys.exit(0 if float('${dur:-0}') < 0.6 else 1)"; then
    vlog "ptt: ${dur}s — too short to be speech"
    return 0
  fi

  local vd; vd="$(ffmpeg -hide_banner -i "$1" -af volumedetect -f null - 2>&1)"
  mean="$(printf '%s' "$vd" | sed -nE 's/.*mean_volume: (-?[0-9.]+) dB.*/\1/p' | head -1)"
  peak="$(printf '%s' "$vd" | sed -nE 's/.*max_volume: (-?[0-9.]+) dB.*/\1/p' | head -1)"
  [[ -n "$mean" && -n "$peak" ]] || return 1   # cannot tell ⇒ assume speech
  vlog "ptt: mean ${mean}dB peak ${peak}dB (floors ${floor}/${peak_floor})"
  python3 -c "import sys
mean, peak = float('$mean'), float('$peak')
sys.exit(0 if (mean < float('$floor') and peak < float('$peak_floor')) else 1)"
}

# Muted means silent, and that includes the two dictation cues — a beep during a call is exactly
# the noise the switch exists to stop. Nothing is lost: the HUD's level meter is the real "it is
# hearing you" signal, and it is visual.
_cue() {
  local c="$VOICE_CUE_DIR/$1.mp3"
  voice_is_muted && return 0
  [[ -s "$c" ]] && ( afplay "$c" >/dev/null 2>&1 & ) 2>/dev/null
  return 0
}

# ── the chunked preview loop ──────────────────────────────────────────────────────
# Remuxing the snapshot is not optional: a wav still being written has a placeholder length in
# its header, and an STT endpoint handed that either errors or transcribes silence.
_preview_loop() {
  local snap="$SNAP_RAW" wav="$SNAP_WAV" prov txt min_bytes
  prov="$(voice_cfg voice.push_to_talk.preview.provider none)"
  [[ "$prov" != "none" ]] || return 0
  # This loop is KILLED by `stop`, so the tidy-up after the while cannot be relied on — a SIGTERM
  # would leave the last 12 s of audio on disk. The trap covers the kill; _wipe_audio covers the
  # trap not running either.
  trap 'rm -f "$snap" "$wav"' EXIT INT TERM
  : > "$PREVIEW_TXT"
  # Below ~0.5 s there is no word to recognise yet, and an STT call on a fragment tends to come
  # back as an invention. 2 bytes per sample, mono.
  min_bytes=$(( RATE * 2 / 2 ))
  local window_secs window_bytes
  window_secs="$(voice_cfg voice.push_to_talk.preview.window_seconds 12)"
  [[ "$window_secs" =~ ^[0-9]+$ ]] || window_secs=12
  window_bytes=$(( RATE * 2 * window_secs ))

  # ── PACED BY THE WORK, NOT BY A SLEEP ──────────────────────────────────────────
  # The first version slept 1.5 s and THEN spent 1.0–1.9 s transcribing (measured: 0.98 s for a
  # 2 s prefix, 1.60 s at 5 s, 1.86 s at 10 s) — so the HUD ran 2.5–3.4 s behind what had been
  # said. Now the only pause is a short one to keep from hammering the API when a response comes
  # back instantly, which roughly halves the visible lag. The extra calls are nearly free: a 10 s
  # prefix through the cheap model is about $0.0005, so a long utterance costs fractions of a cent.
  while _recording; do
    sleep 0.2
    _recording || break
    # A prefix of raw PCM is valid audio by construction — this is the whole reason recording is
    # raw rather than wav.
    # Only the LAST few seconds. Re-uploading the whole prefix made the lag GROW with the
    # utterance (measured 0.98 s at 2 s of audio, 1.86 s at 10 s), so a long dictation would drift
    # further and further behind. A trailing window keeps the update rate flat, and the tail is
    # the part you are watching anyway — the text that actually gets typed is always the accurate
    # pass over the COMPLETE recording, so nothing is lost by not previewing the beginning.
    # tail -c on raw PCM is safe at any even offset: it is fixed-size frames, no header.
    tail -c "$window_bytes" "$REC_RAW" > "$snap" 2>/dev/null || continue
    [[ -s "$snap" ]] || continue
    [[ "$(stat -f%z "$snap" 2>/dev/null || printf 0)" -ge "$min_bytes" ]] || continue
    ffmpeg -y -loglevel error -f s16le -ar "$RATE" -ac 1 -i "$snap" "$wav" 2>/dev/null || continue
    txt="$("$VOICE_SELF_DIR/listen.sh" --provider "$prov" --fast "$wav" 2>/dev/null || true)"
    # Only overwrite on a hit: a failed or discarded pass must not blank a preview the user is
    # reading, which looks like the recording stopped.
    [[ -n "$txt" ]] && printf '%s' "$txt" > "$PREVIEW_TXT"
  done
  rm -f "$snap" "$wav"
}

# ── commands ──────────────────────────────────────────────────────────────────────
cmd_start() {
  _gate
  voice_require ffmpeg
  mkdir -p "$PTT_DIR"
  if _recording; then vlog "ptt: already recording — ignoring"; exit 0; fi

  local mic idx name
  mic="$(_mic)"; idx="${mic%%|*}"; name="${mic##*|}"
  vlog "ptt: recording from [$idx] $name"

  _wipe_audio      # also the safety net for a previous hold that was killed mid-flight
  # -f s16le + -flush_packets 1: raw, and on disk as it arrives, so the preview has something to
  # read while the hold is still in progress.
  nohup ffmpeg -hide_banner -loglevel error -f avfoundation -i ":$idx" \
        -t "$MAX_SECONDS" -ac 1 -ar "$RATE" -f s16le -flush_packets 1 -y "$REC_RAW" >/dev/null 2>&1 &
  printf '%s' "$!" > "$REC_PID"
  voice_now > "$REC_STARTED"

  # ── THE CUE IS THE "SPEAK NOW" SIGNAL, so it must not fire before capture is live ───
  # avfoundation takes 0.23–0.25 s to open the device (measured, twice). Playing the cue at spawn
  # time told the user to start talking a quarter-second before anything was being recorded, and
  # the first word was lost EVERY time — the "some text missing" report. Waiting for the first
  # bytes to land makes the cue mean what the user thinks it means.
  local waited=0
  while [[ ! -s "$REC_RAW" ]] && [[ "$waited" -lt 40 ]]; do
    sleep 0.025; waited=$((waited + 1))
    _recording || break        # ffmpeg died (device busy, no permission) — do not spin
  done
  _cue ptt_start
  vlog "ptt: capture live after $(python3 -c "print(f'{$waited * 0.025:.2f}')")s — cue now"
  # Re-invoke ourselves rather than exporting shell functions into `bash -c`: a `declare -f`
  # payload silently loses anything the function depends on (here: all of lib.sh).
  ( nohup "$VOICE_SELF_DIR/ptt.sh" _preview >/dev/null 2>&1 ) &
  printf '%s' "$!" > "$PREVIEW_PID"
}

_halt_recording() {
  local pid
  [[ -f "$REC_PID" ]] || return 0
  pid="$(cat "$REC_PID" 2>/dev/null || printf 0)"
  # SIGINT, never SIGKILL: ffmpeg needs to write the real length into the wav header, and a
  # killed recording is a file no transcriber will read.
  if [[ "$pid" -gt 0 ]] 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
    kill -INT "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  fi
  rm -f "$REC_PID"
  if [[ -f "$PREVIEW_PID" ]]; then kill "$(cat "$PREVIEW_PID")" 2>/dev/null || true; rm -f "$PREVIEW_PID"; fi
}

cmd_stop() {
  _gate
  local secs=0
  [[ -f "$REC_STARTED" ]] && secs=$(( $(voice_now) - $(cat "$REC_STARTED") ))
  _halt_recording
  _cue ptt_stop
  # EVERY exit from here wipes the audio, including the failure paths: "the transcriber was down"
  # is not a reason to keep a recording of the user on disk. The trap is what makes that true for
  # the `exit 1`s below as well as the happy path.
  trap _wipe_audio EXIT
  if [[ ! -s "$REC_RAW" ]]; then vlog "ptt: nothing recorded"; exit 1; fi
  # Wrap the raw capture for the transcriber, which wants a container.
  if ! ffmpeg -y -loglevel error -f s16le -ar "$RATE" -ac 1 -i "$REC_RAW" "$REC_WAV" 2>/dev/null; then
    vlog "ptt: could not wrap the raw capture"
    exit 1
  fi
  rm -f "$REC_RAW"
  if _is_silent "$REC_WAV"; then
    vlog "ptt: no speech in ${secs}s — not transcribing (the model would echo its prompt back)"
    exit 1
  fi
  vlog "ptt: ${secs}s recorded, transcribing with the accurate model"
  local text
  text="$("$VOICE_SELF_DIR/listen.sh" "$REC_WAV" 2>/dev/null || true)"
  # The moment the transcript is in hand the recording has done its job — before it is even
  # printed, so nothing downstream can fail in a way that leaves the audio behind.
  _wipe_audio
  vlog "ptt: recording wiped ($PTT_DIR is empty of audio)"
  [[ -n "$text" ]] || { vlog "ptt: no transcript"; exit 1; }
  printf '%s\n' "$text"
}

cmd_cancel() {
  _gate
  _halt_recording
  _wipe_audio
  vlog "ptt: cancelled — recording wiped"
}

cmd_preview() { [[ -f "$PREVIEW_TXT" ]] && cat "$PREVIEW_TXT" || true; }

cmd_status() {
  local mic
  if _recording; then
    printf 'recording  yes, %ss\n' "$(( $(voice_now) - $(cat "$REC_STARTED" 2>/dev/null || voice_now) ))"
  else
    printf 'recording  no\n'
  fi
  mic="$(_mic 2>/dev/null || printf '?|?')"
  local want; want="$(voice_cfg voice.push_to_talk.mic default)"
  case "$want" in
    ""|default|system) printf 'microphone [%s] %s  (following the system default input)\n' "${mic%%|*}" "${mic##*|}" ;;
    *)                 printf 'microphone [%s] %s  (pinned: %s)\n' "${mic%%|*}" "${mic##*|}" "$want" ;;
  esac
  printf 'stt        %s\n' "$(voice_cfg voice.stt.provider openai)"
  printf 'preview    %s\n' "$(voice_cfg voice.push_to_talk.preview.provider none)"
  printf 'hotkey     %s\n' "$(voice_cfg voice.push_to_talk.hotkey fn+right_cmd)"
  cmd_policy
}

# The resolved policy, for the key handler — so the Lua never parses YAML, and the "no preview
# ⇒ no auto-Enter" coupling is decided in ONE place instead of two.
cmd_policy() {
  local prev auto
  prev="$(voice_cfg voice.push_to_talk.preview.provider none)"
  if voice_cfg_bool voice.push_to_talk.auto_send true; then auto=1; else auto=0; fi
  [[ "$prev" == "none" ]] && auto=0
  printf 'autosend=%s preview=%s\n' "$auto" "$prev"
}

if [[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]]; then export VOICE_VERBOSE=1; shift; fi
case "${1:-}" in
  start)    cmd_start ;;
  _preview) _preview_loop ;;   # internal: the chunked-preview watcher, spawned by `start`
  stop)    cmd_stop ;;
  cancel)  cmd_cancel ;;
  preview) cmd_preview ;;
  status)  cmd_status ;;
  policy)  cmd_policy ;;
  -h|--help|"") sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d' ;;
  *) vdie "unknown command '$1' (see -h)" ;;
esac
