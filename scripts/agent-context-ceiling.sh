#!/usr/bin/env bash
#
# Measure the per-agent context ceiling from local workflow transcripts.
#
# A spawned agent is killed when its context crosses a limit set by the runtime, not by anything in
# this workspace: the request ends, the transcript gets a synthetic "Request interrupted by user",
# and the structured result — the agent's last action — is never produced, so the workflow scores
# the step as if it had never run. dev-cycle.js tells every agent where that band starts
# (CONTEXT_DISCIPLINE). This is where that number comes from, and how to re-derive it when the
# runtime moves it: a number pinned in a prompt goes stale silently, a measurement does not.
#
#   scripts/agent-context-ceiling.sh              # every workflow run on this machine
#   scripts/agent-context-ceiling.sh <run-id>     # one run, e.g. wf_cbaee3a7-94b
#   scripts/agent-context-ceiling.sh --csv        # killed,max_context,requests,agent per line
#
# Reads only Claude Code's own transcripts under ~/.claude/projects/*/subagents/workflows/, and only
# their token counters — no message content is printed. Other harnesses keep their transcripts
# elsewhere and are not covered; see docs/agents/harnesses.md.

set -uo pipefail

RUN="${1:-}"
CSV=0
[ "$RUN" = "--csv" ] && { CSV=1; RUN=""; }
[ "${2:-}" = "--csv" ] && CSV=1

command -v jq >/dev/null || { echo "agent-context-ceiling: jq is required" >&2; exit 2; }

BASE="$HOME/.claude/projects"
GLOB="wf_*"
[ -n "$RUN" ] && GLOB="$RUN"

rows=$(mktemp)
trap 'rm -f "$rows"' EXIT

for f in "$BASE"/*/*/subagents/workflows/$GLOB/agent-*.jsonl; do
  [ -e "$f" ] || continue
  killed=0
  grep -q "Request interrupted by user" "$f" && killed=1
  # Total input a request carried = fresh + cached-read + cache-creation. The peak across an
  # agent's requests is the closest thing to "how full it got before it stopped".
  jq -r 'select(.message.usage != null)
         | ((.message.usage.input_tokens // 0)
          + (.message.usage.cache_read_input_tokens // 0)
          + (.message.usage.cache_creation_input_tokens // 0))' "$f" 2>/dev/null \
    | awk -v k="$killed" -v n="$(basename "$f" .jsonl)" \
        '{c++; if ($1 > m) m = $1} END {if (c) printf "%d,%d,%d,%s\n", k, m, c, n}' >> "$rows"
done

[ -s "$rows" ] || { echo "agent-context-ceiling: no workflow agent transcripts found${RUN:+ for $RUN}" >&2; exit 1; }

if [ "$CSV" = 1 ]; then cat "$rows"; exit 0; fi

awk -F, '
  { n++; if ($1) { kn++; ks += $2; if ($2 > kmax) kmax = $2; if (kn == 1 || $2 < kmin) kmin = $2
                   if (kn == 1 || $3 < krmin) krmin = $3; if ($3 > krmax) krmax = $3
                   if ($2 >= 160000) k160++ }
          else    { sn++; ss += $2; if ($2 > smax) smax = $2; if (sn == 1 || $2 < smin) smin = $2
                   if (sn == 1 || $3 < srmin) srmin = $3; if ($3 > srmax) srmax = $3 } }
  END {
    printf "agents %d — killed %d, finished %d\n\n", n, kn, sn
    printf "%-9s %6s  %-22s %-16s\n", "", "n", "context (min/mean/max)", "steps (min/max)"
    if (kn) printf "%-9s %6d  %7d %7d %7d   %5d %5d\n", "killed",   kn, kmin, ks / kn, kmax, krmin, krmax
    if (sn) printf "%-9s %6d  %7d %7d %7d   %5d %5d\n", "finished", sn, smin, ss / sn, smax, srmin, srmax
    if (kn) printf "\nceiling: %d of %d deaths past 160,000 input tokens; highest ever reached %d\n", k160, kn, (kmax > smax ? kmax : smax)
  }' "$rows"
