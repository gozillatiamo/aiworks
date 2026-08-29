#!/usr/bin/env bash
# PreToolUse(Bash) — when a session keeps grepping a repo that already has a codegraph
# index, say so once.
#
# WHY THIS EXISTS
#   Everything an agent puts in the window is re-sent on every later turn of that session,
#   so a search result is never priced at its own size. Measured across every session on
#   one machine: 25.8 MB of tool results produced 4,109M cache-read tokens — each byte
#   re-billed roughly 640 times. A 1 KB grep result in a 500-turn session is closer to
#   500 KB of billing.
#
#   Search is where that lands. Of 14,184 Bash calls, 6,088 were grep/find/cat-style
#   probes carrying 8.4 MB; with the 1,412 Read calls that is 16.6 MB — 64% of every
#   tool-result byte ever put in a window. Mean Bash result: 1,065 bytes. Not a few large
#   reads; thousands of small ones, each permanent.
#
#   In the same history `codegraph_explore` was called ONCE and graphify never, against
#   22 of 22 repos carrying a live index. The index is not broken and not stale — it is
#   simply not reached for. One `codegraph query` returns the symbols WITH their call
#   paths in a single round-trip, instead of a grep that finds names, a read that opens
#   each file, and both sets of bytes left in the window for the rest of the session.
#
# Advisory, never blocking: exit 0 always. A grep is a legitimate thing to run, and the
# index does not answer every question — prose, config, and logs are still grep's job.
# Fires once per repo per session, at the third probe, so it reads as a reminder and not
# as a lint.
#
#   --check <repo>   print the nudge for <repo> and exit; used by the selftest.
set -uo pipefail

THRESHOLD="${AIWORKS_CODEGRAPH_NUDGE_AT:-3}"

nudge() {  # $1=repo
  printf '💡 %s has a codegraph index, and this is probe %s into it.\n' "$1" "$THRESHOLD"
  printf '   `codegraph query <symbol> -p "$CLAUDE_PROJECT_DIR/%s"` answers "where is X" and\n' "$1"
  printf '   "what calls Y" in ONE result, with file:line and signatures — instead of a grep\n'
  printf '   plus a read per hit, whose bytes are then re-sent on every later turn.\n'
  printf '   Still use grep for prose, config and logs; the index only knows code.\n'
}

if [ "${1:-}" = "--check" ]; then
  nudge "${2:-repo}"
  exit 0
fi

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# Cheap rejects first — this runs on every Bash call.
# Already using the index, or asking it for something: nothing to suggest.
case "$cmd" in *codegraph*) exit 0 ;; esac

B='(^|[[:space:];&|(])'
printf '%s' "$cmd" \
  | grep -qE "${B}(grep|rg|ag|ack|find|cat|hcat|head|tail|sed|awk|wc)([[:space:]]|$)" || exit 0

ROOT="${CLAUDE_PROJECT_DIR:-}"
[ -n "$ROOT" ] || ROOT=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$ROOT" ] && [ -d "$ROOT" ] || exit 0

# Which repo is being probed? The first token whose leading path component is a directory
# under the workspace root carrying an index. Bare name, ./name and an absolute path into
# the workspace all reduce to the same component, so all three are recognised.
repo=""
for tok in $cmd; do
  tok="${tok#\"}"; tok="${tok#\'}"
  tok="${tok#./}"
  case "$tok" in
    -*) continue ;;
    "$ROOT"/*) tok="${tok#"$ROOT"/}" ;;
    /*) continue ;;
  esac
  cand="${tok%%/*}"
  [ -n "$cand" ] || continue
  if [ -d "$ROOT/$cand/.codegraph" ]; then repo="$cand"; break; fi
done
[ -n "$repo" ] || exit 0

# Count probes per repo per session. One flat file, appended: a session is short-lived and
# this stays a handful of lines, so counting beats any structure worth parsing.
sid=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)
state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.codegraph-nudge-${sid//[^A-Za-z0-9_-]/_}"
grep -qxF "$repo:done" "$state" 2>/dev/null && exit 0
printf '%s\n' "$repo" >> "$state" 2>/dev/null || exit 0
seen=$(grep -cxF "$repo" "$state" 2>/dev/null || printf '0')
[ "$seen" -ge "$THRESHOLD" ] || exit 0
printf '%s\n' "$repo:done" >> "$state" 2>/dev/null

nudge "$repo" >&2
exit 0
