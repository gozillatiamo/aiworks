#!/usr/bin/env bash
# Offline fixture tests for the MCP stdio wrappers and their shared .env loader.
# No network, no real secret: every value below is a fixture.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$(mktemp -d -t aiworks-mcp-selftest)"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# A main checkout with a .env, and a linked worktree that has none yet (setup still running).
MAIN="$FIXTURE/main"
mkdir -p "$MAIN/scripts/mcp"
git -C "$MAIN" init -q
git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
printf 'FOO=main-value\nSONARQUBE_TOKEN=fixture-token\n' > "$MAIN/.env"
git -C "$MAIN" worktree add -q "$FIXTURE/wt" 2>/dev/null
WT="$FIXTURE/wt"
mkdir -p "$WT/scripts/mcp"
cp "$SRC/load-workspace-env.sh" "$SRC/sonarqube.sh" "$WT/scripts/mcp/" 2>/dev/null || true

# T1 — a worktree without .env falls back to the main checkout's .env, silently.
out="$(cd "$WT" && ROOT="$WT" bash -c '. scripts/mcp/load-workspace-env.sh; load_workspace_env FOO; printf "%s" "$FOO"' 2>"$FIXTURE/err")"
test "$out" = "main-value" || fail "T1 fallback did not load FOO"
grep -q main-value "$FIXTURE/err" && fail "T1 value leaked to stderr"

# T2 — the worktree's own .env wins over main's.
printf 'FOO=wt-value\n' > "$WT/.env"
out="$(ROOT="$WT" bash -c ". '$WT/scripts/mcp/load-workspace-env.sh'; load_workspace_env FOO; printf '%s' \"\$FOO\"")"
test "$out" = "wt-value" || fail "T2 worktree .env did not win"
rm "$WT/.env"

# T3 — sonarqube.sh without a token: non-zero, names the key, prints no value.
mv "$MAIN/.env" "$MAIN/.env.off"
if env -u SONARQUBE_TOKEN bash "$WT/scripts/mcp/sonarqube.sh" >"$FIXTURE/out" 2>&1; then fail "T3 should exit non-zero"; fi
grep -q SONARQUBE_TOKEN "$FIXTURE/out" || fail "T3 message does not name SONARQUBE_TOKEN"
mv "$MAIN/.env.off" "$MAIN/.env"

# T4a — closed port: gives up within the wait bound, non-zero.
port=$(( 40000 + RANDOM % 20000 ))
start=$SECONDS
if env -u SONARQUBE_TOKEN MCP_SONARQUBE_PORT=$port MCP_PORT_WAIT_SECS=1 bash "$WT/scripts/mcp/sonarqube.sh" >"$FIXTURE/out" 2>&1; then
  fail "T4a closed port should exit non-zero"
fi
(( SECONDS - start <= 5 )) || fail "T4a wait exceeded bound"
grep -q fixture-token "$FIXTURE/out" && fail "T4a token leaked"

# T4b — open port: execs mcp-remote with the URL and the header built in-process.
mkdir -p "$FIXTURE/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/argv"\n' "$FIXTURE" > "$FIXTURE/bin/npx"
chmod +x "$FIXTURE/bin/npx"
python3 -c 'import socket,sys,time;s=socket.socket();s.bind(("127.0.0.1",0));s.listen();print(s.getsockname()[1],flush=True);time.sleep(10)' > "$FIXTURE/port" &
lpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$FIXTURE/port" ]] && break; sleep 0.2; done
port="$(cat "$FIXTURE/port")"
env -u SONARQUBE_TOKEN PATH="$FIXTURE/bin:$PATH" HOME="$FIXTURE" MCP_SONARQUBE_PORT="$port" MCP_PORT_WAIT_SECS=2 \
  bash "$WT/scripts/mcp/sonarqube.sh" >"$FIXTURE/out" 2>&1 || fail "T4b wrapper failed: $(cat "$FIXTURE/out")"
kill "$lpid" 2>/dev/null || true
grep -qx 'mcp-remote' "$FIXTURE/argv" || fail "T4b mcp-remote not exec'd"
grep -qx "http://localhost:$port/mcp" "$FIXTURE/argv" || fail "T4b URL missing"
grep -qx 'Authorization: Bearer fixture-token' "$FIXTURE/argv" || fail "T4b header missing"
grep -q fixture-token "$FIXTURE/out" && fail "T4b token printed"

echo "mcp selftest: ok"
