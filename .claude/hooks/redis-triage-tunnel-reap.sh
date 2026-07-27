#!/usr/bin/env bash
# SessionEnd — close any redis-triage SSH tunnel left behind by this session.
#
# The MCP server already reaps its own tunnels (idle watchdog + `disconnect` + atexit). This
# hook is the backstop for the case those cannot cover: a hard-killed session, where atexit
# never runs and the watchdog dies with the process, leaving a forwarded port open to a
# deployed Redis.
#
# Only a process that is BOTH listening on one of the tunnel ports AND a gcloud/ssh command
# naming a known Redis VM is touched — an unrelated service on that port is left alone.
set -uo pipefail

reap() {
  local port=$1 vm=$2 pid cmd
  for pid in $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null); do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
    case "$cmd" in
      *"$vm"*)
        kill "$pid" 2>/dev/null || continue
        sleep 1
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        echo "redis-triage: reaped orphan tunnel to $vm (port $port, pid $pid)" >&2
        ;;
    esac
  done
}

reap 6378 ofb-staging-vm
reap 6377 agent-prod-redis-vm
exit 0
