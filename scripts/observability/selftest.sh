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

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
