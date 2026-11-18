#!/usr/bin/env bash
# Night Watch entry point. See scripts/night-watch/README.md.
#
#   ./run.sh tick     run ONE Tick now and exit (cron/launchd friendly)
#   ./run.sh loop     wait for each slot, run a Tick, repeat; Ctrl-C stops it
#   ./run.sh plan     print the slot for now, whether it is active, and the next one
#   ./run.sh brief [latest|HH:MM|YYYYMMDDTHHMM]   print a Verdict for a follow-up (read-only)
#   ./run.sh resolve <latest|HH:MM|YYYYMMDDTHHMM> <n> --note "<one line>" [--alert]
#                     mark finding n of that Verdict safe; later Ticks drop a repeat of it
#   ./run.sh unresolve <id>   remove a resolution (id printed by resolve and resolved)
#   ./run.sh resolved         list active resolutions (read-only)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  tick|plan) exec python3 "$DIR/night_watch.py" "$1" ;;
  brief) exec python3 "$DIR/night_watch.py" brief "${2:-latest}" ;;
  resolve|unresolve|resolved) exec python3 "$DIR/night_watch.py" "$@" ;;
  loop)
    # Hold the machine awake for the lifetime of this process (exec keeps the PID).
    if [[ "$(uname)" == Darwin ]] && command -v caffeinate >/dev/null 2>&1; then
      caffeinate -is -w $$ &
    fi
    exec python3 "$DIR/night_watch.py" loop ;;
  *) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; [[ "${1:-}" == -h || "${1:-}" == --help ]] ;;
esac
