#!/usr/bin/env bash
#
# Post a chat notification WITH a voice note attached — one message carrying both the text and
# the audio. A drop-in front for scripts/notify/send.sh: when voice is off (or the language is
# not `th`), it forwards the arguments verbatim and you get exactly the message send.sh would
# have sent.
#
# Usage:
#   notify-voice.sh --review OFB-1952 [--channel CH] [--spoken TEXT] [--dry-run]
#   notify-voice.sh [--channel CH] [--thread-ts TS] [--event E] [--spoken TEXT] [--dry-run] "text"
#   notify-voice.sh <anything else>          → forwarded to send.sh unchanged
#
#   --event review|ship|approved|must-fix    pick the spoken line explicitly
#   --spoken TEXT                            say exactly this instead
#
# ── THE SPOKEN LINE IS A FIXED SENTENCE, NOT THE MESSAGE ───────────────────────────
# The Slack TEXT keeps every detail — ticket key, title, one URL per repo — because that is
# what people read, search and click. The AUDIO is a nudge, so it is one canonical sentence per
# event type:
#
#     review    มี MR รอ review …            ship      งานนี้ merge แล้ว …
#     approved  review ผ่านแล้ว …             must-fix  review มี must-fix …
#
# Byte-identical every time ⇒ the content-addressed cache hits on the second ticket and every
# ticket after it ⇒ the voice note costs **nothing** after the first one. Speaking the digest
# instead would embed the ticket title, make every message a unique string, and turn a free
# feature into a per-notification charge — for detail the reader can already see in the text.
#
# ── WHAT IT DOES NOT DO ────────────────────────────────────────────────────────────
# `--reply KEY` (a reviewer's verdict threaded under the request) is forwarded WITHOUT audio.
# Thread discovery lives inside the notify adapter, and Slack cannot attach a file to a thread
# the caller has not resolved — doing it here would mean either duplicating that lookup or
# sending two messages, and one message was the requirement.
#
# ── MUTE DOES NOT APPLY HERE ───────────────────────────────────────────────────────
# `aiworks voice mute on` is about THIS MACHINE'S SPEAKERS — it disables what the laptop would say
# out loud, and everything it would have spent doing so. A voice note is not that: it is a
# deliverable for the team, rendered here and listened to on someone else's phone, so whether the
# channel gets one is not a question about the state of my speakers. A muted laptop is not a reason
# to send the team less.
#
# The ONE switch for it is `voice.notify_voice.enabled` in workspace config (with the usual `.local`
# override) — a standing policy decision, made once, not a "for the next twenty minutes" toggle.
# Off (the shipped default) ⇒ this script forwards its arguments verbatim.

set -euo pipefail
VOICE_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$VOICE_SELF_DIR/lib.sh"

SEND="$VOICE_ROOT/scripts/notify/send.sh"
[[ -x "$SEND" ]] || vdie "no notify adapter at $SEND"

# -v is OURS, and it has to come out of the argument list BEFORE anything is forwarded:
# send.sh has no such flag and rejects it, which turned every verbose passthrough into a failed
# notification the first time this ran.
ARGS=()
for a in "$@"; do
  case "$a" in
    -v|--verbose) export VOICE_VERBOSE=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

# ── passthrough decision, made before anything else is parsed ───────────────────────
# Every failure mode here forwards rather than aborts: this script's job is to ADD audio, and a
# notification that did not go out because the voice half was unconfigured would be a far worse
# bug than a notification without audio.
if [[ "$(voice_language)" != "th" ]]; then
  vlog "notify-voice: language is not th — forwarding"; exec "$SEND" "$@"
fi
if ! voice_cfg_bool voice.enabled false; then
  vlog "notify-voice: voice.enabled is false — forwarding"; exec "$SEND" "$@"
fi
if ! voice_cfg_bool voice.notify_voice.enabled false; then
  vlog "notify-voice: voice.notify_voice.enabled is false — forwarding"; exec "$SEND" "$@"
fi
# NO mute check here, by decision — see the header. `voice.notify_voice.enabled` above is the ONLY
# switch for the voice note.

