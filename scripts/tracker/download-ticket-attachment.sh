#!/usr/bin/env bash
# Download one of a ticket's attachments to a local path, so an agent can view it
# (e.g. Read an image) instead of relying on the description text alone.
#
#   ./download-ticket-attachment.sh FM-9 mockup.png /tmp/mockup.png
#   ./download-ticket-attachment.sh APP-123 10042 /tmp/spec.pdf     # Jira: filename or id
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: download-ticket-attachment.sh <ticket> <ref> <dest>

Download one attachment from a ticket in the configured tracker (TRACKER_PROVIDER)
to a local file. Run get-ticket-attachments.sh first to see what <ref> should be.

Arguments:
  <ticket>      Ticket key (FM-9, APP-123, a number), a page id, or a URL.
  <ref>         Which attachment: Jira takes a filename or attachment id
                (from get-ticket-attachments.sh); Notion takes the direct URL
                printed inline by get-ticket-details.sh.
  <dest>        Local path to write the file to.

Options:
  -h, --help    Show this help and exit.

Environment:
  TRACKER_PROVIDER  notion | jira (default: notion). Provider creds live in .env.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

[[ $# -ge 3 ]] || die "usage: $(basename "$0") <ticket> <ref> <dest>   (see -h)"
tracker_download_attachment "$1" "$2" "$3"
