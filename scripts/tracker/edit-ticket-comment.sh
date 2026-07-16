#!/usr/bin/env bash
# Replace an existing comment's body on a ticket in the configured tracker.
#
#   ./edit-ticket-comment.sh FM-9 10234 "Looks good — moving to Testing."
#   ./edit-ticket-comment.sh FM-9 10234 < notes.md       # comment text from stdin
#   ./edit-ticket-comment.sh FM-9 10234 "..." --dry-run  # preview, don't send
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: edit-ticket-comment.sh <ticket> <comment_id> [text] [--dry-run]

Replace an existing comment's body in the configured tracker (TRACKER_PROVIDER).
Jira: supported (PUT /issue/{key}/comment/{id}). Notion / Linear: not yet
implemented (neither exposes a wired-up comment-update path here) — edit it
manually there.

Arguments:
  <ticket>       Ticket key (FM-9, APP-123, a number), a page id, or a URL.
  <comment_id>   The comment's id — get it via GET /rest/api/3/issue/<key>/comment
                 (get-ticket-comments.sh doesn't print ids; fetch the raw API response
                 to find the one you want to replace).
  [text]         The new comment body. If omitted, it is read from stdin.

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

ticket=""; comment_id=""; text=""; have_text=0; dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)
      if [[ -z "$ticket" ]]; then ticket="$1";
      elif [[ -z "$comment_id" ]]; then comment_id="$1";
      else text="$1"; have_text=1; fi
      shift ;;
  esac
done

[[ -n "$ticket" ]]      || die "usage: $(basename "$0") <ticket> <comment_id> [text]   (see -h)"
[[ -n "$comment_id" ]]  || die "usage: $(basename "$0") <ticket> <comment_id> [text]   (see -h)"

if [[ "$have_text" -eq 0 && ! -t 0 ]]; then text="$(cat)"; fi
[[ -n "$text" ]] || die "no comment text — pass it as an argument or pipe it via stdin"

tracker_edit_comment "$ticket" "$comment_id" "$dry" "$text"
