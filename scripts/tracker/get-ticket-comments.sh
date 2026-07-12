#!/usr/bin/env bash
# Read a ticket's comments from the configured tracker and print them as plain text.
#
#   ./get-ticket-comments.sh FM-9
#   ./get-ticket-comments.sh --deep FM-9   # Notion: also inline (block-anchored) comments
#   ./get-ticket-comments.sh <id|url>
#
# --deep only affects providers that anchor comments to sub-blocks (Notion); for
# trackers with a single comment stream (Jira) it is a no-op.
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: get-ticket-comments.sh [--deep] <ticket>

Print a ticket's open comments as plain text, from the tracker selected by
TRACKER_PROVIDER (notion | jira | linear).

Arguments:
  <ticket>            Ticket key (FM-9, APP-123, a number), a page id, or a URL.

Options:
  --deep              Also gather inline (block-anchored) comments where the
                      provider supports them (Notion). No-op otherwise.
  -h, --help          Show this help and exit.

Environment:
  TRACKER_PROVIDER    notion | jira | linear (default: notion).
  NOTION_CONCURRENCY  Parallel requests used by --deep on Notion (default 8).
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

# Internal parallel-worker mode (used by the provider's --deep fan-out). The
# provider impl decides what to write; no-op for providers without block comments.
if [[ "${1:-}" == "--comments-for-block" ]]; then
  tracker_comments_for_block "$2"
  exit 0
fi

deep=0; ticket=""
for a in "$@"; do
  case "$a" in
    --deep) deep=1 ;;
    *)      ticket="$a" ;;
  esac
done
[[ -n "$ticket" ]] || die "usage: $(basename "$0") [--deep] <ticket>   e.g. FM-9, APP-123, 9, or a URL"
tracker_get_comments "$deep" "$ticket"
