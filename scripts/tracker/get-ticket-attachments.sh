#!/usr/bin/env bash
# List a ticket's attachments (filename, id, size, mime type) from the configured tracker.
#
#   ./get-ticket-attachments.sh FM-9
#   ./get-ticket-attachments.sh APP-123
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: get-ticket-attachments.sh <ticket>

List a ticket's attachments/images as CORE input — every entry here must be fetched
(download-ticket-attachment.sh) and viewed before treating the ticket as understood;
a ticket's description text alone is not the full spec when attachments exist.

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
tracker_get_attachments "$1"
