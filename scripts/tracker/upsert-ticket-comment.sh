#!/usr/bin/env bash
# Post a comment ONCE and keep updating that same comment on every later run.
#
# The comment is identified by a MARKER its body carries — normally a visible first line
# naming the context it reports on, e.g. "[test-report · ofb-k6-loadtests]". A ticket
# touched by four test-suite repos therefore carries four durable comments, one per repo,
# each rewritten in place instead of appended to on every re-run.
#
#   ./upsert-ticket-comment.sh OFB-2245 --marker '[test-report · ofb-k6-loadtests]' < report.md
#   ./upsert-ticket-comment.sh OFB-2245 --marker '[test-report · backoffice]' "…text…"
#   ./upsert-ticket-comment.sh OFB-2245 --marker '…' < report.md --dry-run
#
# The marker MUST appear in the text you post, or the next run cannot find what it wrote —
# this script refuses the call rather than posting an orphan.
#
# ⚠️ A WRITER: run it BARE. Never in a pipe, `&&`, `;`, `$( )` or a heredoc — the allow rules
# match the whole command string, so a compound call is denied silently (../../CLAUDE.md).
# Read the existing comment with find-ticket-comment.sh, which is a reader and may be piped.
#
# Providers: every one updates in place, by the route its API actually offers.
#   jira    — rewrites the comment body.
#   linear  — rewrites the comment body (commentUpdate).
#   notion  — its comment API has no update endpoint at all, so a marked record is kept as ONE
#             callout BLOCK on the page instead: the marker is the callout's own text, the record
#             is its children, and an update archives that block and appends a fresh one. The
#             comment feed is left to humans. A record therefore moves to the bottom of the page
#             each time it is rewritten, which is the honest ordering.
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: upsert-ticket-comment.sh <ticket> --marker <text> [text] [--dry-run]

Update the comment carrying <marker> if it exists, else add it. Markdown is rendered to the
tracker's native style, exactly like add-ticket-comment.sh.

Arguments:
  <ticket>         Ticket key (FM-9, APP-123, a number), a page id, or a URL.
  [text]           The comment body. If omitted, it is read from stdin.

Options:
  --marker <text>  The identifying text. MUST also appear in the body being posted.
  --dry-run        Print what would be sent, without writing.
  -h, --help       Show this help and exit.

Environment:
  TRACKER_PROVIDER notion | jira | linear (default: notion).
USAGE
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

ticket=""; marker=""; text=""; have_text=0; dry=0
need() { [[ -n "${1:-}" ]] || die "$2"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --marker)  need "${2:-}" "--marker needs a value"; marker="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)
      if [[ -z "$ticket" ]]; then ticket="$1"; else text="$1"; have_text=1; fi
      shift ;;
  esac
done

[[ -n "$ticket" ]] || die "usage: $(basename "$0") <ticket> --marker <text> [text]   (see -h)"
[[ -n "$marker" ]] || die "--marker is required — without it this is just add-ticket-comment.sh"

if [[ "$have_text" -eq 0 && ! -t 0 ]]; then text="$(cat)"; fi
[[ -n "$text" ]] || die "no comment text — pass it as an argument or pipe it via stdin"

# An unmarked body is an orphan: it posts fine now and is invisible to the next run, which then
# posts a second one. That is the exact failure this script exists to remove, so refuse it here
# rather than let it re-appear as duplicate comments a week later.
case "$text" in
  *"$marker"*) : ;;
  *) die "the body does not contain the marker '$marker' — the next run could not find this comment to update. Put the marker in the text." ;;
esac

existing="$(tracker_find_comment "$ticket" "$marker" || true)"
if [[ -n "$existing" ]]; then
  tracker_edit_comment "$ticket" "${existing%%$'\n'*}" "$dry" "$text" "$marker"
else
  # NOT tracker_add_comment: the record must be findable again by its marker on the next run, and
  # on a provider whose comments cannot be rewritten that means it is not stored as a comment.
  tracker_add_marked "$ticket" "$dry" "$text" "$marker"
fi
