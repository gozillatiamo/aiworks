#!/usr/bin/env bash
# tunnel.sh — inspect / clear the redis-triage SSH tunnels.
#
# The MCP server (redis_triage_mcp.py) owns its own tunnels: it opens them lazily, reaps any
# tunnel idle past its timeout, and closes everything on `disconnect` and on exit. This script
# is the HUMAN's view of that — for confirming nothing is left open, and for clearing an orphan
# left by a hard-killed session.
#
# It is deliberately NOT granted to agents: `gcloud compute ssh` with a different `--` operand
# is a shell on the production VM, so no agent gets a path to that command.
#
# Targets come from scripts/redis/.env — the same file the MCP reads. See .env.example.
#
#   scripts/redis/tunnel.sh status
#   scripts/redis/tunnel.sh kill [<target>…]
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${REDIS_TRIAGE_ENV:-$DIR/.env}"

# Target table parsed out of the .env: NAME<TAB>LOCAL_PORT<TAB>VM<TAB>TUNNEL_KIND per line.
# Only the fields this script needs are read, and none of them are printed beyond the report.
targets() {
  [[ -f "$ENV_FILE" ]] || return 0
  awk '
    /^[ \t]*#/ { next }
    !/^[ \t]*REDISPROD_[A-Za-z0-9_]+=/ { next }
    {
      name = $0; sub(/^[ \t]*REDISPROD_/, "", name); sub(/=.*/, "", name)
      spec = substr($0, index($0, "=") + 1)
      local = ""; vm = ""; kind = "gcloud"
      n = split(spec, parts, ";")
      for (i = 1; i <= n; i++) {
        kv = parts[i]; gsub(/^[ \t]+|[ \t]+$/, "", kv)
        k = kv; sub(/=.*/, "", k)
        v = kv; sub(/^[^=]*=/, "", v)
        if (k == "local") local = v
        else if (k == "vm") vm = v
        else if (k == "tunnel") kind = tolower(v)
      }
      if (local != "") printf "%s\t%s\t%s\t%s\n", tolower(name), local, (vm == "" ? "-" : vm), kind
    }
  ' "$ENV_FILE"
}

listener_pids() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null || true; }

status() {
  local any=0 rows pids
  rows="$(targets)"
  if [[ -z "$rows" ]]; then
    echo "no targets configured — copy scripts/redis/.env.example to scripts/redis/.env"
    return 0
  fi
  while IFS=$'\t' read -r name port vm kind; do
    [[ -n "$name" ]] || continue
    if [[ "$kind" == "none" ]]; then
      echo "n/a     $name  (tunnel=none — nothing for this script to manage)"
      continue
    fi
    pids="$(listener_pids "$port")"
    if [[ -n "$pids" ]]; then
      any=1
      echo "OPEN    $name  (${vm/#-/tunnel})  127.0.0.1:$port  pid(s): $(echo "$pids" | tr '\n' ' ')"
      # shellcheck disable=SC2086
      ps -o pid=,etime=,command= -p $(echo "$pids" | tr '\n' ' ') 2>/dev/null |
        sed 's/^/          /' | cut -c1-160
    else
      echo "closed  $name  (${vm/#-/tunnel})  127.0.0.1:$port"
    fi
  done <<< "$rows"
  [[ "$any" -eq 0 ]] && echo "nothing open — zero connections to a deployed Redis"
  return 0
}

kill_one() {
  local want="$1" found=0 killed
  while IFS=$'\t' read -r name port vm kind; do
    [[ "$name" == "$want" ]] || continue
    found=1
    if [[ "$kind" == "none" ]]; then echo "n/a     $name has tunnel=none — nothing to kill"; continue; fi
    killed=0
    for pid in $(listener_pids "$port"); do
      kill "$pid" 2>/dev/null && killed=1
    done
    sleep 1
    for pid in $(listener_pids "$port"); do kill -9 "$pid" 2>/dev/null || true; done
    if [[ "$killed" -eq 1 ]]; then echo "killed  $name tunnel on :$port"
    else echo "closed  $name already had no listener on :$port"; fi
  done <<< "$(targets)"
  [[ "$found" -eq 1 ]] || { echo "unknown target: $want (see scripts/redis/.env)" >&2; return 2; }
}

case "${1:-status}" in
  status) status ;;
  kill)
    shift || true
    if [[ $# -gt 0 ]]; then
      for name in "$@"; do kill_one "$name" || exit $?; done
    else
      while IFS=$'\t' read -r name _ _ _; do [[ -n "$name" ]] && kill_one "$name"; done <<< "$(targets)"
    fi
    ;;
  *)
    echo "usage: $(basename "$0") status | kill [<target>…]" >&2
    exit 2
    ;;
esac
