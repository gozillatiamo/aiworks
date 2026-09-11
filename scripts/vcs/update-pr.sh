#!/usr/bin/env bash
# Re-describe an OPEN PR/MR — its title, its body, or both.
# Provider-neutral: `gh pr edit --title/--body-file` / PUT /merge_requests/:iid (title, description).
#
# This is the repair for a description that has gone STALE: a design that changed under review, a
# claim a later commit disproved, a mechanism that moved. Before this existed the adapter could
# open a PR/MR and retarget one but never re-describe one, so the only routes were leaving the
# text wrong or reaching for `gh`/`glab` directly — which this workspace forbids, and for good
# reason: a description is what a reviewer reads instead of the diff.
#
# It does NOT touch the branch, the target, the approvals or the comments. A body passed here
# REPLACES the whole description; it is not appended. If you mean to add a remark to the
# conversation rather than correct the record, that is `pr-comment.sh`.
#
#   ./update-pr.sh 42 --body-file ./pr-body.md
#   ./update-pr.sh 42 --title "feat(FM-9): add pet" --body "one line"
#   ./update-pr.sh 42 --body-file - --dry-run
#
# ⚠️ A WRITER: run it BARE. Never in a pipe, `&&`, `;`, `$( )` or a heredoc — the allow rules
# match the whole command string, so a compound call is denied silently (../../CLAUDE.md).
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: update-pr.sh <number> [--title <t>] [--body <b> | --body-file <path>] [--dry-run]

Replace the title and/or the description of an open PR/MR. At least one of them is required.

Arguments:
  <number>            PR/MR number (the iid GitLab prints, the number GitHub prints).

Options:
  --title <text>      New title. Omit to leave the title alone.
  --body  <text>      New description. REPLACES the whole body, never appends.
  --body-file <path>  Same as --body, but read the Markdown from a file ("-" = stdin).
                      Use this for anything longer than a line: a writer must run BARE, and
                      --body "$(cat file)" is a command substitution, i.e. a compound command
                      the adapter guard denies. Mirrors open-pr.sh.
  --dry-run           Print the call, change nothing.
  -h, --help          Show this help and exit.

Prints "updated=<number>" so a caller can assert the write landed rather than trusting it.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

num=""; title=""; body=""; dry=0
need() { [[ -n "${1:-}" ]] || die "$2"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)     need "${2:-}" "--title needs a value"; title="$2"; shift 2 ;;
    --body)      need "${2:-}" "--body needs a value"; body="$2"; shift 2 ;;
    --body-file) [[ -n "${2:-}" ]] || die "--body-file needs a path"
                 if [[ "$2" == "-" ]]; then body="$(cat)"; else [[ -f "$2" ]] || die "--body-file: no such file: $2"; body="$(cat "$2")"; fi
                 shift 2 ;;
    --dry-run)   dry=1; shift ;;
    -*)          die "unknown option: $1   (see -h)" ;;
    *)           num="$1"; shift ;;
  esac
done

[[ -n "$num" ]] || die "usage: $(basename "$0") <number> [--title <t>] [--body <b> | --body-file <path>]"
[[ -n "$title" || -n "$body" ]] || die "nothing to update — pass --title, --body or --body-file"

vcs_pr_describe "$num" "$title" "$body" "$dry"
