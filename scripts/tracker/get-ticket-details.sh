#!/usr/bin/env bash
# Read a ticket's details from the configured tracker and print them as plain text.
#
#   ./get-ticket-details.sh FM-9        # Notion unique-id / Jira key
#   ./get-ticket-details.sh APP-123
#   ./get-ticket-details.sh 9           # bare number (uses the configured project/db)
#   ./get-ticket-details.sh <id|url>    # a raw page id or tracker URL
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: get-ticket-details.sh <ticket>

Print a ticket's details (title, properties/fields, body) as plain text, from the
tracker selected by TRACKER_PROVIDER (notion | jira).

Arguments:
  <ticket>      Ticket key (FM-9, APP-123, or a bare number), a page id, or a URL.

Options:
  -h, --help    Show this help and exit.

Environment:
  TRACKER_PROVIDER  notion | jira (default: notion). Provider creds live in .env.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

[[ $# -ge 1 ]] || die "usage: $(basename "$0") <ticket>   e.g. FM-9, APP-123, 9, or a URL"
tracker_get_details "$1"
