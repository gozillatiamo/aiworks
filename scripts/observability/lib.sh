#!/usr/bin/env bash
# Observability adapter — shared dispatch for the tracing/logging scripts.
# Sourced by entry scripts (get-trace.sh, get-logs.sh); not meant to run alone.
#
# Selects a provider implementation by OBSERVABILITY_PROVIDER (signoz) and sources
# scripts/observability/<provider>/impl.sh, which defines the provider interface:
#
#   obs_require_config                                    — validate the provider's env (base url/key), die if missing
#   obs_get_trace TRACE_ID [SPAN_ID]                       — print the trace's span waterfall; SPAN_ID (optional) highlights one span
#   obs_query_logs FILTERS_JSON FROM_MS TO_MS [LIMIT] [RAW] — print log lines matching a semantic filter object in [FROM_MS, TO_MS).
#                                                            FILTERS_JSON is provider-agnostic (any subset of service/severity/env/
#                                                            body_contains/trace_id); the provider impl translates it. RAW=1 -> raw JSON.
#   obs_http METHOD PATH [BODY]                            — the one HTTP path for the metrics/dashboard functions below; key in a
#                                                            header file (never argv); dies `signoz HTTP <code>` on non-2xx;
#                                                            OBS_DRY_RUN=1 prints the request (key masked) and sends nothing
#   obs_query_promql QUERY FROM_MS TO_MS STEP_S            — PromQL range query -> {series:[{query,labels,points:[[ms,n|null]]}]}
#   obs_query_composite CQ_JSON VARS_JSON FROM_MS TO_MS STEP_S — run a widget's own composite query, same output shape
#   obs_list_dashboards                                    — [{id,title,tags,widgets}]
#   obs_get_dashboard ID                                   — {id,title,variables:[{name,default}],widgets:[<raw widget>]}
#   (OBS_RAW=1 makes the query functions print the provider response unparsed.)
#
# Shared here, provider-neutral: obs_epoch_ms, obs_duration_s, obs_step_s, obs_series_report.
#
# Like the vcs/tracker/notify adapters, this reads a git-ignored scripts/observability/.env
# for the provider + secrets (already covered by the workspace's blanket .env / .env.* gitignore
# rule — nothing extra to add there).

set -euo pipefail

OBSERVABILITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load a .env sitting next to these scripts, if present (git-ignored local config).
if [[ -f "$OBSERVABILITY_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$OBSERVABILITY_DIR/.env"
  set +a
fi

die() { echo "error: $*" >&2; exit 1; }
command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required (brew install jq)"

# obs_epoch_ms WHEN -> epoch milliseconds. Accepts `now`, a relative offset (-30m/-2h/-7d),
# epoch seconds or milliseconds, and ISO-8601 **carrying its own offset** (`…Z`, `…+07:00`,
# `…+0700`).
#
# A bare `2026-08-11T15:52:41` is REFUSED, on purpose. `date` would read it in the shell's
# timezone, so under Asia/Bangkok the window silently moved seven hours and the query returned
# a confident, well-formed answer about the wrong hours — the quietest possible bug, and the
# one that made every caller hand-convert with python3 first. Refusing costs one retry with an
# offset; guessing costs a wrong verdict nobody can see is wrong. This lives here, not in each
# entry script, because two copies of a time parser is how one of them stays broken.
obs_epoch_ms() {
  local w="$1" secs norm
  case "$w" in
    now)
      echo "$(( $(date +%s) * 1000 ))"; return ;;
    -*)
      local n unit; n="${w%[mhd]}"; n="${n#-}"; unit="${w: -1}"
      case "$unit" in
        m) secs=$(( $(date +%s) - n*60 )) ;;
        h) secs=$(( $(date +%s) - n*3600 )) ;;
        d) secs=$(( $(date +%s) - n*86400 )) ;;
        *) die "unrecognized relative offset: $w (use -30m / -2h / -7d)" ;;
      esac ;;
    ''|*[!0-9]*)
      norm=""
      case "$w" in
        *Z)                         norm="${w%Z}+0000" ;;
        *[+-][0-9][0-9]:[0-9][0-9]) norm="${w%??:??}${w: -5:2}${w: -2}" ;;
        *[+-][0-9][0-9][0-9][0-9])  norm="$w" ;;
        *)
          echo "refusing an ambiguous time: $w" >&2
          echo "  It names no timezone, and reading it as local time would query the wrong" >&2
          echo "  hours without failing. Pass epoch ms, or add an offset:" >&2
          echo "    '${w}+07:00'   (Asia/Bangkok)      '${w}Z'   (UTC)" >&2
          exit 1 ;;
      esac
      # BSD date wants %z as +0700; GNU date reads the original string, colon and all.
      secs="$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$norm" +%s 2>/dev/null || date -d "$w" +%s 2>/dev/null)" \
        || die "unrecognized time: $w" ;;
    *)
      # All digits: epoch already. 13+ digits is milliseconds, anything shorter is seconds.
      if [[ ${#w} -ge 13 ]]; then printf '%s' "$w"; return 0; fi
      secs="$w" ;;
  esac
  echo "$(( secs * 1000 ))"
}

# obs_duration_s DURATION -> seconds. Accepts 30s / 5m / 2h / 1d.
obs_duration_s() {
  local d="$1" n="${1%[smhd]}" unit="${1: -1}"
  case "$unit" in
    s) echo "$n" ;;
    m) echo $(( n*60 )) ;;
    h) echo $(( n*3600 )) ;;
    d) echo $(( n*86400 )) ;;
    *) die "unrecognized duration: $d (use 30s / 5m / 2h / 1d)" ;;
  esac
}

