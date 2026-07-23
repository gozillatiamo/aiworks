#!/usr/bin/env bash
# SigNoz implementation of the observability interface. Sourced by ../lib.sh.
#
# Auth: every request sends the API key in the header named by SIGNOZ_AUTH_HEADER
# (default SIGNOZ-API-KEY — SigNoz's Personal Access Token header). If your instance
# gates the query-service behind a different header (e.g. a reverse-proxy bearer token),
# override SIGNOZ_AUTH_HEADER in .env.
#
# Endpoints used (query-service HTTP API):
#   GET  {base}/api/v1/traces/{traceId}   — full span waterfall for one trace
#   POST {base}/api/v4/query_range        — builder query, dataSource=logs, STRUCTURED filters
# These are query-service's stable OSS routes as of SigNoz v0.55+; if your instance is on an
# older/newer build and a call 404s, check that instance's /api docs and adjust the path below.
#
# ⚠️ Filtering MUST use the structured `filters: {op, items:[...]}` builder form, NOT the
# free-text `filter: {expression}` form. This instance SILENTLY IGNORES a free-text expression
# — a query for severity_text='ERROR' returns INFO/WARN rows too, and service.name='x' returns
# other services — so a broken filter looks like "no matching logs / wrong logs" rather than an
# error. Each semantic filter maps to one item: resource attributes (service.name,
# deployment.environment) carry type:"resource",isColumn:false; log columns (severity_text,
# body, trace_id) carry type:"",isColumn:true. Verified filtering live 2026-07-22.

obs_require_config() {
  [[ -n "${SIGNOZ_BASE_URL:-}" ]] || die "signoz observability needs SIGNOZ_BASE_URL in scripts/observability/.env"
  [[ -n "${SIGNOZ_API_KEY:-}"  ]] || die "signoz observability needs SIGNOZ_API_KEY in scripts/observability/.env"
  SIGNOZ_AUTH_HEADER="${SIGNOZ_AUTH_HEADER:-SIGNOZ-API-KEY}"
  SIGNOZ_BASE_URL="${SIGNOZ_BASE_URL%/}"
}

