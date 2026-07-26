#!/usr/bin/env bash
# Close a PR/MR WITHOUT merging it — the "this should never land" exit.
# Provider-neutral: glab mr close / gh pr close.
#
# Use it when a PR/MR was opened by mistake or its change is being abandoned:
# an MR whose whole diff turned out to be a git-ignored artifact, a duplicate of
# another MR, a branch superseded by a different approach. Closing leaves the
# branch and its history alone — only the review request goes away.
#
# This is NOT the reject path for a review. A reviewer who found problems posts
# them (pr-comment.sh) and loops the author; closing ends the conversation.
#
#   ./close-pr.sh 42
#   ./close-pr.sh 42 --body "Closing: the only diff was a git-ignored plan artifact."
#   ./close-pr.sh 42 --dry-run
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: close-pr.sh <number> [--body <text>] [--dry-run]

Close a PR/MR without merging. The branch is untouched; only the review request ends.

Options:
  --body <text>  Reason to post as a comment before closing (optional but kind).
  --dry-run      Print what would run, without commenting or closing.
  -h, --help     Show this help and exit.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

num=""; body=""; dry=0
need() { [[ -n "${1:-}" ]] || die "$2"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --body)    need "${2:-}" "--body needs a value"; body="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)         num="$1"; shift ;;
  esac
done

[[ -n "$num" ]] || die "usage: $(basename "$0") <number> [--body <text>]"

# Say why first — a closed MR with no note is a dead end for whoever finds it later.
[[ -n "$body" ]] && vcs_pr_comment "$num" "" "" "$body" "$dry"
vcs_close_pr "$num" "$dry"
