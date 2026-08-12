#!/usr/bin/env bash
# Query logs from the configured observability backend.
#
#   ./get-logs.sh --service your-service --severity ERROR --env staging
#   ./get-logs.sh --env prod --body-contains 'timeout' --from -30m
#   ./get-logs.sh --trace-id 864ba90806ce1d381024973a3b8f3c3b   # all logs of one trace
#
#   # A case is reported at a wall-clock instant — pass it with its own offset, not a
#   # hand-computed epoch, and let --window bracket it:
#   ./get-logs.sh --env prod --at '2026-03-04T22:52:41+07:00' --window 10m --body-contains '<entity-id>'
#
#   # Two identifiers, one round-trip (each is queried and the results merged, newest first):
#   ./get-logs.sh --env prod --body-contains '<id-a>' --body-contains '<id-b>' --from -6h
#
# Each filter flag is ANDed. Filters map to structured backend filters (a broken/ignored
# filter is a known SigNoz footgun — see signoz/impl.sh); never hand-build a filter string.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: get-logs.sh [filters] [--from <when>|--at <when>] [--to <when>] [--window <dur>]
                   [--limit <n>] [--raw]

Print log lines matching the given filters, newest first, from the backend
selected by OBSERVABILITY_PROVIDER (signoz). Filters are ANDed; with none, prints
the latest lines in the time window.

Filters:
  --service <name>      service.name (repeat or comma-separate for several: -> matches any).
  --severity <level>    severity_text, e.g. ERROR (comma-separate for several: ERROR,FATAL).
  --env <name>          deployment.environment: local | dev | staging | prod.
  --body-contains <s>   substring match on the log body. REPEATABLE: each value is queried
                        separately and the results are merged newest-first, because the
                        backend ANDs filter items and cannot OR two substrings in one query.
  --trace-id <hex>      all logs emitted under one trace id (correlate with get-trace.sh).

Time:
  --from <when>    Range start: epoch ms/s, a relative offset (-30m/-2h/-7d), or ISO-8601
                   CARRYING ITS OFFSET ('...Z' or '...+07:00'). Default: -1h.
  --to <when>      Range end, same formats. Default: now.
  --at <when>      An instant to bracket instead of a range: sets the range to
                   [at - window, at + window]. Cannot be combined with --from/--to.
  --window <dur>   Half-width for --at: 30s / 5m / 2h / 1d. Default: 5m.

  A bare '2026-08-11T15:52:41' is REFUSED, not read as local time — see obs_epoch_ms in
  lib.sh for why that refusal exists.

Options:
  --limit <n>      Max rows (default 100). With several --body-contains, applied after merge.
  --raw            Print the raw JSON response instead of parsed log lines.
                   Not available with several --body-contains (the responses cannot be
                   concatenated into one valid document).
  -h, --help       Show this help and exit.

Environment:
  OBSERVABILITY_PROVIDER  signoz (default). Provider creds live in .env.
EOF
}

# _csv_to_json CSV -> a JSON string (single value) or JSON array (when comma-separated).
_csv_to_json() {
  case "$1" in
    *,*) printf '%s' "$1" | jq -R 'split(",") | map(select(length > 0))' ;;
    *)   jq -n --arg v "$1" '$v' ;;
  esac
}

service="" severity="" env="" trace_id=""
from="-1h" to="now" limit=100 raw=0
at="" window="5m" from_set=0 to_set=0
# Newline-separated rather than an array: an empty indexed array expanded under `set -u` is a
# bash 3.2 landmine, and macOS ships 3.2.
bodies=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) service="${2:-}"; shift 2 ;;
    --severity) severity="${2:-}"; shift 2 ;;
    --env) env="${2:-}"; shift 2 ;;
    --body-contains) bodies="${bodies}${2:-}"$'\n'; shift 2 ;;
    --trace-id) trace_id="${2:-}"; shift 2 ;;
    --from) from="${2:-}"; from_set=1; shift 2 ;;
    --to) to="${2:-}"; to_set=1; shift 2 ;;
    --at) at="${2:-}"; shift 2 ;;
    --window) window="${2:-}"; shift 2 ;;
    --limit) limit="${2:-}"; shift 2 ;;
    --raw) raw=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

