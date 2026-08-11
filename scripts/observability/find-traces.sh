#!/usr/bin/env bash
#
# find-traces.sh — SEARCH and COUNT traces, instead of being handed one trace id.
#
# get-trace.sh answers "what happened in this request". This answers the question that has to come
# first: "how often does this happen, and when?" — the BASE RATE. A single failing trace tells you
# almost nothing on its own; the same failure counted over a week, bucketed by hour, tells you
# whether it is a one-off, a steady leak, or a burst that lines up with something else.
#
# Three modes over the same filters:
#   (default)      one number — how many traces match
#   --by <key>     a breakdown — which routes/services/hosts carry the failures
#   --interval <d> a time series — WHEN they happen, which is what exposes clustering
#   --list         sample trace ids, to hand to get-trace.sh
#
# Usage:
#   find-traces.sh [filters] [--by <key>] [--interval 1h] [--list] [--since 7d] [--limit 20] [--raw]
#
#   --service <name>    span's service (e.g. APISIX, agent-webservice)
#   --status <code>     HTTP response status (e.g. 502)
#   --error             only spans marked as errors
#   --operation <name>  span name / operation
#   --tag k=v           any span attribute; repeatable (e.g. --tag http.target=/AMBPG/PGSOFT/settleBets)
#   --min-duration <ms> only spans slower than this
#   --since <when>      -Nm/-Nh/-Nd, epoch ms, or ISO-8601 CARRYING ITS OFFSET. Default -7d.
#   --until <when>      same formats. Default now.
#   --by <key>          group the count by a span attribute
#   --interval <dur>    bucket the count over time (30m, 1h, 6h, 1d)
#   --list              return matching trace ids instead of a count
#
# Time is unambiguous or refused. `2026-08-10T22:00:00+07:00` and `2026-08-10T15:00:00Z` are both
# accepted and mean the same instant; a bare `2026-08-10T22:00:00` is REJECTED rather than read as
# whatever the shell's timezone happens to be. This used to be read as local time, which is the
# quietest possible bug: SigNoz stores UTC, so passing a trace's own clock time back verbatim
# shifted the window (seven hours, under Asia/Bangkok) and returned a confident, well-formed
# answer about the wrong hours. Epoch ms remains the option that cannot be misread.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

usage() { sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

SERVICE=""; STATUS=""; OPERATION=""; ONLY_ERR=0; MIN_MS=""
SINCE="-7d"; UNTIL="now"; BY=""; INTERVAL=""; LIST=0; LIMIT=20; RAW=0
TAGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)      SERVICE="${2:-}"; shift 2 ;;
    --status)       STATUS="${2:-}"; shift 2 ;;
    --operation)    OPERATION="${2:-}"; shift 2 ;;
    --error)        ONLY_ERR=1; shift ;;
    --tag)          TAGS+=("${2:-}"); shift 2 ;;
    --min-duration) MIN_MS="${2:-}"; shift 2 ;;
    --since|--from) SINCE="${2:-}"; shift 2 ;;
    --until|--to)   UNTIL="${2:-}"; shift 2 ;;
    --by|--group-by) BY="${2:-}"; shift 2 ;;
    --interval)     INTERVAL="${2:-}"; shift 2 ;;
    --list)         LIST=1; shift ;;
    --limit)        LIMIT="${2:-}"; shift 2 ;;
    --raw)          RAW=1; shift ;;
    -h|--help)      usage 0 ;;
    *)              echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

obs_require_config

# --- time -----------------------------------------------------------------------------------
_epoch_ms() {
  local w="$1" secs
  case "$w" in
    now) echo "$(( $(date +%s) * 1000 ))"; return ;;
    -*)  local n unit; n="${w%[mhd]}"; n="${n#-}"; unit="${w: -1}"
         case "$unit" in
           m) secs=$(( $(date +%s) - n*60 )) ;;
           h) secs=$(( $(date +%s) - n*3600 )) ;;
           d) secs=$(( $(date +%s) - n*86400 )) ;;
           *) echo "unrecognized offset: $w" >&2; exit 1 ;;
         esac ;;
    ''|*[!0-9]*)
         # An ISO-8601 timestamp is honoured only when it names its own offset. Without one there
         # is no correct reading — `date` would apply the shell's zone, which is how a window
         # silently moves seven hours — so this refuses instead of guessing.
         local norm=""
         case "$w" in
           *Z)                       norm="${w%Z}+0000" ;;
           *[+-][0-9][0-9]:[0-9][0-9]) norm="${w%??:??}${w: -5:2}${w: -2}" ;;
           *[+-][0-9][0-9][0-9][0-9]) norm="$w" ;;
           *) echo "refusing an ambiguous time: $w" >&2
              echo "  It names no timezone, and reading it as local time would query the wrong" >&2
              echo "  hours without failing. Pass epoch ms, or add an offset:" >&2
              echo "    --since '${w}+07:00'   (Asia/Bangkok)   --since '${w}Z'   (UTC)" >&2
              exit 1 ;;
         esac
         # BSD date wants %z as +0700; GNU date reads the original string, colon and all.
         secs="$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$norm" +%s 2>/dev/null || date -d "$w" +%s 2>/dev/null)" \
           || { echo "unrecognized time: $w" >&2; exit 1; } ;;
    *)   echo "$w"; return ;;   # already epoch ms
  esac
  echo "$(( secs * 1000 ))"
}
_dur_s() {
  local d="$1" n="${1%[mhd]}" unit="${1: -1}"
  case "$unit" in m) echo $(( n*60 )) ;; h) echo $(( n*3600 )) ;; d) echo $(( n*86400 )) ;;
    *) echo "unrecognized interval: $d" >&2; exit 1 ;; esac
}

