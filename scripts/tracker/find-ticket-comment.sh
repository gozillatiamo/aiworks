#!/usr/bin/env bash
# Find the ONE comment on a ticket that carries an identifying MARKER, and print it:
#
#   line 1     the comment id (what edit-ticket-comment.sh takes)
#   line 2..n  the comment's body, rendered back to text
#
# Nothing at all — exit 0, no output — when no comment carries the marker. That is the normal
# "first run" answer, not an error: the caller then posts a fresh comment.
#
#   ./find-ticket-comment.sh APP-123 --marker '[test-report · e2e-suite]'
#   ./find-ticket-comment.sh APP-123 --marker '[test-report · e2e-suite]' --id-only
#
# READ-ONLY, so it may be piped freely (unlike the tracker WRITERS — see ../../CLAUDE.md).
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: find-ticket-comment.sh <ticket> --marker <text> [--id-only]

Print the marked comment's id (line 1) and body (line 2+), or nothing when absent.

Arguments:
  <ticket>          Ticket key (FM-9, APP-123, a number), a page id, or a URL.

Options:
  --marker <text>   The identifying text the comment's body contains. Matched against the
                    RENDERED text, so it must be a line a human can see — an HTML comment
                    does not survive the Markdown → tracker → text round trip.
  --section <h>     Print only the block under heading <h> (e.g. '### web-app') — for a record
                    several agents co-write, one section each. Nothing when that heading is
                    absent, exactly as for a missing record.
  --id-only         Print only the comment id.
  -h, --help        Show this help and exit.

Environment:
  TRACKER_PROVIDER  notion | jira | linear (default: notion). Only jira can update a comment
                    in place; the others print nothing here, on purpose.
USAGE
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

ticket=""; marker=""; section=""; id_only=0
need() { [[ -n "${1:-}" ]] || die "$2"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --marker)  need "${2:-}" "--marker needs a value"; marker="$2"; shift 2 ;;
    --section) need "${2:-}" "--section needs a heading, e.g. '### web-app'"; section="$2"; shift 2 ;;
    --id-only) id_only=1; shift ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)         ticket="$1"; shift ;;
  esac
done

[[ -n "$ticket" ]] || die "usage: $(basename "$0") <ticket> --marker <text>   (see -h)"
[[ -n "$marker" ]] || die "--marker is required — without it there is nothing to identify the comment by"

found="$(tracker_find_comment "$ticket" "$marker")"
[[ -n "$found" ]] || exit 0
if [[ "$id_only" -eq 1 ]]; then printf '%s\n' "${found%%$'\n'*}"; exit 0; fi

if [[ -n "$section" ]]; then
  block="$(tracker_section_extract "${found#*$'\n'}" "$section")"
  [[ -n "$block" ]] || exit 0
  printf '%s\n%s\n' "${found%%$'\n'*}" "$block"
else
  printf '%s\n' "$found"
fi
