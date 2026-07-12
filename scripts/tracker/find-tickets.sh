#!/usr/bin/env bash
# Search the configured tracker for existing tickets — the dedup lookup.
#
# The other scripts resolve ONE ticket by key/number/url; this one QUERIES the
# tracker so a caller (e.g. /clarifying-ticket) can check whether a finding is
# already tracked before filing a duplicate.
#
#   ./find-tickets.sh --query "encryption"                 # title/summary matches "encryption"
#   ./find-tickets.sh --query "Isar index" --open          # ... and not Done
#   ./find-tickets.sh --type "Bug" --open                  # all open Bug tickets
#   ./find-tickets.sh --query rebuild --type "Polish"      # AND of both
#   ./find-tickets.sh --query startup --json               # raw JSON for scripting
#
# Output (one line per match, newest first):
#   <ID> | <Status> | <Type> | <Title>  ::  <Description>
#
# Options are ABSTRACT; each provider maps them to its own query (Notion database
# filter; Jira JQL). NOTE: Notion matches a case-insensitive substring of the title;
# Jira's `summary ~` is a word/text match — pick a distinctive whole token.
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: find-tickets.sh [options]

Search the configured tracker (TRACKER_PROVIDER) and print matching tickets
(newest first), one per line: "<ID> | <Status> | <Type> | <Title>  ::  <Description>".
Use it to check whether a finding is already tracked before filing a new ticket.

Options:
  --query <text>     Match tickets whose title/summary contains/matches this text
                     (pick a distinctive keyword — Notion: substring; Jira: word match).
  --type <name>      Match a ticket type. Repeatable / comma-separated → OR.
  --open             Exclude "done" tickets (Notion: Status != NOTION_STATUS_DONE;
                     Jira: statusCategory != Done).
  --done             Keep ONLY "done" tickets (the inverse of --open). Used by
                     /estimate-ticket to pull a completed-ticket calibration set.
  --estimated        Keep only tickets that carry an estimate — a Dev-points or
                     QA-points (or effort) value. Pairs with --done --limit 10 for a
                     deterministic calibration set. No-op if no point field is configured.
  --limit <n>        Print at most n rows (default 50; 0 = no limit).
  --json             Print the raw matched tickets as a JSON array instead of lines.
  -h, --help         Show this help and exit.

With NO --query and NO --type, lists every ticket (newest first) — combine with
--open to scope it.

Environment:
  TRACKER_PROVIDER   notion | jira | linear (default: notion). Provider creds live in .env.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

query=""; open=0; done_only=0; estimated=0; limit=50; as_json=0; types_json='[]'
addtype() { types_json="$(jq -n --argjson cur "$types_json" --arg t "$1" '$cur + [$t]')"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --query)  [[ -n "${2:-}" ]] || die "--query needs a value"; query="$2"; shift 2 ;;
    --type)   [[ -n "${2:-}" ]] || die "--type needs a value";
              IFS=',' read -r -a _t <<<"$2"
              for t in "${_t[@]}"; do t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"; [[ -n "$t" ]] && addtype "$t"; done
              shift 2 ;;
    --open)   open=1; shift ;;
    --done)   done_only=1; shift ;;
    --estimated) estimated=1; shift ;;
    --limit)  [[ -n "${2:-}" ]] || die "--limit needs a value"; limit="$2"; shift 2 ;;
    --json)   as_json=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)       die "unknown option: $1   (see -h)" ;;
    *)        die "unexpected argument: $1   (see -h)" ;;
  esac
done

opts="$(jq -n --arg q "$query" --argjson open "$open" --argjson done "$done_only" \
  --argjson estimated "$estimated" --argjson limit "$limit" \
  --argjson json "$as_json" --argjson types "$types_json" \
  '{query: $q, open: ($open == 1), done: ($done == 1), estimated: ($estimated == 1),
    limit: $limit, as_json: ($json == 1), types: $types}')"

tracker_find "$opts"
