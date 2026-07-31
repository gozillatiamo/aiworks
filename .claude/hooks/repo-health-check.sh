#!/usr/bin/env bash
#
# SessionStart + UserPromptSubmit hook — workspace repo readiness health check.
#
# Why this exists
# ---------------
# A fresh Superset worktree runs .superset/setup.sh (which calls `aiworks sync`) to CLONE
# and onboard every product repo declared in workspace.config.yaml. That clone+onboard of
# ~16 repos takes several minutes — but the Claude Code session in the new worktree starts
# IMMEDIATELY, before setup finishes. So Claude would try to cd / grep / search a repo
# directory that setup has not cloned yet, get stuck "finding the repo directory", or wrongly
# conclude a repo "does not exist". This hook checks — at session start, and again every turn
# until the workspace is ready — which mani-declared repos are actually cloned, and injects a
# clear status + guidance into context so Claude WAITS for setup instead of erroring out.
#
# How it decides
# --------------
# The EXPECTED repo set is read from the committed mani.d/*.yaml (`path: ../<repo>`), which is
# present in every worktree from the first checkout — no `mani` binary required. The clones
# themselves are git-ignored and appear only as setup progresses. A repo is "ready" when its
# directory exists AND has a valid git HEAD (a finished, checked-out clone); an in-progress
# clone (dir present, no HEAD yet) is treated as NOT ready.
#
# Modes
# -----
#   (no args)      hook mode: emit {hookSpecificOutput.additionalContext} JSON for the harness.
#                  SessionStart reports once (even when healthy); UserPromptSubmit injects only
#                  when NOT ready (silent when healthy, so it never bloats a normal turn).
#   --status       print a one-line human summary; exit 0 if all ready, else 1. No JSON.
#   --wait [secs]  block (polling every 5s) until every repo is ready or <secs> elapse
#                  (default 900); prints progress. exit 0 when ready, 1 on timeout.
#
# Wired under SessionStart + UserPromptSubmit in .claude/settings.json. Committed, so every
# teammate's fresh worktree gets the same guard (the race hits everyone, not just the author).
#
set -uo pipefail

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# ── enumerate the EXPECTED product repos from the committed mani.d/*.yaml (path: ../<repo>).
# Dependency-free (no `mani` needed) and present even in a bare fresh worktree.
expected="$(
  awk 'match($0, /path:[[:space:]]*\.\.\/[A-Za-z0-9._-]+/) {
         s = substr($0, RSTART, RLENGTH); sub(/.*\//, "", s); print s
       }' "$root"/mani.d/*.yaml 2>/dev/null | sort -u
)"

# sets: total, present_count, missing (space-separated names, leading space trimmed)
compute() {
  total=0; present_count=0; missing=""
  local name
  for name in $expected; do
    total=$((total + 1))
    if [ -e "$root/$name/.git" ] && git -C "$root/$name" rev-parse --verify -q HEAD >/dev/null 2>&1; then
      present_count=$((present_count + 1))
    else
      missing="$missing $name"
    fi
  done
  missing="${missing# }"
}

# Classify the setup process so we can tell "still cloning" apart from "crashed" and from
# "never ran". Sets two globals (NOT echoed — a $(...) subshell would drop $setup_detail):
# SETUP_STATE = running | crashed | idle, and $setup_detail (a human phrase for the message).
#
# Preferred signal: the per-worktree lock .superset/run/setup.lock that setup.sh writes at start
# and trap-removes on exit (deterministic, scoped to THIS worktree, no command-string guessing).
#   • lock present + recorded pid alive  → running
#   • lock present + recorded pid gone    → crashed (hard-killed / power loss; trap never fired)
#   • no lock                             → fall back to pgrep (manual/legacy setup) → running|idle
LOCK="$root/.superset/run/setup.lock"
SETUP_STATE=""
setup_detail=""
setup_state() {
  setup_detail=""
  local pid started
  if [ -f "$LOCK" ]; then
    pid=$(sed -n 's/^pid=//p' "$LOCK" 2>/dev/null | head -n1)
    started=$(sed -n 's/^started=//p' "$LOCK" 2>/dev/null | head -n1)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      setup_detail="setup process pid $pid, started ${started:-unknown}"
      SETUP_STATE=running; return
    fi
    setup_detail="a setup lock exists (started ${started:-unknown}) but its process (pid ${pid:-?}) is gone"
    SETUP_STATE=crashed; return
  fi
  if command -v pgrep >/dev/null 2>&1; then
    if pgrep -f '[.]superset/setup\.sh' >/dev/null 2>&1 \
       || pgrep -f 'aiworks[ ].*sync' >/dev/null 2>&1 \
       || pgrep -f 'mani[ ].*sync' >/dev/null 2>&1; then
      setup_detail="a setup/sync process is running (detected via pgrep; no lock file)"
      SETUP_STATE=running; return
    fi
  fi
  setup_detail="no setup process or lock detected"
  SETUP_STATE=idle
}

