#!/usr/bin/env bash
# Post a comment ONCE and keep updating that same comment on every later run.
#
# The comment is identified by a MARKER its body carries — normally a visible first line
# naming the context it reports on, e.g. "[test-report · e2e-suite]". A ticket
# touched by four test-suite repos therefore carries four durable comments, one per repo,
# each rewritten in place instead of appended to on every re-run.
#
#   ./upsert-ticket-comment.sh APP-123 --marker '[test-report · e2e-suite]' < report.md
#   ./upsert-ticket-comment.sh APP-123 --marker '[test-report · load-suite]' "…text…"
#   ./upsert-ticket-comment.sh APP-123 --marker '…' < report.md --dry-run
#
# The marker MUST appear in the text you post, or the next run cannot find what it wrote —
# this script refuses the call rather than posting an orphan.
#
# ONE RECORD, SEVERAL WRITERS. With --section, the body you pass is not the whole record but one
# SECTION of it, under a heading you own — so a ticket touched by four repos carries ONE comment
# with four `### <repo>` sections instead of four comments:
#
#   ./upsert-ticket-comment.sh APP-123 --marker '[dev · APP-123]' --section '### web-app' < sec.md
#
# The section body starts with its own heading line and needs no marker (this script owns the
# marker line). The record is re-read, the block under that heading replaced (or appended) and the
# result written back, under a local lock keyed by ticket+marker so two repos building in parallel
# cannot lose each other's section.
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
Usage: upsert-ticket-comment.sh <ticket> --marker <text> [--section <heading>] [text] [--dry-run]

Update the comment carrying <marker> if it exists, else add it. Markdown is rendered to the
tracker's native style, exactly like add-ticket-comment.sh.

Arguments:
  <ticket>         Ticket key (FM-9, APP-123, a number), a page id, or a URL.
  [text]           The comment body. If omitted, it is read from stdin.

Options:
  --marker <text>  The identifying text. MUST also appear in the body being posted.
  --section <h>    Write only the block under heading <h> (e.g. '### web-app') inside the marked
                   record, leaving every other section untouched. The text must then START with
                   that heading line, and carries no marker — this script writes the marker line.
  --dry-run        Print what would be sent, without writing.
  -h, --help       Show this help and exit.

Environment:
  TRACKER_PROVIDER notion | jira | linear (default: notion).
USAGE
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

ticket=""; marker=""; section=""; text=""; have_text=0; dry=0
need() { [[ -n "${1:-}" ]] || die "$2"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --marker)  need "${2:-}" "--marker needs a value"; marker="$2"; shift 2 ;;
    --section) need "${2:-}" "--section needs a heading, e.g. '### web-app'"; section="$2"; shift 2 ;;
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

if [[ -n "$section" ]]; then
  # Section mode: the marker line belongs to the record, not to this writer's block. What IS
  # refused is a body that does not open with the heading it claims to own — that would splice a
  # foreign block in under someone else's name, or append a nameless one nobody can find again.
  first="${text%%$'\n'*}"; first="${first%"${first##*[![:space:]]}"}"
  head_trimmed="${section%"${section##*[![:space:]]}"}"
  [[ "$first" == "$head_trimmed" ]] || die "the body's first line is '$first' but --section is '$head_trimmed' — a section body must start with its own heading."

  # A ticket's repos build in PARALLEL, and this is a read-modify-write: without the lock two
  # sections land on the same record and the slower writer's read is already stale, so it posts a
  # body missing the other's block. Same-machine lock — one dev-cycle run, one host.
  # ponytail: a directory lock, no flock (absent on macOS); a writer on a second host could still
  # clobber — move to a provider-side compare-and-set if that ever becomes real.
  lock_key="$(printf '%s' "$ticket|$marker" | cksum)"; lock_key="${lock_key%% *}"
  lock_dir="${TMPDIR:-/tmp}/tracker-record-${lock_key}.lock"
  waited=0
  until mkdir "$lock_dir" 2>/dev/null; do
    # A crashed writer must not wedge every later run: reclaim a lock nobody has touched in 5min.
    [[ -n "$(find "$lock_dir" -maxdepth 0 -mmin +5 2>/dev/null)" ]] && rmdir "$lock_dir" 2>/dev/null && continue
    waited=$((waited + 1))
    [[ "$waited" -lt 120 ]] || die "another writer has held $lock_dir for 2 minutes — remove it if that process is gone"
    sleep 1
  done
  trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT

  found="$(tracker_find_comment "$ticket" "$marker" || true)"
  if [[ -n "$found" ]]; then
    text="$(tracker_section_splice "${found#*$'\n'}" "$section" "$text")"
  else
    text="**$marker**"$'\n\n'"$text"
  fi
fi

# An unmarked body is an orphan: it posts fine now and is invisible to the next run, which then
# posts a second one. That is the exact failure this script exists to remove, so refuse it here
# rather than let it re-appear as duplicate comments a week later.
case "$text" in
  *"$marker"*) : ;;
  *) die "the body does not contain the marker '$marker' — the next run could not find this comment to update. Put the marker in the text." ;;
esac

existing="${found-$(tracker_find_comment "$ticket" "$marker" || true)}"
if [[ -n "$existing" ]]; then
  tracker_edit_comment "$ticket" "${existing%%$'\n'*}" "$dry" "$text" "$marker"
else
  # NOT tracker_add_comment: the record must be findable again by its marker on the next run, and
  # on a provider whose comments cannot be rewritten that means it is not stored as a comment.
  tracker_add_marked "$ticket" "$dry" "$text" "$marker"
fi
