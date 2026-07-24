#!/usr/bin/env bash
# Boot the Slack dispatcher: start the dedicated Redis, ensure a venv with deps,
# then run the Socket Mode service in the foreground. Ctrl-C stops the service
# (Redis keeps running; stop it with: docker compose down).
#
#   ./run.sh            # start the service
#   ./run.sh --check    # run pre-flight checks only, then exit
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# Load local config (git-ignored). Same pattern the notify adapter uses.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
else
  echo "error: scripts/slack-dispatch/.env not found — copy .env.example and fill it in" >&2
  exit 1
fi

PY=./.venv/bin/python
if [[ ! -x "$PY" ]]; then
  echo "── creating venv + installing deps ──"
  python3 -m venv .venv
  ./.venv/bin/pip install --quiet --upgrade pip
  ./.venv/bin/pip install --quiet -r requirements.txt
fi

echo "── starting dedicated Redis (docker compose) ──"
docker compose up -d

if [[ "${1:-}" == "--check" ]]; then
  exec "$PY" -m aiworks_dispatch.check
fi

echo "── pre-flight ──"
"$PY" -m aiworks_dispatch.check || { echo "pre-flight failed — see above"; exit 1; }

echo "── starting dispatcher (Ctrl-C to stop) ──"
exec "$PY" -m aiworks_dispatch
