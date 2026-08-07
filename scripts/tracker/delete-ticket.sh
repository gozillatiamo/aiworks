#!/usr/bin/env bash
# Delete a whole ticket from the configured tracker. THE MOST DESTRUCTIVE VERB HERE.
#
#   ./delete-ticket.sh APP-9 --dry-run              # preview
#   ./delete-ticket.sh APP-9 --yes                  # do it
#   ./delete-ticket.sh APP-9 --yes --with-subtasks  # and its sub-tasks
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: delete-ticket.sh <ticket> (--yes | --dry-run) [--with-subtasks]

Delete a ticket from the configured tracker (TRACKER_PROVIDER).
Jira: supported (needs the 'Delete Issues' project permission).
Notion: not implemented — Notion ARCHIVES a page (restorable) rather than deleting
it, which is a different guarantee, so it is refused rather than silently mapped.

IRREVERSIBLE. A deleted Jira issue has no trash can: its comments, attachments and
history go with it, and the key is never reused. A mistyped key cannot be undone.
--yes is required for that reason, and the issue's summary is printed before the
delete so you can see which one actually went.

This exists for THROWAWAY tickets — a scratch issue made to prove a rendering or an
integration works. A real ticket that turned out to be wrong should be closed or
moved to a "won't do" status, not deleted: the board's history is worth more than
the tidiness.

Arguments:
  <ticket>          Ticket key (APP-9, a number), a page id, or a URL.

Options:
  --yes             Confirm the deletion. Required unless --dry-run.
  --with-subtasks   Also delete the issue's sub-tasks. Without it, Jira REFUSES to
                    delete an issue that has any (a 400), rather than orphaning them.
  --dry-run         Print the request instead of sending it.
  -h, --help        Show this help and exit.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

ticket=""; dry=0; yes=0; subtasks=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       dry=1; shift ;;
    --yes)           yes=1; shift ;;
    --with-subtasks) subtasks=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    -*)              die "unknown option: $1   (see -h)" ;;
    *)
      if [[ -z "$ticket" ]]; then ticket="$1"; else die "unexpected argument: $1"; fi
      shift ;;
  esac
done

[[ -n "$ticket" ]] || die "usage: $(basename "$0") <ticket> (--yes | --dry-run)"
[[ "$dry" -eq 1 || "$yes" -eq 1 ]] \
  || die "refusing to delete without --yes (deleting a ticket cannot be undone). Preview it with --dry-run first."

tracker_delete_ticket "$ticket" "$dry" "$subtasks"