# --- time ------------------------------------------------------------------------------------
if [[ -n "$at" ]]; then
  if [[ $from_set -eq 1 || $to_set -eq 1 ]]; then
    die "--at brackets an instant and cannot be combined with --from/--to"
  fi
  at_ms="$(obs_epoch_ms "$at")"
  half_ms=$(( $(obs_duration_s "$window") * 1000 ))
  from_ms=$(( at_ms - half_ms ))
  to_ms=$(( at_ms + half_ms ))
else
  from_ms="$(obs_epoch_ms "$from")"
  to_ms="$(obs_epoch_ms "$to")"
fi

# --- filters ---------------------------------------------------------------------------------
# Build the provider-agnostic semantic filter object (only the flags that were given).
_filters_for() {  # $1 = body substring, possibly empty
  jq -n \
    --argjson service "$( [[ -n "$service" ]]  && _csv_to_json "$service"  || echo null )" \
    --argjson severity "$( [[ -n "$severity" ]] && _csv_to_json "$severity" || echo null )" \
    --arg env "$env" --arg body "$1" --arg trace "$trace_id" '
    {}
    | (if $service  != null then .service       = $service  else . end)
    | (if $severity != null then .severity      = $severity else . end)
    | (if $env      != ""   then .env           = $env      else . end)
    | (if $body     != ""   then .body_contains = $body     else . end)
    | (if $trace    != ""   then .trace_id      = $trace    else . end)'
}

body_count="$(printf '%s' "$bodies" | grep -c . || true)"
[[ -z "$body_count" ]] && body_count=0

if [[ "$body_count" -gt 1 && $raw -eq 1 ]]; then
  die "--raw prints one backend response verbatim; with several --body-contains there are $body_count of them. Re-run with a single --body-contains, or drop --raw."
fi

if [[ "$body_count" -le 1 ]]; then
  # Single query — the common path, byte-for-byte the previous behaviour.
  out="$(obs_query_logs "$(_filters_for "$(printf '%s' "$bodies" | tr -d '\n')")" \
         "$from_ms" "$to_ms" "$limit" "$raw")"
else
  # One query per substring, merged. The backend ANDs its filter items, so two `contains` on
  # the same column cannot be ORed in a single request (signoz/impl.sh) — N requests is the
  # only faithful translation, and it still costs the caller one command.
  #
  # Parsed lines start with the timestamp, so a reverse lexical sort restores newest-first
  # across the merged set. A log body containing a newline would sort its continuation lines
  # separately; that is the known cost of merging text rather than JSON.
  # Only log-shaped lines survive the merge. A sub-query that matched nothing prints a
  # human-readable note ("no logs matched …") instead of rows, and merging that verbatim put a
  # diagnostic at the TOP of the results — sort -r ranks 'note:' above any digit — where it
  # reads exactly like data. So each sub-query is filtered to lines starting with an ISO
  # timestamp, and the no-match note is re-emitted once, at the end, only if nothing matched.
  # A sub-query that matched nothing is EXPECTED here — that is the whole point of asking for
  # several substrings — and it says so on stderr. Printing one such note per value next to a
  # perfectly good merged result set reads as failure, so each sub-query's stderr is held back
  # and discarded when it exits 0, and surfaced verbatim when it does not. Suppressing stderr
  # outright would also swallow an auth or backend rejection.
  merged="" chunk="" err_f=""
  err_f="$(mktemp)"; trap 'rm -f "$err_f"' EXIT
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    if ! chunk="$(obs_query_logs "$(_filters_for "$b")" "$from_ms" "$to_ms" "$limit" 0 2>"$err_f")"; then
      cat "$err_f" >&2
      die "backend query failed for --body-contains '$b'"
    fi
    merged="${merged}$(printf '%s\n' "$chunk" \
      | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' || true)"$'\n'
  done <<EOF
$bodies
EOF
  out="$(printf '%s' "$merged" | grep -v '^$' | sort -ru | head -n "$limit" || true)"
  if [[ -z "$out" ]]; then
    out="note: no logs matched any of the $body_count --body-contains values in this window."
  fi
fi

# PRODUCTION logs carry real player data (an email in an error body, a client ip on a span).
# Record the personal values in keyed-hash form so the tracker / notify adapters can redact
# exactly those values later — and only those, leaving identical-looking local/staging data
# alone. Nothing is recorded for any other --env. See docs/agents/pii-provenance.md.
printf '%s\n' "$out"
case "$(printf '%s' "$env" | tr '[:upper:]' '[:lower:]')" in
  prod|production)
    printf '%s' "$out" | python3 "$DIR/../lib/pii_provenance.py" record - >/dev/null 2>&1 || true
    ;;
esac