START="$(_epoch_ms "$SINCE")"; END="$(_epoch_ms "$UNTIL")"
STEP=60; [[ -n "$INTERVAL" ]] && STEP="$(_dur_s "$INTERVAL")"

# --- filters --------------------------------------------------------------------------------
# SigNoz promotes some span attributes to first-class columns; everything else is a plain tag.
# Getting isColumn wrong yields an empty result rather than an error, so the set is explicit.
_is_column() {
  case "$1" in
    serviceName|responseStatusCode|httpRoute|httpUrl|httpHost|httpMethod|name|durationNano|hasError) echo true ;;
    *) echo false ;;
  esac
}
# SigNoz also type-checks the key: a NUMERIC column declared as a string is rejected outright with
# "error in builder queries", which is what made --min-duration fail on every invocation. The
# dataType is therefore looked up, not assumed.
_data_type() {
  case "$1" in
    durationNano) echo float64 ;;
    *)            echo string ;;
  esac
}
_key_json() { jq -n --arg k "$1" --arg d "$(_data_type "$1")" --argjson c "$(_is_column "$1")" \
  '{key:$k,dataType:$d,type:(if $c then "tag" else "tag" end),isColumn:$c}'; }

items="[]"
_add() {  # key op value
  items="$(jq -c --argjson k "$(_key_json "$1")" --arg op "$2" --arg v "$3" \
    '. + [{key:$k, op:$op, value:$v}]' <<<"$items")"
}
[[ -n "$SERVICE"   ]] && _add serviceName        "=" "$SERVICE"
[[ -n "$STATUS"    ]] && _add responseStatusCode "=" "$STATUS"
[[ -n "$OPERATION" ]] && _add name               "=" "$OPERATION"
[[ $ONLY_ERR -eq 1 ]] && _add hasError           "=" "true"
if [[ -n "$MIN_MS" ]]; then
  items="$(jq -c --argjson k "$(_key_json durationNano)" --arg v "$(( MIN_MS * 1000000 ))" \
    '. + [{key:$k, op:">=", value:($v|tonumber)}]' <<<"$items")"
fi
for t in "${TAGS[@]}"; do
  [[ "$t" == *=* ]] || { echo "--tag needs key=value, got: $t" >&2; exit 1; }
  _add "${t%%=*}" "=" "${t#*=}"
done

# --- query ----------------------------------------------------------------------------------
SELECT="[]"
if [[ $LIST -eq 1 ]]; then
  PANEL="list"; AGG="noop"; GROUP="[]"
  # panelType "list" is rejected outright without selectColumns — the fields to bring back.
  SELECT="$(jq -c -n '[ "traceID", "serviceName", "name", "responseStatusCode", "durationNano" ]
    | map({key:., dataType:"string", type:"tag", isColumn:true})')"
else
  PANEL="table"; AGG="count"; GROUP="[]"
  [[ -n "$INTERVAL" ]] && PANEL="graph"
  [[ -n "$BY" ]] && GROUP="$(jq -c -n --argjson k "$(_key_json "$BY")" '[$k]')"
fi

body="$(jq -n --argjson s "$START" --argjson e "$END" --argjson step "$STEP" \
  --argjson items "$items" --argjson group "$GROUP" --argjson limit "$LIMIT" \
  --argjson select "$SELECT" --arg panel "$PANEL" --arg agg "$AGG" '
  { start:$s, end:$e, step:$step,
    compositeQuery: { queryType:"builder", panelType:$panel,
      builderQueries: { A: {
        dataSource:"traces", queryName:"A", aggregateOperator:$agg,
        expression:"A", disabled:false, stepInterval:$step, limit:$limit,
        filters:{ op:"AND", items:$items }, groupBy:$group, selectColumns:$select,
        orderBy:[{columnName:"timestamp", order:"desc"}]
      } } } }')"

