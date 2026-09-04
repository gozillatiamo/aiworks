#!/usr/bin/env bash
# Execute one canonical .claude/workflows/src script through a selected Harness adapter.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
command -v node >/dev/null 2>&1 || { printf 'aiworks workflow: node is required\n' >&2; exit 1; }
exec node "$DIR/workflows/run.mjs" "$@"
