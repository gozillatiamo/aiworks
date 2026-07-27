#!/usr/bin/env bash
# Query logs from the configured observability backend.
#
#   ./get-logs.sh --service agent-webservice --severity ERROR --env staging
#   ./get-logs.sh --env prod --body-contains 'timeout' --from -30m
#   ./get-logs.sh --trace-id 864ba90806ce1d381024973a3b8f3c3b   # all logs of one trace
#
# Each filter flag is ANDed. Filters map to structured backend filters (a broken/ignored
# filter is a known SigNoz footgun — see signoz/impl.sh); never hand-build a filter string.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: get-logs.sh [filters] [--from <when>] [--to <when>] [--limit <n>] [--raw]

Print log lines matching the given filters, newest first, from the backend
selected by OBSERVABILITY_PROVIDER (signoz). Filters are ANDed; with none, prints
the latest lines in the time window.

Filters:
  --service <name>      service.name (repeat or comma-separate for several: -> matches any).
  --severity <level>    severity_text, e.g. ERROR (comma-separate for several: ERROR,FATAL).
  --env <name>          deployment.environment: local | dev | staging | prod.
  --body-contains <s>   substring match on the log body.
  --trace-id <hex>      all logs emitted under one trace id (correlate with get-trace.sh).

Options:
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

# _csv_to_json CSV -> a JSON string (single value) or JSON array (when comma-separated).
_csv_to_json() {
  case "$1" in
    *,*) printf '%s' "$1" | jq -R 'split(",") | map(select(length > 0))' ;;
    *)   jq -n --arg v "$1" '$v' ;;
  esac
}

service="" severity="" env="" body_contains="" trace_id=""
from="-1h" to="now" limit=100 raw=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) service="${2:-}"; shift 2 ;;
    --severity) severity="${2:-}"; shift 2 ;;
    --env) env="${2:-}"; shift 2 ;;
    --body-contains) body_contains="${2:-}"; shift 2 ;;
    --trace-id) trace_id="${2:-}"; shift 2 ;;
    --from) from="${2:-}"; shift 2 ;;
    --to) to="${2:-}"; shift 2 ;;
    --limit) limit="${2:-}"; shift 2 ;;
    --raw) raw=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ "$to" == "now" ]] && to="$(date +%s)000"
from_ms="$(_to_epoch_ms "$from")"
to_ms="$(_to_epoch_ms "$to")"

# Build the provider-agnostic semantic filter object (only the flags that were given).
filters="$(jq -n \
  --argjson service "$( [[ -n "$service" ]]  && _csv_to_json "$service"  || echo null )" \
  --argjson severity "$( [[ -n "$severity" ]] && _csv_to_json "$severity" || echo null )" \
  --arg env "$env" --arg body "$body_contains" --arg trace "$trace_id" '
  {}
  | (if $service  != null then .service       = $service  else . end)
  | (if $severity != null then .severity      = $severity else . end)
  | (if $env      != ""   then .env           = $env      else . end)
  | (if $body     != ""   then .body_contains = $body     else . end)
  | (if $trace    != ""   then .trace_id      = $trace    else . end)')"

# shellcheck source=lib.sh
. "$DIR/lib.sh"

# PRODUCTION logs carry real player data (an email in an error body, a client ip on a span).
# Record the personal values in keyed-hash form so the tracker / notify adapters can redact
# exactly those values later — and only those, leaving identical-looking local/staging data
# alone. Nothing is recorded for any other --env. See docs/agents/pii-provenance.md.
case "$(printf '%s' "$env" | tr '[:upper:]' '[:lower:]')" in
  prod|production)
    out="$(obs_query_logs "$filters" "$from_ms" "$to_ms" "$limit" "$raw")"
    printf '%s\n' "$out"
    printf '%s' "$out" | python3 "$DIR/../lib/pii_provenance.py" record - >/dev/null 2>&1 || true
    ;;
  *)
    obs_query_logs "$filters" "$from_ms" "$to_ms" "$limit" "$raw"
    ;;
esac