resp="$(curl -sS -X POST -H "${SIGNOZ_AUTH_HEADER}: ${SIGNOZ_API_KEY}" -H 'Content-Type: application/json' \
  --data "$body" "${SIGNOZ_BASE_URL}/api/v4/query_range")" || { echo "signoz request failed" >&2; exit 1; }

if jq -e '.error' >/dev/null 2>&1 <<<"$resp"; then
  echo "signoz rejected the request: $(jq -r '.error' <<<"$resp")" >&2; exit 1
fi
[[ $RAW -eq 1 ]] && { printf '%s\n' "$resp"; exit 0; }

# --- render ---------------------------------------------------------------------------------
# The response goes through a file, not stdin: a `<<<` on the same command as the `<<'PY'`
# heredoc replaces the script itself, and python then tries to execute the JSON.
RESP_FILE="$(mktemp)"; printf '%s' "$resp" > "$RESP_FILE"
trap 'rm -f "$RESP_FILE"' EXIT
BY="$BY" LIST="$LIST" INTERVAL="$INTERVAL" RESP_FILE="$RESP_FILE" \
  SPAN_BUCKETS="$(( (END - START) / 1000 / STEP ))" python3 - <<'PY'
import json, os, sys, datetime
d = json.load(open(os.environ["RESP_FILE"]))
res = (d.get("data", {}) or {}).get("result") or []
by, listing, interval = os.environ.get("BY"), os.environ.get("LIST") == "1", os.environ.get("INTERVAL")
if not res:
    print("no matching traces"); raise SystemExit
r = res[0]

if listing:
    rows = r.get("list") or []
    print(f"{len(rows)} trace(s)")
    for x in rows:
        c = x.get("data", {})
        print(f"  {x.get('timestamp','')[:23]}  {c.get('traceID') or c.get('traceId','')}  "
              f"{c.get('serviceName','')}  {c.get('responseStatusCode','')}  {c.get('name','')}")
    raise SystemExit

series = r.get("series") or []
if not series:
    print("0 matching traces"); raise SystemExit

if interval:
    # One line per bucket that actually has traces. Empty buckets are the signal for clustering,
    # so the count of non-empty buckets is printed rather than every zero.
    # SigNoz omits empty buckets, so the denominator has to come from the requested range —
    # counting only what came back would make every result look evenly spread.
    total_buckets = max(int(os.environ.get("SPAN_BUCKETS", "0")), 1)
    hot = [(v["timestamp"], float(v["value"])) for s in series for v in s["values"] if float(v["value"]) > 0]
    total = sum(v for _, v in hot)
    print(f"total={int(total)}   buckets_with_traces={len(hot)}/{total_buckets}   interval={interval}")
    for t, v in sorted(hot, key=lambda x: -x[1])[:20]:
        stamp = datetime.datetime.fromtimestamp(t / 1000, datetime.timezone.utc)
        print(f"  {stamp:%Y-%m-%d %H:%M}Z  {int(v)}")
    if len(hot) <= total_buckets * 0.25:
        share = sum(v for _, v in sorted(hot, key=lambda x: -x[1])[:3]) / total * 100 if total else 0
        print(f"\n  CLUSTERED — {len(hot)} of {total_buckets} buckets carry any traces at all, and the")
        print(f"  top 3 carry {share:.0f}% of them. This is a burst, not a steady rate.")
        print("  Correlate the hot buckets against deploys, pod replacements and node events before")
        print("  theorising about request content.")
    else:
        print(f"\n  SPREAD — traces appear in {len(hot)} of {total_buckets} buckets. A cause tied to a")
        print("  one-off event (a deploy, an eviction) does not explain a steady rate.")
elif by:
    rows = sorted((((s["labels"].get(by) or "(unset)"), float(s["values"][0]["value"])) for s in series),
                  key=lambda x: -x[1])
    print(f"total={int(sum(v for _, v in rows))}   grouped by {by}")
    for k, v in rows[:25]:
        print(f"  {int(v):>8}  {k[:90]}")
    if len(rows) == 1 and rows[0][0] == "(unset)":
        print(f"\n  '{by}' is empty on every matching span — this attribute is not populated by")
        print("  that emitter. Try a different key (e.g. a raw tag like http.target).")
else:
    print(int(sum(float(v["value"]) for s in series for v in s["values"])))
PY
