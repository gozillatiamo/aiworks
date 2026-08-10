#!/usr/bin/env bash
# tunnel.sh — inspect / clear the redis-triage SSH tunnels.
#
# The MCP server (redis_triage_mcp.py) owns its own tunnels: it opens them lazily, reaps any
# tunnel idle past its timeout, and closes everything on `disconnect` and on exit. This
# script is the HUMAN's view of that — for confirming nothing is left open, and for clearing
# an orphan left by a hard-killed session.
#
# It is deliberately NOT granted to agents: `gcloud compute ssh` with a different `--` operand
# is a shell on the production VM, so no agent gets a path to that command.
#
#   scripts/redis/tunnel.sh status
#   scripts/redis/tunnel.sh kill [staging|prod]
set -euo pipefail

declare -a NAMES=(staging prod)

# Lookup FUNCTIONS, not associative arrays — `declare -A` needs bash 4 and macOS ships 3.2
# as /bin/bash (see the interpreter note in scripts/aiworks).
vm_of() {   case "$1" in staging) printf 'ofb-staging-vm' ;; prod) printf 'agent-prod-redis-vm' ;; esac; }
port_of() { case "$1" in staging) printf '6378' ;; prod) printf '6377' ;; esac; }

listener_pids() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null || true; }

status() {
  local any=0
  for name in "${NAMES[@]}"; do
    local port pids
    port="$(port_of "$name")"
    pids=$(listener_pids "$port")
    if [ -n "$pids" ]; then
      any=1
      echo "OPEN    $name  ($(vm_of "$name"))  127.0.0.1:$port  pid(s): $(echo "$pids" | tr '\n' ' ')"
      # shellcheck disable=SC2086
      ps -o pid=,etime=,command= -p $(echo "$pids" | tr '\n' ' ') 2>/dev/null |
        sed 's/^/          /' | cut -c1-160
    else
      echo "closed  $name  ($(vm_of "$name"))  127.0.0.1:$port"
    fi
  done
  local strays
  strays=$(pgrep -f "gcloud.*compute.*ssh.*($(vm_of staging)|$(vm_of prod))" 2>/dev/null || true)
  if [ -n "$strays" ]; then
    echo "note    gcloud ssh process(es) matching a redis VM: $(echo "$strays" | tr '\n' ' ')"
  fi
  [ "$any" -eq 0 ] && echo "nothing open — zero connections to a deployed Redis"
  return 0
}

kill_one() {
  local name=$1 port pids killed=0
  port="$(port_of "$name")"
  pids=$(listener_pids "$port")
  for pid in $pids; do
    kill "$pid" 2>/dev/null && killed=1
  done
  sleep 1
  for pid in $(listener_pids "$port"); do
    kill -9 "$pid" 2>/dev/null || true
  done
  if [ "$killed" -eq 1 ]; then echo "killed  $name tunnel on :$port"; else echo "closed  $name already had no listener on :$port"; fi
}

case "${1:-status}" in
  status) status ;;
  kill)
    shift || true
    if [ $# -gt 0 ]; then
      for name in "$@"; do
        [ -n "$(port_of "$name")" ] || { echo "unknown target: $name (use staging|prod)" >&2; exit 2; }
        kill_one "$name"
      done
    else
      for name in "${NAMES[@]}"; do kill_one "$name"; done
    fi
    ;;
  *)
    echo "usage: $(basename "$0") status | kill [staging|prod]" >&2
    exit 2
    ;;
esac
