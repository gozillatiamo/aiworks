#!/usr/bin/env bash
# Print a PR/MR's state, merge SHA, and whether the forge already records an approval.
#   ./pr-view.sh 42                ->  state=MERGED
#                                      merge_sha=abc123…
#                                      approved=no
#   ./pr-view.sh 42 --approved     ->  no          (just the one word, for a scripted check)
#
# approved= is yes | no | unknown. UNKNOWN IS NOT NO: it means this forge would not answer
# (approvals disabled on the instance, an API refusal), and a caller must never skip a review
# gate on an unanswered question — treat unknown as unapproved and review.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for a in "$@"; do case "$a" in -h|--help) echo "Usage: pr-view.sh <number> [--approved]"; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

num=""; approved_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --approved|--approved-only) approved_only=1; shift ;;
    -*) die "unknown option: $1   (see -h)" ;;
    *)  num="$1"; shift ;;
  esac
done
[[ -n "$num" ]] || die "usage: $(basename "$0") <number> [--approved]"

if [[ "$approved_only" -eq 1 ]]; then vcs_pr_approved "$num"; else vcs_pr_view "$num"; fi
