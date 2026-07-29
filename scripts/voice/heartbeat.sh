#!/usr/bin/env bash
#
# Heartbeat — "still working, currently doing X", for a turn that has run long enough that you
# have started to wonder. Spawned detached by .claude/hooks/voice-ack.sh at the start of every
# turn; it sleeps, wakes, checks whether the turn is still open, and exits the moment it is not.
#
# Usage:
#   heartbeat.sh [-v] --session ID --turn EPOCH [--transcript PATH]
#
# ── NO LLM CALL ────────────────────────────────────────────────────────────────────
# The line is a TEMPLATE over the last tool activity read from the transcript:
#
#     "ยังทำงานอยู่ครับ ตอนนี้ <what the last tool call was>"
#
# A heartbeat is a status ping, not a report — its entire value is "alive, and doing X". Sending
# it through the summarizer would add a second of latency and a fraction of a cent for prose
# nobody is listening to closely, and the templated form repeats often enough that the audio
# cache mostly hits. The elapsed minutes are deliberately NOT spoken: they would make every
# heartbeat a unique string and turn a cache hit into a synthesis every time. `-v` logs them.
#
# ── QUEUED AS AN `ack`, NOT A MILESTONE ────────────────────────────────────────────
# Deliberate: a heartbeat is the most droppable thing this feature produces. As an `ack` it
# inherits exactly the right rules — dropped if >30 s stale, superseded by a newer one, and
# silent inside 20 s of anything else that spoke. A heartbeat that queues behind a real
# milestone and plays late is worse than one that never plays.
#
# ── THE SCHEDULE BACKS OFF ─────────────────────────────────────────────────────────
# 90 s, then 3 min, then 5 min, capped at 6 utterances. A fixed 90 s interval on a twenty-minute
# dev-cycle run would speak thirteen times and become the thing you mute.

set -euo pipefail
VOICE_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$VOICE_SELF_DIR/lib.sh"

GAPS=(90 180 300 300 300 300)     # seconds to sleep BEFORE each beat
SESSION="" MY_TURN="" TRANSCRIPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) export VOICE_VERBOSE=1; shift ;;
    --session)    SESSION="${2:-}"; shift 2 ;;
    --turn)       MY_TURN="${2:?}"; shift 2 ;;
    --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
    -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; exit 0 ;;
    *)            vdie "unknown option $1 (see -h)" ;;
  esac
done

voice_gate_or_exit "heartbeat"
voice_cfg_bool voice.autoplay.enabled false || { vlog "heartbeat skipped: autoplay off"; exit 0; }
voice_cfg_bool voice.autoplay.heartbeat true || { vlog "heartbeat skipped: voice.autoplay.heartbeat is false"; exit 0; }
[[ -n "$SESSION" ]] || SESSION="$VOICE_ROOT"
[[ -n "$MY_TURN" ]] || MY_TURN="$(voice_turn_get "$SESSION" turn)"

# What the last tool call was, in a form worth saying out loud. Falls back to the tool's own
# name — "ตอนนี้ Grep" is thin but true, and better than inventing detail.
_activity() {
  [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -rs '
    [.[] | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")] | last
    | if . == null then ""
      elif .name == "Bash"      then (.input.description // (.input.command // "" | .[0:60]))
      elif .name == "Task"      then ("agent: " + (.input.description // ""))
      elif (.name | test("^(Read|Edit|Write|NotebookEdit)$")) then
        (.name + " " + ((.input.file_path // "") | split("/") | last))
      elif (.name | test("^(Grep|Glob)$")) then (.name + " " + (.input.pattern // ""))
      elif (.name | startswith("mcp__")) then (.name | split("__") | .[1:] | join(" "))
      else .name end
    | gsub("[\"`]"; "") | .[0:70]
  ' "$TRANSCRIPT" 2>/dev/null || printf ''
}

beat=0
for gap in "${GAPS[@]}"; do
  sleep "$gap"
  beat=$((beat + 1))

  now_turn="$(voice_turn_get "$SESSION" turn)"
  ended="$(voice_turn_get "$SESSION" ended)"
  if [[ "$now_turn" != "$MY_TURN" ]]; then
    vlog "heartbeat: turn $MY_TURN superseded by $now_turn — done"
    exit 0
  fi
  if [[ "$ended" -ge "$MY_TURN" && "$MY_TURN" -gt 0 ]]; then
    vlog "heartbeat: turn finished — done after $beat check(s)"
    exit 0
  fi
  # Muted is not a reason to stop watching: the mute may come off before the turn ends.
  if voice_is_muted; then
    vlog "heartbeat: muted — skipping beat $beat"
    continue
  fi

  elapsed=$(( $(voice_now) - MY_TURN ))
  act="$(_activity)"
  if [[ -n "$act" ]]; then line="ยังทำงานอยู่ครับ ตอนนี้ $act"; else line="ยังทำงานอยู่ครับ"; fi
  vlog "heartbeat $beat (${elapsed}s in): $line"

  "$VOICE_SELF_DIR/speak.sh" --kind ack "$line" || vlog "heartbeat: speak failed, continuing"
done

vlog "heartbeat: ${#GAPS[@]} beats spoken — not saying any more about this turn"
