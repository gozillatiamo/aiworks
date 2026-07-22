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
#   POST {base}/api/v4/query_range        — builder query, dataSource=logs, filter.expression=QUERY
# These are query-service's stable OSS routes as of SigNoz v0.55+; if your instance is on an
# older/newer build and a call 404s, check that instance's /api docs and adjust the path below.

obs_require_config() {
  [[ -n "${SIGNOZ_BASE_URL:-}" ]] || die "signoz observability needs SIGNOZ_BASE_URL in scripts/observability/.env"
  [[ -n "${SIGNOZ_API_KEY:-}"  ]] || die "signoz observability needs SIGNOZ_API_KEY in scripts/observability/.env"
  SIGNOZ_AUTH_HEADER="${SIGNOZ_AUTH_HEADER:-SIGNOZ-API-KEY}"
  SIGNOZ_BASE_URL="${SIGNOZ_BASE_URL%/}"
}

# obs_get_trace TRACE_ID [SPAN_ID] -> prints the span waterfall (indented by call depth),
# marking SPAN_ID (if given) with "→". Falls back to pretty raw JSON if the response shape
# doesn't match what's expected (e.g. a SigNoz version with a different payload).
obs_get_trace() {
  local trace_id="$1" span_id="${2:-}" resp

  resp="$(curl -sS -H "${SIGNOZ_AUTH_HEADER}: ${SIGNOZ_API_KEY}" \
    "${SIGNOZ_BASE_URL}/api/v1/traces/${trace_id}")" || die "signoz request failed (network)"

  if printf '%s' "$resp" | jq -e '.error' >/dev/null 2>&1; then
    die "signoz rejected the request: $(printf '%s' "$resp" | jq -r '.error')"
  fi

  local spans
  spans="$(printf '%s' "$resp" | jq -c '
    (.data.spans // .data // empty) | if type == "array" then . else empty end
  ' 2>/dev/null)"

  if [[ -z "$spans" || "$spans" == "empty" ]]; then
    echo "note: unrecognized response shape — printing raw JSON" >&2
    printf '%s' "$resp" | jq '.'
    return 0
  fi

  printf '%s' "$resp" | jq -r --arg mark "$span_id" '
    (.data.spans // .data) as $spans
    | ($spans | map({(.spanID // .spanId // .id): (.parentSpanID // .parentSpanId // .references[0].spanID // "")}) | add // {}) as $parents
    | def depth(id; seen):
        if (id == null or id == "" or ($parents[id] // "") == "" or (seen | index(id)))
        then (seen | length)
        else depth($parents[id]; seen + [id])
        end;
    $spans
    | sort_by(.startTimeUnixNano // .startTime // 0)
    | .[]
    | . as $s
    | ($s.spanID // $s.spanId // $s.id // "") as $id
    | (depth($id; []) ) as $d
    | ($s.durationNano // ($s.duration * 1000) // 0) as $durNano
    | (if $id == $mark and $mark != "" then "→ " else "  " end) as $prefix
    | "\($prefix)" + ("  " * $d) +
      "\($s.name // $s.operationName // "?") " +
      "[\($s.serviceName // $s.resource.\"service.name\" // "?")] " +
      "\(($durNano/1000000)|tostring)ms " +
      "\($s.statusCode // $s.status.code // "")" +
      (if $id == $mark and $mark != "" then "  <-- requested spanId" else "" end)
  '
}

# obs_query_logs QUERY FROM_MS TO_MS [LIMIT] -> prints matching log lines, newest first.
# QUERY is a SigNoz filter expression, e.g.: service.name = 'agent-webservice' AND severity_text = 'ERROR'
obs_query_logs() {
  local query="$1" from_ms="$2" to_ms="$3" limit="${4:-100}" body resp

  body="$(jq -n \
    --argjson start "$from_ms" --argjson end "$to_ms" --argjson limit "$limit" --arg expr "$query" '
    {
      start: $start, end: $end, step: 60,
      compositeQuery: {
        queryType: "builder", panelType: "list",
        builderQueries: {
          A: {
            dataSource: "logs", queryName: "A", aggregateOperator: "noop",
            expression: "A", disabled: false, limit: $limit,
            filter: { expression: $expr },
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

  local rows
  rows="$(printf '%s' "$resp" | jq -c '[.. | objects | select(has("timestamp") and (has("body") or has("data")))] // []' 2>/dev/null)"

  if [[ -z "$rows" || "$rows" == "[]" ]]; then
    echo "note: unrecognized response shape — printing raw JSON" >&2
    printf '%s' "$resp" | jq '.'
    return 0
  fi

  printf '%s' "$rows" | jq -r '.[] | "\(.timestamp)  \(.severity_text // .data.severity_text // "")  \(.body // .data.body // .)"'
}
