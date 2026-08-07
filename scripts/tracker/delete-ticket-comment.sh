#!/usr/bin/env bash
# Delete one comment from a ticket in the configured tracker. DESTRUCTIVE.
#
#   ./delete-ticket-comment.sh OFB-9 43859 --dry-run
#   ./delete-ticket-comment.sh OFB-9 43859 --yes
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: delete-ticket-comment.sh <ticket> <comment-id> (--yes | --dry-run)

Delete ONE comment from a ticket in the configured tracker (TRACKER_PROVIDER).
Jira: supported. Notion: not implemented (its API cannot delete a comment).

IRREVERSIBLE — Jira keeps no trash for comments. This is the counterpart to
edit-ticket-comment.sh, for a comment that should not exist at all (a probe, a
duplicate, a post on the wrong ticket). To CORRECT a comment, edit it instead:
the discussion keeps its place in the thread.

Arguments:
  <ticket>       Ticket key (OFB-9, a number), a page id, or a URL.
  <comment-id>   The comment's id. List them with: get-ticket-comments.sh <ticket>

Options:
  --yes          Confirm the deletion. Required unless --dry-run.
  --dry-run      Print the request instead of sending it.
  -h, --help     Show this help and exit.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

ticket=""; cid=""; dry=0; yes=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --yes)     yes=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)
      if [[ -z "$ticket" ]]; then ticket="$1"; elif [[ -z "$cid" ]]; then cid="$1"; else die "unexpected argument: $1"; fi
      shift ;;
  esac
done

[[ -n "$ticket" ]] || die "usage: $(basename "$0") <ticket> <comment-id> (--yes | --dry-run)"
[[ -n "$cid" ]]    || die "usage: $(basename "$0") <ticket> <comment-id> (--yes | --dry-run)"
if [[ "$dry" -eq 0 && "$yes" -eq 0 ]]; then
  die "refusing to delete without --yes (deleting a comment cannot be undone). Preview it with --dry-run first."
fi

tracker_delete_comment "$ticket" "$dry" "$cid"