# obs_get_trace TRACE_ID [SPAN_ID] -> prints the span waterfall (indented by call depth),
# marking SPAN_ID (if given) with "->". Falls back to pretty raw JSON if the response shape
# doesn't match what's expected (e.g. a SigNoz version with a different payload).
#
# GET /api/v1/traces/{id} returns a columnar shape: [{"columns":[...],"events":[[...],...]}],
# each row a positional array matching `columns` (SpanId, ServiceName, Name, DurationNano,
# References, HasError, StatusCodeString, ...). `References` is a stringified struct like
# "{TraceId=.., SpanId=<parentId>, RefType=CHILD_OF}" (empty SpanId = root span) — parsed
# below to build the parent-child tree for indentation.
obs_get_trace() {
  local trace_id="$1" span_id="${2:-}" resp

  resp="$(curl -sS -H "${SIGNOZ_AUTH_HEADER}: ${SIGNOZ_API_KEY}" \
    "${SIGNOZ_BASE_URL}/api/v1/traces/${trace_id}")" || die "signoz request failed (network)"

  if printf '%s' "$resp" | jq -e 'type == "object" and has("error")' >/dev/null 2>&1; then
    die "signoz rejected the request: $(printf '%s' "$resp" | jq -r '.error.message // .error')"
  fi

  if ! printf '%s' "$resp" | jq -e '(.[0].columns? and .[0].events?) // false' >/dev/null 2>&1; then
    echo "note: unrecognized response shape — printing raw JSON" >&2
    printf '%s' "$resp" | jq '.'
    return 0
  fi

  printf '%s' "$resp" | jq -r --arg mark "$span_id" '
    .[0] as $t
    | ($t.columns) as $cols
    | ($t.events | map( . as $row | [$cols, $row] | transpose | map({(.[0]): .[1]}) | add )) as $spans
    | ($spans | map({(.SpanId): ( (.References[0] // "") | capture("SpanId=(?<p>[a-f0-9]*)").p // "" ) }) | add) as $parents
    | def depth(id; seen):
        if (id == null or id == "" or ($parents[id] // "") == "" or (seen | index(id)))
        then (seen | length)
        else depth($parents[id]; seen + [id])
        end;
    $spans
    | sort_by(.__time)
    | .[]
    | . as $s
    | (depth($s.SpanId; [])) as $d
    | (if $s.SpanId == $mark and $mark != "" then "-> " else "   " end) as $prefix
    | "\($prefix)" + ("  " * $d) +
      "\($s.Name) [\($s.ServiceName)] \(($s.DurationNano | tonumber) / 1000000)ms \($s.StatusCodeString)" +
      (if $s.HasError == "true" then " ERROR: \($s.StatusMessage)" else "" end) +
      (if $s.SpanId == $mark and $mark != "" then "  <-- requested spanId" else "" end)
  '
}

# obs_query_logs FILTERS_JSON FROM_MS TO_MS [LIMIT] [RAW] -> prints matching log lines, newest first.
#
# FILTERS_JSON is a provider-agnostic SEMANTIC filter object built by get-logs.sh — any subset of:
#   { "service": "x" | ["a","b"],   "severity": "ERROR" | ["ERROR","FATAL"],
#     "env": "staging",   "body_contains": "timeout",   "trace_id": "<hex>" }
# It is translated below into SigNoz's structured filters.items (see the ⚠️ note at the top of this
# file for why the free-text expression form is unusable). An empty object ({}) filters nothing —
# just the time window. RAW=1 prints the raw JSON response instead of parsed lines.
obs_query_logs() {
  local filters="$1" from_ms="$2" to_ms="$3" limit="${4:-100}" raw="${5:-0}" items body resp

  # Semantic filters -> SigNoz filters.items. Scalars use "="/"contains"; arrays use "in".
  items="$(printf '%s' "$filters" | jq -c '
    def col(k): {key:{key:k,dataType:"string",type:"",isColumn:true}};
    def res(k): {key:{key:k,dataType:"string",type:"resource",isColumn:false}};
    def eq(base; v): if (v|type)=="array" then (base + {op:"in", value:v}) else (base + {op:"=", value:v}) end;
    [
      (if .service       then eq(res("service.name"); .service) else empty end),
      (if .env           then res("deployment.environment") + {op:"=", value:.env} else empty end),
      (if .severity      then eq(col("severity_text"); .severity) else empty end),
      (if .body_contains then col("body") + {op:"contains", value:.body_contains} else empty end),
      (if .trace_id      then col("trace_id") + {op:"=", value:.trace_id} else empty end)
    ]')"

  body="$(jq -n \
    --argjson start "$from_ms" --argjson end "$to_ms" --argjson limit "$limit" --argjson items "$items" '
    {
      start: $start, end: $end, step: 60,
      compositeQuery: {
        queryType: "builder", panelType: "list",
        builderQueries: {
          A: {
            dataSource: "logs", queryName: "A", aggregateOperator: "noop",
            expression: "A", disabled: false, limit: $limit,
            filters: { op: "AND", items: $items },
            orderBy: [{ columnName: "timestamp", order: "desc" }]
          }
        }
      }
    }')"

  resp="$(curl -sS -X POST -H "${SIGNOZ_AUTH_HEADER}: ${SIGNOZ_API_KEY}" -H 'Content-Type: application/json' \
    --data "$body" "${SIGNOZ_BASE_URL}/api/v4/query_range")" || die "signoz request failed (network)"

  if printf '%s' "$resp" | jq -e '.error' >/dev/null 2>&1; then
    die "signoz rejected the request: $(printf '%s' "$resp" | jq -r '.error')"
  fi

  if [[ "$raw" -eq 1 ]]; then
    printf '%s' "$resp" | jq '.'
    return 0
  fi

  local rows
  rows="$(printf '%s' "$resp" | jq -c '[.. | objects | select(has("timestamp") and (has("body") or has("data")))] // []' 2>/dev/null)"

  if [[ -z "$rows" || "$rows" == "[]" ]]; then
    echo "note: no logs matched (filters + time window), or unrecognized response shape — raw JSON:" >&2
    printf '%s' "$resp" | jq '.'
    return 0
  fi

  printf '%s' "$rows" | jq -r '.[] | "\(.timestamp)  \(.severity_text // .data.severity_text // "")  \(.body // .data.body // .)"'
}
