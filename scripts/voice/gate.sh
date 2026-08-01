#!/usr/bin/env bash
#
# The gate voice — "Shall I…?", spoken when the run STOPS AND WAITS FOR YOU.
# Spawned DETACHED by .claude/hooks/voice-gate.sh.
#
# Usage:
#   gate.sh [-v] --event NAME [--session ID] [--payload FILE]
#
# ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────
# It is the single most recognisable thing JARVIS does. He does not act on the big irreversible
# step; he names it and waits:
#
#     "Shall I begin machining the parts?"      "The House Party Protocol, sir?"
#     "Shall I render, utilizing proposed specifications?"      "Shall I take over?"
#
# Every gate in this workspace was already there — a permission prompt, a plan waiting for approval,
# an auto-mode denial — and every one of them was SILENT. The person who stepped away
# from the screen learned about them by coming back and finding nothing had happened. That is the
# half of "talks like JARVIS" that no amount of narration fixes: the narrator says what happened, and
# this says what is waiting for YOU.
#
# ── THE EVENTS ─────────────────────────────────────────────────────────────────────
#   PermissionRequest            a tool call needs a decision      → "ขออนุญาตรัน <cmd> ค่ะ"
#   PermissionDenied             auto-mode refused it              → "<cmd> ถูก block ค่ะ"  (red)
#   PreToolUse(ExitPlanMode)     a plan is up for approval         → "แผนพร้อมแล้ว ขออนุมัติค่ะ"
#   Notification                 permission / agent state          → classified from the message
#
# PermissionDenied earns its place on its own: an auto-mode denial is INVISIBLE — it never becomes a
# prompt, the model simply gets a refusal and reroutes. Eight of them in one ticket went unnoticed
# until the transcript was read back afterwards.
#
# ── WHAT IT DOES NOT DO ────────────────────────────────────────────────────────────
# It never speaks the notification's own text. Those messages are English ("Permission required for
# Bash tool") and this is a Thai voice — an English sentence read by a Thai voice model is the worst
# of both. An event it cannot classify is SILENT rather than guessed at.
#
# Independent of `chattiness`: a gate is a WHETHER, not a HOW MUCH — the same reason `ack` and
# `milestones` are their own switches. Its own key is voice.autoplay.gates.
#
# Inert unless `language: th` AND voice.enabled AND voice.autoplay.enabled AND
# voice.autoplay.gates — and silent when muted, like everything else this machine says.

set -euo pipefail
VOICE_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$VOICE_SELF_DIR/lib.sh"

DEDUPE_WINDOW=20   # seconds — one prompt can arrive as two events (see below)

SESSION="" PAYLOAD="" EVENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) export VOICE_VERBOSE=1; shift ;;
    --session)    SESSION="${2:-}"; shift 2 ;;
    --payload)    PAYLOAD="${2:-}"; shift 2 ;;
    --event)      EVENT="${2:-}"; shift 2 ;;
    -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; exit 0 ;;
    *)            vdie "unknown option $1 (see -h)" ;;
  esac
done

cleanup() { [[ -n "$PAYLOAD" && -f "$PAYLOAD" ]] && rm -f "$PAYLOAD"; return 0; }
trap cleanup EXIT

voice_gate_or_exit "gate"
voice_cfg_bool voice.autoplay.enabled false || { vlog "gate skipped: autoplay off"; exit 0; }
voice_cfg_bool voice.autoplay.gates true || { vlog "gate skipped: voice.autoplay.gates is false"; exit 0; }
voice_is_muted && { vlog "gate: muted — nothing synthesized"; exit 0; }
[[ -n "$SESSION" ]] || SESSION="$VOICE_ROOT"
voice_require jq

_p() { [[ -n "$PAYLOAD" && -f "$PAYLOAD" ]] || { printf ''; return 0; }
       jq -r --arg k "$1" '.[$k] // empty' "$PAYLOAD" 2>/dev/null || printf ''; }

TOOL="$(_p tool_name)"
MESSAGE="$(_p message)"

# The command or target, short enough to speak: `cargo test --lib -p x` → "cargo test".
_target() {
  local cmd path
  [[ -n "$PAYLOAD" && -f "$PAYLOAD" ]] || { printf ''; return 0; }
  cmd="$(jq -r '.tool_input.command // empty' "$PAYLOAD" 2>/dev/null || true)"
  if [[ -n "$cmd" ]]; then
    printf '%s' "$cmd" | python3 -c '
import re, sys, os
cmd = sys.stdin.read().strip().split("&&")[0].split("|")[0].strip()
parts = [p for p in re.split(r"\s+", cmd) if p and not p.startswith("-")]
if parts:
    head = os.path.basename(parts[0])
    if len(parts) > 1 and re.fullmatch(r"[A-Za-z][\w.:-]*", parts[1]):
        head += " " + parts[1]
    sys.stdout.write(head[:28])
' 2>/dev/null || true
    return 0
  fi
  path="$(jq -r '.tool_input.file_path // .tool_input.path // empty' "$PAYLOAD" 2>/dev/null || true)"
  [[ -n "$path" ]] && printf '%s' "$(basename "$path")"
}

