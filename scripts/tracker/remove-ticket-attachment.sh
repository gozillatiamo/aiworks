#!/usr/bin/env bash
# Delete one attachment from a ticket in the configured tracker. DESTRUCTIVE.
#
#   ./remove-ticket-attachment.sh APP-9 APP-9-TC001-fail.png --dry-run   # preview
#   ./remove-ticket-attachment.sh APP-9 APP-9-TC001-fail.png --yes       # do it
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: remove-ticket-attachment.sh <ticket> <filename-or-id> (--yes | --dry-run)

Delete ONE attachment from a ticket in the configured tracker (TRACKER_PROVIDER).
Jira: supported. Notion: not implemented (its uploader isn't either).

DESTRUCTIVE AND IRREVERSIBLE. Jira keeps no trash for attachments: the bytes are
gone, and any comment or description that embedded the file by id is left pointing
at nothing. --yes is required so this cannot happen as a side effect of a typo.

Arguments:
  <ticket>            Ticket key (APP-9, a number), a page id, or a URL.
  <filename-or-id>    Which attachment — its filename or its numeric id.
                      List them with: get-ticket-attachments.sh <ticket>

Options:
  --yes         Confirm the deletion. Required unless --dry-run.
  --dry-run     Print the request instead of sending it.
  -h, --help    Show this help and exit.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

ticket=""; ref=""; dry=0; yes=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --yes)     yes=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)
      if [[ -z "$ticket" ]]; then ticket="$1"; elif [[ -z "$ref" ]]; then ref="$1"; else die "unexpected argument: $1"; fi
      shift ;;
  esac
done

[[ -n "$ticket" ]] || die "usage: $(basename "$0") <ticket> <filename-or-id> (--yes | --dry-run)"
[[ -n "$ref" ]]    || die "usage: $(basename "$0") <ticket> <filename-or-id> (--yes | --dry-run)"
[[ "$dry" -eq 1 || "$yes" -eq 1 ]] \
  || die "refusing to delete without --yes (deleting an attachment cannot be undone). Preview it with --dry-run first."

tracker_remove_attachment "$ticket" "$dry" "$ref"