# obs_step_s FROM_MS TO_MS [STEP] -> the range query's step in seconds. An explicit STEP goes
# through obs_duration_s; the default is max(60, range/300) rounded up to a whole minute (6h
# gives 120s, about 180 points per series). Refuses more than 11000 points (Prometheus' own limit).
obs_step_s() {
  local range_s=$(( ($2 - $1) / 1000 )) step
  if [[ -n "${3:-}" ]]; then
    step="$(obs_duration_s "$3")"
  else
    step=$(( (range_s / 300 + 59) / 60 * 60 ))
    [[ $step -lt 60 ]] && step=60
  fi
  if [[ $(( range_s / step )) -gt 11000 ]]; then
    echo "error: step ${step}s over ${range_s}s is $(( range_s / step )) points (max 11000) — use --step $(( (range_s / 11000 + 59) / 60 * 60 ))s or larger" >&2
    exit 2
  fi
  echo "$step"
}

# obs_series_report QUERY FROM_MS TO_MS STEP_S SUMMARY_ONLY LIMIT — stdin is a provider-normalized
# `{series:[{labels, points:[[ms, number|null]]}]}`; prints the report shape
# `{query, window:{from,to,step_s}, series:[{labels, summary, points}]}` sorted by summary.peak
# descending. SUMMARY_ONLY=1 drops `points`; more than LIMIT series are cut with a stderr note.
#
# summary = {current, current_time, peak, peak_time, min, points, trend} over the NON-null
# points (a NaN/Inf value is null and skipped). trend compares the mean of the first 10% of
# points (at least 1) with the mean of the last 10%, as a ratio of |peak|: |r| < 0.05 flat,
# r > 0 rising, else falling; fewer than 2 points is flat.
obs_series_report() {
  local total
  local input; input="$(cat)"
  total="$(printf '%s' "$input" | jq '.series | length')"
  if [[ "$total" -eq 0 ]]; then echo "note: no series matched the query in this window" >&2; fi
  if [[ "$total" -gt "$6" ]]; then echo "note: $(( total - $6 )) more series not shown (--limit-series $6)" >&2; fi
  printf '%s' "$input" | jq --arg q "$1" --argjson from "$2" --argjson to "$3" --argjson step "$4" \
    --argjson summary_only "$5" --argjson limit "$6" '
    def iso: (. / 1000 | floor | todate);
    def summarize:
      (.points | map(select(.[1] != null))) as $p | ($p | length) as $n
      | if $n == 0 then {current: null, current_time: null, peak: null, peak_time: null, min: null, points: 0, trend: "flat"}
        else ($p | max_by(.[1])) as $pk | ($p | min_by(.[1])) as $mn | $p[-1] as $cur
        | ([($n * 0.1 | ceil), 1] | max) as $k
        | (($p[:$k] | map(.[1]) | add) / $k) as $head
        | (($p[($n - $k):] | map(.[1]) | add) / $k) as $tail
        | ([($pk[1] | fabs), 1e-9] | max) as $den
        | (($tail - $head) / $den) as $r
        | {current: $cur[1], current_time: ($cur[0] | iso), peak: $pk[1], peak_time: ($pk[0] | iso),
           min: $mn[1], points: $n,
           trend: (if $n < 2 or ($r | fabs) < 0.05 then "flat" elif $r > 0 then "rising" else "falling" end)}
        end;
    {query: $q, window: {from: ($from | iso), to: ($to | iso), step_s: $step},
     series: ([.series[] | {labels, summary: summarize, points}]
              | sort_by(.summary.peak // -1e308) | reverse | .[:$limit]
              | if $summary_only == 1 then map(del(.points)) else . end)}'
}

# Which observability backend this workspace uses. Defaults to signoz (the only provider today).
OBSERVABILITY_PROVIDER="${OBSERVABILITY_PROVIDER:-signoz}"
IMPL="$OBSERVABILITY_DIR/$OBSERVABILITY_PROVIDER/impl.sh"
[[ -f "$IMPL" ]] || die "unknown OBSERVABILITY_PROVIDER '$OBSERVABILITY_PROVIDER' (no $IMPL) — use 'signoz', or add an impl.sh under scripts/observability/$OBSERVABILITY_PROVIDER/"

# shellcheck disable=SC1090
. "$IMPL"
obs_require_config
