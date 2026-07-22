#!/usr/bin/env bash
# Observability adapter — shared dispatch for the tracing/logging scripts.
# Sourced by entry scripts (get-trace.sh, get-logs.sh); not meant to run alone.
#
# Selects a provider implementation by OBSERVABILITY_PROVIDER (signoz) and sources
# scripts/observability/<provider>/impl.sh, which defines the provider interface:
#
#   obs_require_config                         — validate the provider's env (base url/key), die if missing
#   obs_get_trace TRACE_ID [SPAN_ID]            — print the trace's span waterfall; SPAN_ID (optional) highlights one span
#   obs_query_logs QUERY FROM_MS TO_MS [LIMIT]  — print log lines matching QUERY in [FROM_MS, TO_MS)
#
# Like the vcs/tracker/notify adapters, this reads a git-ignored scripts/observability/.env
# for the provider + secrets (already covered by the workspace's blanket .env / .env.* gitignore
# rule — nothing extra to add there).

set -euo pipefail

OBSERVABILITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load a .env sitting next to these scripts, if present (git-ignored local config).
if [[ -f "$OBSERVABILITY_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$OBSERVABILITY_DIR/.env"
  set +a
fi

die() { echo "error: $*" >&2; exit 1; }
command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required (brew install jq)"

# Which observability backend this workspace uses. Defaults to signoz (the only provider today).
OBSERVABILITY_PROVIDER="${OBSERVABILITY_PROVIDER:-signoz}"
IMPL="$OBSERVABILITY_DIR/$OBSERVABILITY_PROVIDER/impl.sh"
[[ -f "$IMPL" ]] || die "unknown OBSERVABILITY_PROVIDER '$OBSERVABILITY_PROVIDER' (no $IMPL) — use 'signoz', or add an impl.sh under scripts/observability/$OBSERVABILITY_PROVIDER/"

# shellcheck disable=SC1090
. "$IMPL"
obs_require_config
