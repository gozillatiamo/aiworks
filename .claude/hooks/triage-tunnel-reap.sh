#!/usr/bin/env bash
# SessionEnd — reap the triage-MCP ssh forwards a hard-killed session left behind.
#
# The pg/redis triage MCPs reap their own tunnels (idle watchdog + `disconnect` + atexit). This
# hook is the backstop for the one case those cannot cover: a hard-killed session, where atexit
# never runs and the watchdog dies with the process, leaving a forwarded port open to a
# deployed database.
#
# It reads no .env and knows no ports. Every forward the MCP spawns is signed by its own
# argv — `-E …/triage-tunnel-<mcp-pid>-<label>-….log` (scripts/lib/gcloud_tunnel.py) — so the
# hook walks every listening ssh, and kills ONLY a signed one whose owner pid is dead. An
# unsigned forward (a person's own) and a signed one whose MCP is still running are never
# touched. The kill goes to the process group, so the gcloud wrapper above the ssh dies too.
#
#   --selftest   hermetic check against python stand-ins (no ssh, no network)
set -uo pipefail

CMD="${TRIAGE_REAP_CMD:-ssh}"   # lsof command name of a forward (selftest seam)

# Every listening pid whose lsof command name is $CMD.
listeners() {
  lsof -nP -iTCP -sTCP:LISTEN -Fpc 2>/dev/null | awk -v want="$CMD" '
    /^p/ { pid = substr($0, 2) }
    /^c/ { if (substr($0, 2) == want) print pid }' | sort -u
}

# The MCP pid a signed forward belongs to, or nothing when unsigned.
owner_of() {
  ps -ww -o args= -p "$1" 2>/dev/null | grep -oE '(^|/)triage-tunnel-[0-9]+-' | head -1 | grep -oE '[0-9]+'
}

reap() {
  local pid owner pgid
  for pid in $(listeners); do
    owner="$(owner_of "$pid")"
    [[ -n "$owner" ]] || continue            # unsigned: a person's own forward
    kill -0 "$owner" 2>/dev/null && continue  # owner alive: the MCP will close it itself
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [[ -n "$pgid" ]] || continue
    kill -TERM -- "-$pgid" 2>/dev/null || continue
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -KILL -- "-$pgid" 2>/dev/null
    echo "triage-tunnel-reap: reaped orphan forward pid $pid (owner $owner is dead)" >&2
  done
}

selftest() {
  local fails=0 dead live p1 p2 p3 c
  check() { if [[ "$2" == "1" ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
  alive() { [[ -n "$(ps -o stat= -p "$1" 2>/dev/null | grep -v '^Z')" ]]; }   # a zombie child still answers kill -0
  # A pid that is certainly dead: a short-lived child whose exit we have already collected.
  ( : ) & dead=$!; wait "$dead"
  live=$$
  stand_in() {  # listener on a free port, own process group, argv carrying the given tail
    python3 -c 'import os,socket,time
os.setsid(); s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(1); time.sleep(60)' "$@" >/dev/null 2>&1 &
    echo $!
  }
  p1="$(stand_in -E "/tmp/triage-tunnel-$dead-lbl-x.log")"   # signed, owner dead  -> reaped
  p2="$(stand_in -E "/tmp/triage-tunnel-$live-lbl-x.log")"   # signed, owner alive -> kept
  p3="$(stand_in -E "/tmp/unsigned.log")"                     # unsigned            -> kept
  sleep 1
  c="$(lsof -a -nP -iTCP -sTCP:LISTEN -Fpc -p "$p1" 2>/dev/null | awk '/^c/ { print substr($0, 2); exit }')"   # -a: AND the filters
  check "stand-ins listen (lsof names them)" "$([[ -n "$c" ]] && echo 1 || echo 0)"
  check "owner_of: signed -> owner pid" "$([[ "$(owner_of "$p1")" == "$dead" ]] && echo 1 || echo 0)"
  check "owner_of: unsigned -> empty" "$([[ -z "$(owner_of "$p3")" ]] && echo 1 || echo 0)"
  CMD="$c" reap 2>/dev/null
  sleep 1
  check "dead-owner forward reaped" "$(alive "$p1" && echo 0 || echo 1)"
  check "live-owner forward kept" "$(alive "$p2" && echo 1 || echo 0)"
  check "unsigned forward kept" "$(alive "$p3" && echo 1 || echo 0)"
  kill "$p2" "$p3" 2>/dev/null; wait 2>/dev/null
  echo "triage-tunnel-reap selftest: $fails failure(s)"
  [[ "$fails" -eq 0 ]]
}

case "${1:-}" in
  --selftest) selftest ;;
  *) reap; exit 0 ;;
esac
