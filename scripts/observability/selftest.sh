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

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
