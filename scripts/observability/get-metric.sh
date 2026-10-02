#!/usr/bin/env bash
# Run a PromQL range query against the configured observability backend.
#
#   ./get-metric.sh --promql 'sum by (service_name) (rate(http_requests_total[5m]))' --from -6h
#   ./get-metric.sh --promql '<q>' --from -6h --summary          # per-series summary, no points
#   ./get-metric.sh --promql '<q>' --from -6h --dry-run          # the request, nothing sent
#
# The query text reaches the backend byte-exact (built with jq --arg, never interpolated), so
# pass it single-quoted and keep PromQL's own escaping: '{__name__=~".*\\.lag_seconds"}'.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: get-metric.sh --promql <query> [--from <when>] [--to <when>] [--step <dur>]
                     [--summary] [--limit-series <n>] [--raw] [--dry-run]

Run a PromQL range query and print JSON:
  {query, window:{from,to,step_s}, series:[{labels, summary, points}]}
  points  = [[<epoch_ms>, <number|null>], ...]  (NaN / +Inf / -Inf become null)
  summary = {current, current_time, peak, peak_time, min, points, trend}, over the
            non-null points; times ISO-8601 UTC. Series sort by summary.peak descending.
  trend   = mean of the first 10% of points vs mean of the last 10% (at least 1 each),
            as a ratio of |peak|: |r| < 0.05 flat, r > 0 rising, else falling.

There is NO --env flag: PromQL carries the environment itself, as a label matcher
({deployment_environment="staging"}) or a `by (...)` label. The adapter never rewrites
the query; a backend parse error is printed verbatim with exit 1.

Options:
  --promql <query>      The PromQL expression (required). Single-quote it.
  --from <when>         Range start: epoch ms/s, relative (-30m/-2h/-7d), or ISO-8601 carrying
                        its offset ('...Z' / '...+07:00'); a bare local time is refused. Default -1h.
  --to <when>           Range end, same formats. Default now.
  --step <dur>          Resolution: 30s / 2m / 1h. Default max(1m, range/300) rounded up to a
                        minute (6h -> 2m). More than 11000 points is refused.
  --summary             Drop `points`; keep labels + summary (context-lean).
  --limit-series <n>    Keep the n highest-peak series (default 50); the rest are counted on stderr.
  --raw                 Print the backend response unparsed.
  --dry-run             Print method, URL, headers (key masked) and body; send nothing.
  -h, --help            Show this help and exit.

Environment:
  OBSERVABILITY_PROVIDER  signoz (default). Provider creds live in .env.
EOF
}

promql="" from="-1h" to="now" step="" summary=0 limit=50 raw=0 dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --promql) promql="${2:-}"; shift 2 ;;
    --from) from="${2:-}"; shift 2 ;;
    --to) to="${2:-}"; shift 2 ;;
    --step) step="${2:-}"; shift 2 ;;
    --summary) summary=1; shift ;;
    --limit-series) limit="${2:-}"; shift 2 ;;
    --raw) raw=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$promql" ]] || { usage; exit 2; }

# shellcheck source=lib.sh
. "$DIR/lib.sh"

from_ms="$(obs_epoch_ms "$from")"
to_ms="$(obs_epoch_ms "$to")"
[[ "$from_ms" -lt "$to_ms" ]] || { echo "error: --from ($from) is not before --to ($to)" >&2; exit 2; }
step_s="$(obs_step_s "$from_ms" "$to_ms" "$step")"

if [[ $dry_run -eq 1 ]]; then OBS_DRY_RUN=1 obs_query_promql "$promql" "$from_ms" "$to_ms" "$step_s"; exit 0; fi
if [[ $raw -eq 1 ]];     then OBS_RAW=1 obs_query_promql "$promql" "$from_ms" "$to_ms" "$step_s"; exit 0; fi

resp="$(obs_query_promql "$promql" "$from_ms" "$to_ms" "$step_s")"
if printf '%s' "$resp" | jq -e 'has("series")' >/dev/null 2>&1; then
  printf '%s' "$resp" | obs_series_report "$promql" "$from_ms" "$to_ms" "$step_s" "$summary" "$limit"
else
  printf '%s\n' "$resp"   # unrecognized shape: raw JSON already noted on stderr by the provider
fi
