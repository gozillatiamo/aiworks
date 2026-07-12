#!/usr/bin/env bash
# Add a comment to a ticket in the configured tracker.
#
#   ./add-ticket-comment.sh FM-9 "Looks good — moving to Testing."
#   ./add-ticket-comment.sh FM-9 < notes.md       # comment text from stdin
#   cat plan.md | ./add-ticket-comment.sh APP-123
#   ./add-ticket-comment.sh FM-9 "..." --dry-run  # preview, don't send
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: add-ticket-comment.sh <ticket> [text] [--dry-run]

Add an open comment to a ticket in the configured tracker (TRACKER_PROVIDER). The
comment text comes from the [text] argument, or from stdin when none is given.

Arguments:
  <ticket>      Ticket key (FM-9, APP-123, a number), a page id, or a URL.
  [text]        The comment body. If omitted, it is read from stdin.

Options:
  --dry-run     Print the request body instead of sending it.
  -h, --help    Show this help and exit.

Environment:
  TRACKER_PROVIDER  notion | jira | linear (default: notion). Provider creds live in .env.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

ticket=""; text=""; have_text=0; dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)
      if [[ -z "$ticket" ]]; then ticket="$1"; else text="$1"; have_text=1; fi
      shift ;;
  esac
done

[[ -n "$ticket" ]] || die "usage: $(basename "$0") <ticket> [text]   (see -h)"

# No text argument → read it from stdin (a redirected file or a pipe).
if [[ "$have_text" -eq 0 && ! -t 0 ]]; then text="$(cat)"; fi
[[ -n "$text" ]] || die "no comment text — pass it as an argument or pipe it via stdin"

tracker_add_comment "$ticket" "$dry" "$text"
