#!/usr/bin/env bash
# PostToolUse(*) + SessionStart(compact) — the self-handoff loop that keeps an agent sharp.
#
# WHY THIS EXISTS
#   Two things go wrong past ~140k of context, and both are measured on this workspace's own
#   runs (docs/agents/headroom.md, scripts/agent-context-ceiling.sh): the runtime kills a spawned
#   agent somewhere past 160k with no last step to tidy up in, and long before that the answers
#   degrade — the model reasons over a window most of which is stale tool output it can no longer
#   weigh. Compaction fixes the window but the built-in summary is written by a model that is
#   already in that state, about work it did not plan to summarise. A handoff document written
#   ON PURPOSE, by the agent, while it still knows what matters, is a better seed — and the
#   `handoff` skill already writes exactly that for a NEXT agent. This hook makes the agent
#   write one for ITSELF, at a path the hook chooses, and hands it back after the compaction.
#
# THE LOOP, per (session, agent):
#   armed      window ≥ AIWORKS_CONTEXT_HANDOFF  → demand the document (PostToolUse `block`
#              with the reason, the strongest thing a hook can say) → requested
#   requested  document present and newer than the demand → say so, ask for nothing new,
#              and — for a subagent — to RETURN a partial naming the path → written
#              still absent → demand again, at most AIWORKS_HANDOFF_NAGS times (an agent with
#              no Write tool cannot comply, and a nag that never ends is ignored anyway)
#              window collapsed (compaction happened without a document) → armed
#   written    SessionStart(compact) fires, or the window collapses → hand the document back
#              as context → resumed
#   resumed    behaves as armed: the next crossing writes the next document over the last.
#
# The document lives OUTSIDE the workspace (the skill's own rule), under AIWORKS_HANDOFF_DIR,
# as <sid>/<agent_id|main>.md; the state file sits beside it. Everything is keyed by the
# caller's OWN transcript (lib-context-window.sh): a subagent is measured on its file, never
# the parent's. Exit 0 always — a measuring hook must never break the tool call it rides on.
#
#   --check <n>   print the phase transition for a window of n tokens from `armed`; selftest.
set -uo pipefail

H="${AIWORKS_CONTEXT_HANDOFF:-140000}"
NAGS="${AIWORKS_HANDOFF_NAGS:-3}"
# Tool calls between the document landing and the seal closing. It pays for the one thing the
# document CANNOT carry: an uncommitted tree. Findings, verdicts and ledger rows go in the
# document and the relay posts them, so this is slack rather than a dependency — 4-6 calls is
# the honest need (status, add, commit, push, a ledger Write) and the rest is room to retry.
GRACE="${AIWORKS_HANDOFF_GRACE:-20}"
tmp="${TMPDIR:-/tmp}"; DIR="${AIWORKS_HANDOFF_DIR:-${tmp%/}/aiworks-handoff}"
DROP=20000   # a window never shrinks between two calls except across a compaction

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-context-window.sh"

json_out() { # json_out <decision|""> <reason|""> <additionalContext|""> <systemMessage|"">
  jq -cn --arg d "$1" --arg r "$2" --arg c "$3" --arg m "$4" '
    ( if $d != "" then {decision:$d, reason:$r} else {} end )
    + ( if $c != "" then {hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$c}} else {} end )
    + ( if $m != "" then {systemMessage:$m} else {} end )'
}

demand() { # demand <window> <doc> <nag>
  printf '⛔ Context window %sk has crossed %sk — the band where an agent gets killed or starts reasoning over stale output. FIRST, before any other work: invoke the `handoff` skill with the argument `self %s` and write a handoff document for YOURSELF at exactly that path (create the directory; overwrite an old file). It must let a fresh copy of you continue without re-reading anything: the task and its acceptance, what is done (commits, paths, threads), what is in flight, the exact next steps, decisions and why, files already read that need no re-read, suggested skills. Then continue the step in flight — a compaction follows and you are restored from that file. (%s/%s)' \
    "$(( $1 / 1000 ))" "$(( H / 1000 ))" "$2" "$3" "$NAGS"
}

recorded() { # recorded <doc> <grace>
  printf '✅ Handoff recorded at %s — SEALED IN %s TOOL CALLS. Spend them on ONE thing: making what you already hold durable. Commit or park the working tree (a `wip(...)` commit, or `git stash push -u`) — that is the only thing this document cannot carry for you. Open nothing new, start no fix, run no suite. Then RETURN your result, and put the literal token HANDOFF_RELAY:%s in it — that token is what ends you cleanly and starts your replacement from this document instead of from an empty context. After those %s calls every tool is denied, so returning is the only move you will have left.' "$1" "$2" "$1" "$2"
}

sealed_text() { # sealed_text <doc>
  printf '⛔ SEALED. Your handoff document is written at %s and your grace window is spent, so every tool call from here is denied — there is nothing left to do but RETURN. Return your result now, filled with what is TRUE so far (a partial is a real answer the workflow continues from), and INCLUDE THE LITERAL TOKEN HANDOFF_RELAY:%s in it. That token is not decoration: it is what tells whoever spawned you to replace you with a fresh agent continuing from that document. Without it you are scored as having simply stopped.' "$1" "$1"
}