# ── CLI modes (manual / on-demand use) ──────────────────────────────────────────────
case "${1:-}" in
  --status)
    compute
    if [ "$total" -eq 0 ]; then echo "no product repos declared in mani.d/ — nothing to check."; exit 0; fi
    if [ -z "$missing" ]; then echo "OK: all $total product repos are cloned and ready."; exit 0; fi
    echo "NOT READY: $present_count/$total repos cloned — pending: $missing"
    setup_state
    case "$SETUP_STATE" in
      running) echo "  setup is running ($setup_detail) — should clear as it finishes." ;;
      crashed) echo "  setup looks interrupted ($setup_detail) — re-run .superset/setup.sh (idempotent)." ;;
      idle)    echo "  no setup running — run .superset/setup.sh." ;;
    esac
    exit 1
    ;;
  --wait)
    secs="${2:-900}"
    deadline=$(( $(date +%s) + secs ))
    while :; do
      compute
      if [ "$total" -eq 0 ] || [ -z "$missing" ]; then
        echo "OK: all ${total} product repos are cloned and ready."; exit 0
      fi
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "TIMEOUT after ${secs}s — still not ready: $missing"; exit 1
      fi
      printf 'waiting for setup... %d/%d cloned; pending: %s\n' "$present_count" "$total" "$missing"
      sleep 5
    done
    ;;
esac

# ── hook mode ───────────────────────────────────────────────────────────────────────
compute
[ "$total" -eq 0 ] && exit 0   # nothing declared → nothing to inject

# Which event? SessionStart reports always; UserPromptSubmit only when NOT ready.
event="SessionStart"
if [ ! -t 0 ]; then
  ev="$(cat 2>/dev/null | jq -r '.hook_event_name // empty' 2>/dev/null)"
  [ -n "$ev" ] && event="$ev"
fi

# emit additionalContext JSON for $event with message $1. Messages are single-line, plain
# ASCII with no double-quotes/backticks, so the jq-less fallback stays valid JSON.
emit() {
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg ev "$event" --arg ctx "$1" \
      '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$event" "$1"
  fi
}

if [ -z "$missing" ]; then
  # Healthy: announce once at SessionStart, stay silent on every prompt (no per-turn bloat).
  [ "$event" = "SessionStart" ] && \
    emit "[workspace repo health] All $total product repos are cloned and present in this worktree - the workspace is ready."
  exit 0
fi

# Not ready → inject clear guidance on BOTH events so Claude never treats a mid-setup repo as missing.
setup_state
case "$SETUP_STATE" in
  running)
    cause="The workspace setup (.superset/setup.sh via aiworks sync) is still running - $setup_detail. A fresh Superset worktree clones and onboards every product repo, which takes several minutes."
    action="Do NOT treat a not-ready repo as an error, do not cd/grep/search inside it, and do not conclude it is absent - it is simply not cloned YET. If the user asks you to work in a not-ready repo, wait for setup: run  .claude/hooks/repo-health-check.sh --wait  to block until every repo is ready (or  --status  to recheck now), then proceed."
    ;;
  crashed)
    cause="A previous setup did not finish - $setup_detail (likely hard-killed or a crash)."
    action="Tell the user setup was interrupted and offer to re-run  .superset/setup.sh  to finish cloning the missing repos (it is idempotent - already-cloned repos are skipped). Do not treat the missing repos as a real error until setup completes."
    ;;
  *)
    cause="No setup is running and no setup lock is present, so setup has not started."
    action="Tell the user and offer to run  .superset/setup.sh  to clone and onboard the missing repos. Do not treat the missing repos as a real error until setup has completed."
    ;;
esac
emit "[workspace repo health] Only $present_count of $total product repos are cloned in this worktree. NOT ready: $missing. $cause $action"
exit 0
