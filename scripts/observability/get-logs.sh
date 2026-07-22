#!/usr/bin/env bash
# Query logs from the configured observability backend.
#
#   ./get-logs.sh --query "service.name = 'agent-webservice' AND severity_text = 'ERROR'"
#   ./get-logs.sh --query "..." --from "2026-07-22T10:00:00" --to "2026-07-22T10:15:00"
#   ./get-logs.sh --query "..." --from -30m                  # last 30 minutes
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: get-logs.sh --query <expr> [--from <when>] [--to <when>] [--limit <n>] [--raw]

Print log lines matching a filter expression, newest first, from the backend
selected by OBSERVABILITY_PROVIDER (signoz).

Options:
  --query <expr>   Filter expression, e.g. service.name = 'x' AND severity_text = 'ERROR'.
  --from <when>    Range start: ISO-8601 (2026-07-22T10:00:00), epoch ms, or a relative
                   offset like -30m / -1h / -1d. Default: -1h.
  --to <when>      Range end, same formats. Default: now.
  --limit <n>      Max rows (default 100).
  --raw            Print the raw JSON response instead of parsed log lines.
  -h, --help       Show this help and exit.

Environment:
  OBSERVABILITY_PROVIDER  signoz (default). Provider creds live in .env.
EOF
}

# _to_epoch_ms WHEN -> epoch milliseconds. Accepts epoch ms, ISO-8601, or -Nm/-Nh/-Nd.
_to_epoch_ms() {
  local when="$1" secs
  case "$when" in
    -*)
      local n unit now
      n="${when%[mhd]}"; n="${n#-}"; unit="${when: -1}"
      now="$(date +%s)"
      case "$unit" in
        m) secs=$(( now - n*60 )) ;;
        h) secs=$(( now - n*3600 )) ;;
        d) secs=$(( now - n*86400 )) ;;
        *) echo "unrecognized relative offset: $when" >&2; exit 1 ;;
      esac
      ;;
    ''|*[!0-9]*)
      secs="$(date -j -f '%Y-%m-%dT%H:%M:%S' "$when" +%s 2>/dev/null || date -d "$when" +%s 2>/dev/null)" \
        || { echo "unrecognized time: $when" >&2; exit 1; }
      ;;
    *)
      # all-digits: already epoch (seconds or ms — pass ms through as-is)
      if [[ ${#when} -ge 13 ]]; then printf '%s' "$when"; return 0; else secs="$when"; fi
      ;;
  esac
  printf '%s' "$(( secs * 1000 ))"
}

query="" from="-1h" to="now" limit=100 raw=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --query) query="${2:-}"; shift 2 ;;
    --from) from="${2:-}"; shift 2 ;;
    --to) to="${2:-}"; shift 2 ;;
    --limit) limit="${2:-}"; shift 2 ;;
    --raw) raw=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$query" ]] || { usage; exit 1; }
[[ "$to" == "now" ]] && to="$(date +%s)000"

from_ms="$(_to_epoch_ms "$from")"
to_ms="$(_to_epoch_ms "$to")"

# shellcheck source=lib.sh
. "$DIR/lib.sh"

if [[ "$raw" -eq 1 ]]; then
  body="$(jq -n --argjson start "$from_ms" --argjson end "$to_ms" --argjson limit "$limit" --arg expr "$query" '
    {start:$start,end:$end,step:60,compositeQuery:{queryType:"builder",panelType:"list",builderQueries:{A:{
      dataSource:"logs",queryName:"A",aggregateOperator:"noop",expression:"A",disabled:false,
      limit:$limit,filter:{expression:$expr},orderBy:[{columnName:"timestamp",order:"desc"}]}}}}')"
  curl -sS -X POST -H "${SIGNOZ_AUTH_HEADER}: ${SIGNOZ_API_KEY}" -H 'Content-Type: application/json' \
    --data "$body" "${SIGNOZ_BASE_URL}/api/v4/query_range" | jq '.'
else
  obs_query_logs "$query" "$from_ms" "$to_ms" "$limit"
fi
