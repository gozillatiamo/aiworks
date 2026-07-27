#!/usr/bin/env bash
# SessionEnd — close any redis-triage SSH tunnel left behind by this session.
#
# The MCP server already reaps its own tunnels (idle watchdog + `disconnect` + atexit). This
# hook is the backstop for the case those cannot cover: a hard-killed session, where atexit
# never runs and the watchdog dies with the process, leaving a forwarded port open to a
# deployed Redis.
#
# Targets are read from scripts/redis/.env (the file the MCP itself reads), so this hook needs
# no hardcoded ports and stays correct when a target is added or renamed.
#
# Only a process that is BOTH listening on a declared tunnel port AND a command naming that
# target's VM is touched — an unrelated service on that port is left alone. A `tunnel=none`
# target spawns nothing, so there is nothing to reap for it.
set -uo pipefail

ENV_FILE="${REDIS_TRIAGE_ENV:-${CLAUDE_PROJECT_DIR:-.}/scripts/redis/.env}"
[[ -f "$ENV_FILE" ]] || exit 0

reap() {
  local port=$1 vm=$2 pid cmd
  [[ -n "$vm" ]] || return 0
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

while IFS=$'\t' read -r port vm kind; do
  [[ -n "$port" && "$kind" != "none" && "$vm" != "-" ]] || continue
  reap "$port" "$vm"
done < <(
  awk '
    /^[ \t]*#/ { next }
    !/^[ \t]*REDISPROD_[A-Za-z0-9_]+=/ { next }
    {
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
      if (local != "") printf "%s\t%s\t%s\n", local, (vm == "" ? "-" : vm), kind
    }
  ' "$ENV_FILE"
)
exit 0
