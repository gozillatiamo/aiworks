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

# Who owns a listener — the same identification gcloud_tunnel.owner_of applies, so this script,
# the MCP and the SessionEnd reaper agree: an MCP-spawned forward carries
# `-E …/triage-tunnel-<mcp-pid>-…log` in its argv. Owner alive -> MCP-owned; owner dead -> MCP
# orphan. No signature -> a person's own (ppid 1 -> detached manual).
ssh_owner() {
  local pid="$1" args owner ppid
  args="$(ps -ww -o args= -p "$pid" 2>/dev/null)"
  owner="$(grep -oE '(^|/)triage-tunnel-[0-9]+-' <<< "$args" | head -1 | grep -oE '[0-9]+')"
  if [[ -n "$owner" ]]; then
    kill -0 "$owner" 2>/dev/null && echo "MCP-owned" || echo "MCP orphan"
    return 0
  fi
  ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  [[ "$ppid" == "1" ]] && echo "detached manual" || echo "manual"
}

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
      for pid in $pids; do
        printf '          %-16s ' "$(ssh_owner "$pid")"
        ps -o pid=,etime=,command= -p "$pid" 2>/dev/null | cut -c1-140
      done
    else
      echo "closed  $name  (${vm/#-/tunnel})  127.0.0.1:$port"
    fi
  done <<< "$rows"
  [[ "$any" -eq 0 ]] && echo "nothing open — zero connections to a deployed Redis"
  return 0
}

kill_one() {
  local want="$1" found=0 killed owner pgid kept
  while IFS=$'\t' read -r name port vm kind; do
    [[ "$name" == "$want" ]] || continue
    found=1
    if [[ "$kind" == "none" ]]; then echo "n/a     $name has tunnel=none — nothing to kill"; continue; fi
    killed=0; kept=""
    for pid in $(listener_pids "$port"); do
      owner="$(ssh_owner "$pid")"
      if [[ "$owner" == *manual ]]; then
        kept="$kept $pid"
        echo "kept    pid $pid ($owner — yours; stop it with Ctrl-C in its terminal, or kill $pid)"
        continue
      fi
      # Process group, so the gcloud wrapper above the ssh dies with it.
      pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
      kill -TERM -- "-${pgid:-$pid}" 2>/dev/null && killed=1
    done
    sleep 1
    for pid in $(listener_pids "$port"); do
      [[ " $kept " == *" $pid "* ]] && continue
      pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
      kill -KILL -- "-${pgid:-$pid}" 2>/dev/null || true
    done
    if [[ "$killed" -eq 1 ]]; then echo "killed  $name tunnel on :$port"
    elif [[ -z "$kept" ]]; then echo "closed  $name already had no listener on :$port"; fi
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