# ── parse only the shapes we can add audio to ──────────────────────────────────────
ORIG=("$@")
REVIEW="" CHANNEL="" THREAD="" EVENT="" SPOKEN="" DRY=0 TEXT="" UNKNOWN=0 RTITLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --review)     REVIEW="${2:?}"; shift 2 ;;
    --channel)    CHANNEL="${2:?}"; shift 2 ;;
    --thread-ts)  THREAD="${2:?}"; shift 2 ;;
    --event)      EVENT="${2:?}"; shift 2 ;;
    --spoken)     SPOKEN="${2:-}"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    # --title is the DIGEST header for --review, which is exactly the shape dev-cycle's Notify
    # phase sends. It is forwarded to the compose step; the final upload carries its own file
    # title, which is a different thing wearing the same flag name in send.sh.
    --title)      RTITLE="${2:?}"; shift 2 ;;
    --reply|--delete|--file) UNKNOWN=1; shift ;;   # modes we deliberately do not touch
    -*)           UNKNOWN=1; shift ;;
    *)            TEXT="${TEXT:+$TEXT }$1"; shift ;;
  esac
done
[[ "$UNKNOWN" -eq 0 ]] || { vlog "notify-voice: a mode we do not add audio to — forwarding"; exec "$SEND" "${ORIG[@]}"; }

# ── the message text ───────────────────────────────────────────────────────────────
# For --review the digest is composed inside send.sh (it gathers the open PR/MR across every
# repo, which must not be reimplemented here), so ask it for the composed text with --dry-run
# and take everything after its header line.
if [[ -n "$REVIEW" ]]; then
  composed="$("$SEND" --review "$REVIEW" ${RTITLE:+--title "$RTITLE"} ${CHANNEL:+--channel "$CHANNEL"} \
                --dry-run 2>/dev/null | tail -n +2)" || composed=""
  if [[ -z "$composed" ]]; then
    # No open PR/MR anywhere, or the output shape changed. Either way send.sh is the authority
    # on what to do about it — including exiting non-zero.
    vlog "notify-voice: could not compose the --review digest — forwarding"
    exec "$SEND" "${ORIG[@]}"
  fi
  TEXT="$composed"
  [[ -n "$EVENT" ]] || EVENT=review
fi
[[ -n "$TEXT" ]] || { vlog "notify-voice: no text (stdin mode?) — forwarding"; exec "$SEND" "${ORIG[@]}"; }

# ── the spoken line ────────────────────────────────────────────────────────────────
voice_load_credentials
voice_load_tts_provider
P="$(case "$(voice_tts_gender)" in m) printf 'ครับ' ;; *) printf 'ค่ะ' ;; esac)"

if [[ -z "$EVENT" ]]; then
  low="$(printf '%s' "$TEXT" | tr '[:upper:]' '[:lower:]')"
  case "$low" in
    *"please review"*|*"รอ review"*|*"ช่วย review"*) EVENT=review ;;
    *merged*|*"merge เข้า"*|*shipped*|*"deploy แล้ว"*) EVENT=ship ;;
    *approved*|*"อนุมัติ"*) EVENT=approved ;;
    *must-fix*) EVENT="must-fix" ;;
    *) EVENT=generic ;;
  esac
fi

if [[ -z "$SPOKEN" ]]; then
  case "$EVENT" in
    review)   SPOKEN="มี MR รอ review $P" ;;
    ship)     SPOKEN="งานนี้ merge แล้ว$P" ;;
    approved) SPOKEN="review ผ่านแล้ว$P" ;;
    must-fix) SPOKEN="review มี must-fix $P" ;;
    *)        SPOKEN="มีอัปเดตจาก Sunmi $P" ;;
  esac
fi

# ── render + send as ONE message ───────────────────────────────────────────────────
# A temp DIRECTORY so the file inside can be NAMED: Slack shows the filename, and macOS
# `mktemp -t x.XXXXXX` keeps the literal XXXXXX in the name — "voice-note.XXXXXX.SsfCYjZdAS.mp3"
# in a channel looks like a leaked scratch file.
TMPD="$(mktemp -d -t sunmi)" || vdie "mktemp -d failed"
trap 'rm -rf "$TMPD"' EXIT
AUDIO="$TMPD/sunmi-$EVENT.mp3"

# --no-play: this renders a file for the channel, it must not also speak here — and that flag is
# also what carries it past mute, which is the mechanism behind the header note above.
if ! "$VOICE_SELF_DIR/speak.sh" --no-play --no-prefix --out "$AUDIO" "$SPOKEN" >/dev/null; then
  vlog "notify-voice: could not render the voice note — sending the text alone"
  exec "$SEND" "${ORIG[@]}"
fi
vlog "notify-voice: event=$EVENT spoken='$SPOKEN' ($(du -k "$AUDIO" | awk '{print $1}')KB)"

"$SEND" ${CHANNEL:+--channel "$CHANNEL"} ${THREAD:+--thread-ts "$THREAD"} \
        --file "$AUDIO" --title "sunmi-$EVENT" $( ((DRY)) && printf '%s' --dry-run ) "$TEXT"