LINE="" CUE=attention CLASS=""
case "$EVENT" in
  PermissionRequest)
    T="$(_target)"
    if [[ "$TOOL" == "Bash" && -n "$T" ]]; then LINE="ขออนุญาตรัน $T ค่ะ"
    elif [[ -n "$TOOL" && -n "$T" ]];   then LINE="ขออนุญาตใช้ $TOOL กับ $T ค่ะ"
    elif [[ -n "$TOOL" ]];              then LINE="ขออนุญาตใช้ $TOOL ค่ะ"
    else                                     LINE="รออนุญาตอยู่ค่ะ"; fi
    CLASS=perm
    ;;
  PermissionDenied)
    T="$(_target)"
    LINE="${T:-$TOOL} ถูก block ค่ะ"
    CUE=red
    CLASS=denied
    ;;
  PreToolUse)
    # Wired for ExitPlanMode only, but a matcher is a string in a settings file — check anyway
    # rather than announcing a plan gate for whatever tool a future edit points at this hook.
    [[ "$TOOL" == "ExitPlanMode" ]] || { vlog "gate: PreToolUse for $TOOL is not a gate"; exit 0; }
    LINE="แผนพร้อมแล้ว ขออนุมัติค่ะ"
    CLASS=plan
    ;;
  Notification)
    # Classified, never read aloud (the message is English). Unknown ⇒ silence.
    m="$(printf '%s' "$MESSAGE" | tr '[:upper:]' '[:lower:]')"
    case "$m" in
      *permission*|*approve*|*allow*) LINE="ขออนุญาตทำงานต่อค่ะ"; CLASS=perm ;;
      *completed*|*finished*|*done*)  LINE="agent ทำเสร็จแล้วค่ะ";  CLASS=agent ;;
      # NO `idle` CLASS — deliberately, and do not put one back. "Claude is waiting for your input"
      # is not a gate: nothing is blocked and nothing needs a decision. The turn ENDED, the closing
      # line already said what happened, and the only new information in "รอคำสั่งอยู่ค่ะ" is that
      # the person has not typed yet — which they know, because they are the one not typing. It is
      # the one line here that fires while someone is THINKING, so it reads as nagging rather than
      # as the assistant getting out of the way. Every other class names something that will not
      # move until a human acts.
      *) vlog "gate: notification not classifiable — staying quiet: ${MESSAGE:0:60}"; exit 0 ;;
    esac
    ;;
  *)
    vlog "gate: no line for event '$EVENT'"
    exit 0
    ;;
esac

[[ -n "$LINE" ]] || exit 0

# One waiting prompt arrives as TWO events — PermissionRequest fires, and so does
# Notification/permission_prompt for the same dialog. Deduped on the CLASS, not on the sentence:
# those two produce DIFFERENTLY WORDED lines for one prompt ("ขออนุญาตรัน cargo test ค่ะ" and
# "ขออนุญาตทำงานต่อค่ะ"), so a text hash lets both through and the machine asks twice. The class is
# what the user experiences — one thing is waiting — and the first, more specific wording wins
# because it arrives first.
NOW="$(voice_now)"
LAST="$(voice_narrate_get "$SESSION" gate)"
LAST_TS="$(voice_narrate_get "$SESSION" gatets)"
if [[ "$CLASS" == "$LAST" ]] && (( NOW - LAST_TS < DEDUPE_WINDOW )); then
  vlog "gate: a '$CLASS' gate already spoke $((NOW - LAST_TS))s ago — once is enough"
  exit 0
fi
voice_narrate_put "$SESSION" gate "$CLASS"
voice_narrate_put "$SESSION" gatets "$NOW"

vlog "gate[$EVENT/$CUE]: $LINE"
# --kind milestone: NEVER dropped by the queue. A narration about a finished step can go stale, but
# "this is waiting for you" is still true five minutes later — that is the whole point of saying it.
# Deleted here, not by the EXIT trap: `exec` replaces this process, so the trap never runs on the
# one path that always reaches the end.
cleanup
exec "$VOICE_SELF_DIR/speak.sh" --kind milestone --cue "$CUE" "$LINE"
