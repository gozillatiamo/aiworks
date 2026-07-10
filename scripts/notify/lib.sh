#!/usr/bin/env bash
# Notify adapter — shared dispatch for the notification scripts.
# Sourced by the entry script (send.sh); not meant to run alone.
#
# Selects a provider implementation by NOTIFY_PROVIDER (slack) and sources
# scripts/notify/<provider>/impl.sh, which defines the provider interface:
#
#   notify_require_config                   — validate the provider's env (token/webhook), die if missing
#   notify_send  CHANNEL TEXT [DRY] [THREAD] — post TEXT to CHANNEL; a non-empty THREAD replies in-thread. Prints "ok=1" + "permalink=<url>"
#   notify_find_thread CHANNEL KEY          — print the ts of the newest message containing KEY (the review-request), else nothing (caller SKIPS). Best-effort; a provider that can't search returns empty
#
# CHANNEL is provider-neutral: an id, a #name, or empty (fall back to NOTIFY_CHANNEL, then
# whatever the provider's default destination is — e.g. a webhook's bound channel).
#
# Like the vcs/tracker adapters, this reads a git-ignored scripts/notify/.env for the
# provider + secrets. The "should we notify at all" DECISION lives upstream in
# workspace.config.yaml (notify.enabled + vcs.auto_merge) and the dev-cycle workflow's
# Notify phase — send.sh is the low-level primitive and always sends when invoked.

set -euo pipefail

NOTIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load a .env sitting next to these scripts, if present (git-ignored local config).
if [[ -f "$NOTIFY_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$NOTIFY_DIR/.env"
  set +a
fi

die() { echo "error: $*" >&2; exit 1; }
command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required (brew install jq)"

# Which chat backs this workspace. Defaults to slack (the only provider today).
NOTIFY_PROVIDER="${NOTIFY_PROVIDER:-slack}"
IMPL="$NOTIFY_DIR/$NOTIFY_PROVIDER/impl.sh"
[[ -f "$IMPL" ]] || die "unknown NOTIFY_PROVIDER '$NOTIFY_PROVIDER' (no $IMPL) — use 'slack', or add an impl.sh under scripts/notify/$NOTIFY_PROVIDER/"

# shellcheck disable=SC1090
. "$IMPL"
notify_require_config
