#!/usr/bin/env bash
#
# Hermetic regression for the observability adapter's metrics + dashboard scripts.
#
# No network, no credentials, no .env: the adapter directory is COPIED into a temp dir (so the
# real git-ignored .env beside the scripts is never sourced), the provider env is a fake
# (SIGNOZ_BASE_URL=http://signoz.test, SIGNOZ_API_KEY=k-test), and a fake `curl` first on PATH
# records what the scripts would have sent and serves a fixture chosen by URL path.
#
# Run:  scripts/observability/selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0

ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
# ck NAME EXPECTED ACTUAL
ck()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected: $2 | got: $3"; fi; }

# --- sandbox -----------------------------------------------------------------------------------
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
OBS="$T/observability"; mkdir -p "$OBS" "$T/bin" "$T/fx"
cp "$SRC"/*.sh "$OBS/"; cp -R "$SRC/signoz" "$OBS/signoz"   # scripts only — never .env
export SIGNOZ_BASE_URL=http://signoz.test SIGNOZ_API_KEY=k-test FAKE_DIR="$T/fx"
unset OBSERVABILITY_PROVIDER SIGNOZ_AUTH_HEADER

# Fake curl: appends its argv to $FAKE_DIR/argv.log, saves the --data body to
# $FAKE_DIR/body.json, and answers with $FAKE_DIR/<path with / as _>.json (+ .code, default
# 200). With -w present it appends "\n<code>", like the real `-w '\n%{http_code}'`.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/argv.log"
url="" w=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data) printf '%s' "$2" > "$FAKE_DIR/body.json"; shift 2 ;;
    -w) w=1; shift 2 ;;
    -H|-X) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
name="${url#http://signoz.test/}"; name="${name//\//_}"
if [[ -f "$FAKE_DIR/$name.json" ]]; then
  cat "$FAKE_DIR/$name.json"; code="$(cat "$FAKE_DIR/$name.code" 2>/dev/null || echo 200)"
else
  printf 'not found'; code=404
fi
[[ $w -eq 1 ]] && printf '\n%s' "$code"
exit 0
EOF
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

reset_fx() { rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR"; }
# fixture PATH [CODE] < body
fixture() { local n="${1#/}"; n="${n//\//_}"; cat > "$FAKE_DIR/$n.json"; [[ -n "${2:-}" ]] && echo "$2" > "$FAKE_DIR/$n.code"; }
no_secret() { # NAME TEXT — the key must never appear in any output or recorded argv
  if grep -q 'k-test' <<<"$2" || grep -q 'k-test' "$FAKE_DIR/argv.log" 2>/dev/null
  then bad "$1: no key leak" "k-test found in output or curl argv"; else ok "$1: no key leak"; fi
}

GM="$OBS/get-metric.sh"
GD="$OBS/get-dashboard.sh"

# --- M0: harness -------------------------------------------------------------------------------
reset_fx
out="$("$GM" --help 2>&1)"; ck "get-metric.sh --help exits 0" 0 $?
case "$out" in *--promql*) ok "help mentions --promql" ;; *) bad "help mentions --promql" "$out" ;; esac

# --- M1: PromQL range query --------------------------------------------------------------------
# The motivating query, exactly as a caller types it inside single quotes: the two backslashes
# and the quoted label name must reach the provider byte-exact.
Q='max by (consumer_name, stream_name, consumer_group, "deployment.environment") ({__name__=~".*\\.consumer\\.lag_seconds"})'
reset_fx
fixture /api/v4/query_range <<'EOF'
{"status":"success","data":{"resultType":"","result":[{"queryName":"A","series":[
 {"labels":{"consumer_name":"x"},"values":[{"timestamp":1700000000000,"value":"1"},{"timestamp":1700000120000,"value":"2"},{"timestamp":1700000240000,"value":"5"},{"timestamp":1700000360000,"value":"3"}]},
 {"labels":{"consumer_name":"y"},"values":[{"timestamp":1700000000000,"value":"NaN"},{"timestamp":1700000120000,"value":"10"},{"timestamp":1700000240000,"value":"+Inf"},{"timestamp":1700000360000,"value":"4"}]}
]}]}}
EOF
out="$("$GM" --promql "$Q" --from -6h 2>"$T/err")"; ck "promql query exits 0" 0 $?
body="$(cat "$FAKE_DIR/body.json")"
ck "queryType is promql" promql "$(jq -r '.compositeQuery.queryType' <<<"$body")"
ck "query reaches the provider byte-exact" "$Q" "$(jq -r '.compositeQuery.promQueries.A.query' <<<"$body")"
ck "window is 6h" 21600000 "$(jq '.end - .start' <<<"$body")"
ck "step for 6h is 120s" 120 "$(jq '.step' <<<"$body")"
ck "url is query_range" "http://signoz.test/api/v4/query_range" "$(grep -o 'http://signoz.test[^ ]*' "$FAKE_DIR/argv.log")"
case "$(cat "$FAKE_DIR/argv.log")" in *'-X POST'*) ok "method is POST" ;; *) bad "method is POST" "$(cat "$FAKE_DIR/argv.log")" ;; esac
ck "output carries the query" "$Q" "$(jq -r '.query' <<<"$out")"
ck "window step_s echoed" 120 "$(jq '.window.step_s' <<<"$out")"
ck "series sorted by peak desc" 'y x' "$(jq -r '[.series[].labels.consumer_name] | join(" ")' <<<"$out")"
ck "summary of series x" '3 2023-11-14T22:19:20Z 5 2023-11-14T22:17:20Z 1 4 rising' \
  "$(jq -r '.series[1].summary | "\(.current) \(.current_time) \(.peak) \(.peak_time) \(.min) \(.points) \(.trend)"' <<<"$out")"
ck "NaN/+Inf become null and are skipped" '[null,10,null,4] 10 4 2 falling' \
  "$(jq -r '.series[0] | "\([.points[][1]]|tojson) \(.summary.peak) \(.summary.min) \(.summary.points) \(.summary.trend)"' <<<"$out")"
ck "points are [ms, value] pairs" '[1700000000000,1]' "$(jq -c '.series[1].points[0]' <<<"$out")"
no_secret "promql" "$out"
ck "one request" 1 "$(grep -o 'http://signoz.test' "$FAKE_DIR/argv.log" | wc -l | tr -d ' ')"
case "$(cat "$FAKE_DIR/argv.log")" in *'-H @/dev/fd/'*) ok "key sent via header file, not argv" ;; *) bad "key sent via header file, not argv" "$(cat "$FAKE_DIR/argv.log")" ;; esac

reset_fx
fixture /api/v4/query_range <<<'{"status":"success","data":{"result":[]}}'
out="$("$GM" --promql 'up' --from -1h 2>"$T/err")"; ck "empty result exits 0" 0 $?
ck "empty result gives series:[]" '[]' "$(jq -c '.series' <<<"$out")"
case "$(cat "$T/err")" in *note:*) ok "empty result notes on stderr" ;; *) bad "empty result notes on stderr" "$(cat "$T/err")" ;; esac

reset_fx
fixture /api/v4/query_range <<<'{"status":"error","errorType":"bad_data","error":"parse error at char 42: unexpected label"}'
out="$("$GM" --promql 'up' --from -1h 2>&1)"; ck "provider error exits 1" 1 $?
case "$out" in *'parse error at char 42: unexpected label'*) ok "provider error message verbatim" ;; *) bad "provider error message verbatim" "$out" ;; esac

reset_fx
fixture /api/v4/query_range 401 <<<'<html><body>401 Authorization Required</body></html>'
out="$("$GM" --promql 'up' --from -1h 2>&1)"; ck "HTTP 401 exits 1" 1 $?
case "$out" in *'signoz HTTP 401'*) ok "HTTP 401 named" ;; *) bad "HTTP 401 named" "$out" ;; esac
no_secret "401" "$out"

reset_fx
out="$("$GM" --promql 'up' --from 2026-08-10T22:00:00 2>&1)"; ck "bare ISO refused" 1 $?
ck "bare ISO makes no request" 0 "$(grep -c . "$FAKE_DIR/argv.log" 2>/dev/null || echo 0)"
"$GM" --from -1h >/dev/null 2>&1; ck "missing --promql exits 2" 2 $?
"$GM" --promql up --from now --to -1h >/dev/null 2>&1; ck "--from after --to exits 2" 2 $?
"$GM" --promql up --from -7d --step 1s >/dev/null 2>&1; ck "too many points refused" 2 $?

# --- M2: --summary / --limit-series / --raw / --dry-run ----------------------------------------
TWO='{"status":"success","data":{"result":[{"queryName":"A","series":[
 {"labels":{"n":"x"},"values":[{"timestamp":1700000000000,"value":"1"},{"timestamp":1700000060000,"value":"2"}]},
 {"labels":{"n":"y"},"values":[{"timestamp":1700000000000,"value":"9"},{"timestamp":1700000060000,"value":"8"}]}]}]}}'
reset_fx; fixture /api/v4/query_range <<<"$TWO"
out="$("$GM" --promql up --from -1h --summary 2>/dev/null)"; ck "--summary exits 0" 0 $?
ck "--summary drops points" 'false' "$(jq '.series[0] | has("points")' <<<"$out")"
ck "--summary keeps summary" 9 "$(jq '.series[0].summary.peak' <<<"$out")"

reset_fx; fixture /api/v4/query_range <<<"$TWO"
out="$("$GM" --promql up --from -1h --limit-series 1 2>"$T/err")"; ck "--limit-series exits 0" 0 $?
ck "--limit-series 1 keeps the top series" 'y' "$(jq -r '[.series[].labels.n] | join(" ")' <<<"$out")"
case "$(cat "$T/err")" in *'note: 1 more series not shown'*) ok "--limit-series notes the cut" ;; *) bad "--limit-series notes the cut" "$(cat "$T/err")" ;; esac

reset_fx; fixture /api/v4/query_range <<<"$TWO"
out="$("$GM" --promql up --from -1h --raw 2>/dev/null)"; ck "--raw exits 0" 0 $?
ck "--raw is the provider response verbatim" "$(jq -c . <<<"$TWO")" "$(jq -c . <<<"$out")"

reset_fx
out="$("$GM" --promql up --from -1h --dry-run 2>&1)"; ck "--dry-run exits 0" 0 $?
ck "--dry-run sends nothing" 0 "$(grep -c . "$FAKE_DIR/argv.log" 2>/dev/null || echo 0)"
case "$out" in *'POST http://signoz.test/api/v4/query_range'*) ok "--dry-run prints method + URL" ;; *) bad "--dry-run prints method + URL" "$out" ;; esac
case "$out" in *': ***'*) ok "--dry-run masks the key" ;; *) bad "--dry-run masks the key" "$out" ;; esac
ck "--dry-run prints the body" promql "$(sed -n '/^{/,$p' <<<"$out" | jq -r '.compositeQuery.queryType')"
no_secret "dry-run" "$out"

# --- M3: dashboards list / get / widget --------------------------------------------------------
D1=00000000-0000-4000-8000-000000000001
D2=00000000-0000-4000-8000-000000000002
PQ='sum by (service_name) (rate(http_requests_total{deployment_environment="$deployment_environment"}[5m]))'
# The v2 (Perses-style) document: panels keyed by id, queries under spec.queries[0].spec.plugin.spec.queries.
v2panel() { jq -n --arg name "$1" --arg kind "$2" --argjson qs "$3" \
  '{kind: "Panel", spec: {display: {name: $name}, plugin: {kind: $kind, spec: {}},
    queries: [{kind: "time_series", spec: {plugin: {kind: "signoz/CompositeQuery", spec: {queries: $qs}}}}]}}'; }
DASH1="$(jq -n --arg id "$D1" \
  --argjson p1 "$(v2panel 'Lag by env' signoz/TimeSeriesPanel "$(jq -n --arg pq "$PQ" '[{type: "promql", spec: {name: "A", query: $pq, disabled: false, legend: "{{service_name}}", step: 0}}]')")" \
  --argjson p2 "$(v2panel 'Requests' signoz/NumberPanel "$(jq -n '[{type: "builder_query", spec: {name: "A", signal: "metrics", disabled: false, aggregations: [{metricName: "http_requests_total"}]}}, {type: "builder_formula", spec: {name: "F1", expression: "A*2", disabled: false}}]')")" \
  --argjson p3 "$(v2panel 'Raw SQL' signoz/TimeSeriesPanel "$(jq -n '[{type: "clickhouse_sql", spec: {name: "A", query: "SELECT count() FROM signoz_logs.logs", disabled: false, legend: ""}}]')")" \
  '{id: $id, name: "consumer-lag", tags: [{key: "squad", value: "streams"}],
    spec: {display: {name: "Consumer Lag"}, variables: [{kind: "ListVariable", spec: {name: "service", defaultValue: "api"}}],
           panels: {"w-promql": $p1, "w-builder": $p2, "w-ch": $p3}}}')"
# the list endpoint carries no panels, only the display name
DASH2="$(jq -n --arg id "$D2" '{id: $id, name: "other", tags: [], spec: {display: {name: "Other"}}}')"
DASH1L="$(jq 'del(.spec.panels, .spec.variables)' <<<"$DASH1")"
reset_fx
jq -n --argjson a "$DASH1L" --argjson b "$DASH2" '{status: "success", data: {dashboards: [$a, $b], total: 2}}' | fixture /api/v2/dashboards
jq -n --argjson a "$DASH1" '{status: "success", data: $a}' | fixture "/api/v2/dashboards/$D1"

out="$("$GD" --help 2>&1)"; ck "get-dashboard.sh --help exits 0" 0 $?
out="$("$GD" list 2>/dev/null)"; ck "list exits 0" 0 $?
ck "list has one row per dashboard" 2 "$(jq 'length' <<<"$out")"
ck "list row fields" "$D1 Consumer Lag squad:streams null" "$(jq -r '.[0] | "\(.id) \(.title) \(.tags|join(",")) \(.widgets)"' <<<"$out")"
ck "list url" "http://signoz.test/api/v2/dashboards" "$(grep -o 'http://signoz.test[^ ]*' "$FAKE_DIR/argv.log")"
case "$(cat "$FAKE_DIR/argv.log")" in *'-X GET'*) ok "list method is GET" ;; *) bad "list method is GET" "$(cat "$FAKE_DIR/argv.log")" ;; esac
out="$("$GD" list --search 'consumer' 2>/dev/null)"
ck "--search is case-insensitive on title" "$D1" "$(jq -r '.[].id' <<<"$out")"
out="$("$GD" list --search 'nomatch' 2>/dev/null)"; ck "--search with no match gives []" '[]' "$(jq -c . <<<"$out")"
no_secret "list" "$out"

out="$("$GD" get "$D1" 2>/dev/null)"; ck "get exits 0" 0 $?
ck "get title" "Consumer Lag" "$(jq -r '.title' <<<"$out")"
ck "get variables" 'service=api' "$(jq -r '[.variables[] | "\(.name)=\(.default)"] | join(" ")' <<<"$out")"
ck "get widget table" 'w-promql|Lag by env|graph|promql|A w-builder|Requests|value|builder|A,F1 w-ch|Raw SQL|graph|clickhouse_sql|A' \
  "$(jq -r '[.widgets[] | "\(.id)|\(.title)|\(.panel_type)|\(.query_type)|\(.queries|join(","))"] | join(" ")' <<<"$out")"
ck "get url" "http://signoz.test/api/v2/dashboards/$D1" "$(grep -o 'http://signoz.test[^ ]*' "$FAKE_DIR/argv.log" | tail -1)"

out="$("$GD" widget "$D1" w-promql 2>/dev/null)"; ck "widget exits 0" 0 $?
ck "widget prints the PromQL text exact" "$PQ" "$(jq -r '.queries.promql[0].query' <<<"$out")"
ck "widget carries query_type" promql "$(jq -r '.query_type' <<<"$out")"
out="$("$GD" widget "$D1" w-builder 2>/dev/null)"
ck "builder widget prints query data" 'A metrics F1' "$(jq -r '.queries.builder | "\(.queryData[0].queryName) \(.queryData[0].signal) \(.queryFormulas[0].queryName)"' <<<"$out")"
out="$("$GD" widget "$D1" w-ch 2>/dev/null)"
ck "clickhouse widget prints SQL" 'SELECT count() FROM signoz_logs.logs' "$(jq -r '.queries.clickhouse_sql[0].query' <<<"$out")"

out="$("$GD" widget "$D1" w-nope 2>&1)"; ck "unknown widget exits 1" 1 $?
case "$out" in *'w-promql'*'Lag by env'*'w-builder'*'w-ch'*) ok "unknown widget lists valid ids + titles" ;; *) bad "unknown widget lists valid ids + titles" "$out" ;; esac
out="$("$GD" get "$D2" 2>&1)"; ck "unknown dashboard exits 1" 1 $?
case "$out" in *'signoz HTTP 404'*) ok "unknown dashboard names HTTP 404" ;; *) bad "unknown dashboard names HTTP 404" "$out" ;; esac
"$GD" 2>/dev/null; ck "no subcommand exits 2" 2 $?
"$GD" widget "$D1" 2>/dev/null; ck "widget without id exits 2" 2 $?

# --- M4: widget --run ----------------------------------------------------------------------------
RUN='{"status":"success","data":{"result":[{"queryName":"A","series":[
 {"labels":{"service_name":"api"},"values":[{"timestamp":1700000000000,"value":"1"},{"timestamp":1700000120000,"value":"3"}]}]},
 {"queryName":"F1","series":[{"labels":{},"values":[{"timestamp":1700000000000,"value":"2"},{"timestamp":1700000120000,"value":"6"}]}]}]}}'
reset_fx
jq -n --argjson a "$DASH1" '{status: "success", data: $a}' | fixture "/api/v2/dashboards/$D1"
fixture /api/v4/query_range <<<"$RUN"

out="$("$GD" widget "$D1" w-promql --run --from -6h --summary 2>&1)"; ck "unresolved variable refused (exit 1)" 1 $?
case "$out" in *'deployment_environment'*) ok "refusal names the variable" ;; *) bad "refusal names the variable" "$out" ;; esac
ck "refusal sends nothing" 1 "$(grep -c 'api/v2/dashboards' "$FAKE_DIR/argv.log")"
ck "refusal never reaches query_range" 0 "$(grep -c 'query_range' "$FAKE_DIR/argv.log")"

reset_fx
jq -n --argjson a "$DASH1" '{status: "success", data: $a}' | fixture "/api/v2/dashboards/$D1"
fixture /api/v4/query_range <<<"$RUN"
out="$("$GD" widget "$D1" w-promql --run --from -6h --var deployment_environment=staging --summary 2>"$T/err")"; ck "promql widget --run exits 0" 0 $?
body="$(cat "$FAKE_DIR/body.json")"
ck "run: composite is promql" promql "$(jq -r '.compositeQuery.queryType' <<<"$body")"
ck "run: promQueries keyed by name, text exact" "$PQ" "$(jq -r '.compositeQuery.promQueries.A.query' <<<"$body")"
ck "run: panelType from the widget" graph "$(jq -r '.compositeQuery.panelType' <<<"$body")"
ck "run: --var lands in variables" staging "$(jq -r '.variables.deployment_environment' <<<"$body")"
ck "run: window is 6h at 120s" '21600000 120' "$(jq -r '"\(.end - .start) \(.step)"' <<<"$body")"
ck "run: one AC7 block per query name" 'A' "$(jq -rs '[.[].query] | join(" ")' <<<"$out")"
ck "run: block has the AC7 shape" 'true true 3 rising' "$(jq -rs '.[0] | "\(has("window")) \(.series[0] | has("summary")) \(.series[0].summary.peak) \(.series[0].summary.trend)"' <<<"$out")"
ck "run: --summary drops points" false "$(jq -rs '.[0].series[0] | has("points")' <<<"$out")"
no_secret "widget run" "$out"

reset_fx
jq -n --argjson a "$DASH1" '{status: "success", data: $a}' | fixture "/api/v2/dashboards/$D1"
fixture /api/v4/query_range <<<"$RUN"
out="$("$GD" widget "$D1" w-builder --run --from -6h 2>&1)"; ck "builder widget --run refused (exit 1)" 1 $?
case "$out" in *'v2 dashboard shape'*) ok "builder refusal explains the v2 shape" ;; *) bad "builder refusal explains the v2 shape" "$out" ;; esac
ck "builder refusal never reaches query_range" 0 "$(grep -c 'query_range' "$FAKE_DIR/argv.log")"

reset_fx
jq -n --argjson a "$DASH1" '{status: "success", data: $a}' | fixture "/api/v2/dashboards/$D1"
out="$("$GD" widget "$D1" w-ch --run --from -1h --dry-run 2>&1)"; ck "widget --run --dry-run exits 0" 0 $?
ck "run dry-run never reaches query_range" 0 "$(grep -c 'query_range' "$FAKE_DIR/argv.log")"
case "$out" in *'POST http://signoz.test/api/v4/query_range'*) ok "run dry-run prints method + URL" ;; *) bad "run dry-run prints method + URL" "$out" ;; esac
ck "run: chQueries keyed by name" 'SELECT count() FROM signoz_logs.logs' "$(sed -n '/^{/,$p' <<<"$out" | jq -r '.compositeQuery.chQueries.A.query')"
no_secret "widget dry-run" "$out"

reset_fx
jq -n --argjson a "$DASH1" '{status: "success", data: $a}' | fixture "/api/v2/dashboards/$D1"
fixture /api/v4/query_range <<<'{"status":"success","data":{"result":"something else"}}'
out="$("$GD" widget "$D1" w-ch --run --from -1h 2>"$T/err")"; ck "unrecognized result shape exits 0" 0 $?
case "$(cat "$T/err")" in *note:*) ok "unrecognized shape notes on stderr" ;; *) bad "unrecognized shape notes on stderr" "$(cat "$T/err")" ;; esac
ck "unrecognized shape prints raw" 'something else' "$(jq -r '.data.result' <<<"$out")"

# --- the backend widens a step it finds too fine; the report must say what it really returned ----
reset_fx
fixture /api/v4/query_range <<<'{"status":"success","data":{"result":[{"queryName":"A","series":[{"labels":{},"values":[{"timestamp":1700000000000,"value":"1"},{"timestamp":1700001980000,"value":"2"}]}]}]}}'
out="$("$GM" --promql 'up' --from -6h --step 60s --summary 2>/dev/null)"
ck "report names the step the backend actually used" '60 1980' "$(jq -r '"\(.window.step_s) \(.window.effective_step_s)"' <<<"$out")"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