resume_text() { # resume_text <doc>
  printf '🔁 You were compacted. What follows is YOUR OWN handoff document, written by you before the compaction at %s. Continue from its next steps; do not re-read what it says is already known. The loop repeats: at %sk you will be asked to write the next one. When the work is DONE, hand off to the next agent exactly as before.\n\n' "$1" "$(( H / 1000 ))"
  head -c 32768 "$1" 2>/dev/null
}

if [ "${1:-}" = "--check" ]; then
  w="${2:-0}"
  if [ "$w" -ge "$H" ] 2>/dev/null; then echo "armed -> requested"; else echo "armed -> armed"; fi
  exit 0
fi

payload="$(cat 2>/dev/null)" || exit 0
ev="$(printf '%s' "$payload" | jq -r '.hook_event_name // "PostToolUse"' 2>/dev/null)" || exit 0
sid="$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)"
aid="$(printf '%s' "$payload" | jq -r '.agent_id // ""' 2>/dev/null)"
tp="$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)"
[ -n "$sid" ] || exit 0
# THE MAIN SESSION IS NOT OUR BUSINESS (ADR-0037). The model cannot run /compact, so a demand
# here bought a document that only paid off if a person then compacted; auto-compaction already
# restores the window on its own. Everything below is for an agent that can be ENDED and
# REPLACED — which the main session, the one agent nobody can respawn, is not.
[ -n "$aid" ] || exit 0

key="${aid:-main}"; key="${key//[^A-Za-z0-9_.-]/_}"
sdir="$DIR/${sid//[^A-Za-z0-9_.-]/_}"
doc="$sdir/$key.md"
st="$sdir/$key.state"
# A workflow agent's brief names a STEP key; then the document is shared by every attempt at that
# step (by-key/<key>.md) while the state stays this agent's own — a replacement is asked for its
# own document, and the predecessor's, older than the demand, never counts as it.
if [ -n "$aid" ]; then
  hk="$(handoff_key_of "$(own_transcript "$tp" "$aid")")"
  [ -n "$hk" ] && doc="$DIR/by-key/$hk.md"
fi

phase=armed; ts=0; nag=0; wref=0
[ -f "$st" ] && read -r phase ts nag wref < "$st" 2>/dev/null
case "$ts"   in ''|*[!0-9]*) ts=0 ;; esac
case "$nag"  in ''|*[!0-9]*) nag=0 ;; esac
case "$wref" in ''|*[!0-9]*) wref=0 ;; esac
save() { mkdir -p "$sdir" 2>/dev/null && printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" > "$st" 2>/dev/null; }
now="$(date +%s)"

# ── PreToolUse: the seal. Runs before EVERY tool call in the workspace, so it leaves as fast as
# it can — no state file, or a phase that is not grace/sealed, and it is already gone. Only two
# things get through a closed seal: a write to the handoff document itself (the agent may refresh
# it), and returning, which is not a tool call at all.
if [ "$ev" = "PreToolUse" ]; then
  case "$phase" in grace|sealed) ;; *) exit 0 ;; esac
  fp="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""' 2>/dev/null)"
  [ -n "$fp" ] && [ "$fp" = "$doc" ] && exit 0
  if [ "$phase" = grace ] && [ "$nag" -gt 0 ]; then
    nag=$((nag - 1)); save grace "$ts" "$nag" "$wref"
    printf 'SEALED IN %s TOOL CALLS — commit or park what you hold, then return with HANDOFF_RELAY:%s\n' "$nag" "$doc" >&2
    exit 0
  fi
  save sealed "$now" 0 "$wref"
  sealed_text "$doc" >&2
  exit 2
fi

# ── PostToolUse: measure the caller's OWN window.
tx="$(own_transcript "$tp" "$aid")"
[ -n "$tx" ] || exit 0
win="$(window_of "$tx")"
[ "$win" -gt 0 ] || exit 0

mark="$sdir/$key.mark"   # mtime = the moment of the FIRST demand; the document must not be older
case "$phase" in
  armed|resumed)
    [ "$win" -ge "$H" ] || exit 0
    save requested "$now" 1 "$win"
    touch "$mark" 2>/dev/null
    json_out block "$(demand "$win" "$doc" 1)" "" ""
    ;;
  requested)
    if [ -f "$doc" ] && ! [ "$doc" -ot "$mark" ]; then
      save grace "$now" "$GRACE" "$win"
      json_out "" "" "$(recorded "$doc" "$GRACE")" "handoff written at $doc — sealed in $GRACE tool calls"
    elif [ "$win" -lt "$(( wref - DROP ))" ]; then
      save armed "$now" 0 0            # compacted without a document: nothing to hand back
    elif [ "$nag" -lt "$NAGS" ]; then
      nag=$((nag + 1)); save requested "$ts" "$nag" "$wref"
      json_out block "$(demand "$win" "$doc" "$nag")" "" ""
    fi
    ;;
  grace|sealed)
    # The runtime can still compact a subagent in place before the seal ever closes (the
    # auto-compaction point sits above the demand). That is the better ending — no re-spawn at
    # all — so it keeps winning: hand the document back and re-arm.
    [ "$win" -lt "$(( wref - DROP ))" ] || exit 0
    save resumed "$now" 0 0
    json_out "" "" "$(resume_text "$doc")" ""
    ;;
esac
exit 0
