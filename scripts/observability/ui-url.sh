#!/usr/bin/env bash
# Print the observability UI link for evidence ids — one output line per id, in order.
#
#   ./ui-url.sh trace 474635a87bd076aeb672bbcf59591a8c 35ee3fb8fb1f8fc441bac2b40c944f9b
#
# A line is empty when there is no verified deep link for that (kind, id): the caller shows
# plain text instead. No network call. Exit 0; non-zero only on usage or missing config.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: ui-url.sh <kind> <id>...

Print one line per <id>: the backend's UI URL for that evidence (kind: trace), or an empty
line when the backend has no verified deep link for it. Provider: OBSERVABILITY_PROVIDER.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 2 ]] || { usage >&2; exit 2; }

# shellcheck source=lib.sh
. "$DIR/lib.sh"
obs_require_config

kind="$1"; shift
for id in "$@"; do
  line="$(obs_ui_url "$kind" "$id")"
  printf '%s\n' "$line"
done
