#!/usr/bin/env bash
# Repoint an OPEN PR/MR at a different target/base branch.
# Provider-neutral: PUT /merge_requests/:iid (target_branch) / gh pr edit --base.
#
# This is the repair for a PR/MR that targets the wrong branch — the run's base was overridden
# and something downstream re-derived it, or a branch model answered "where does a branch of this
# shape USUALLY go" instead of "where did this run say". Retargeting keeps the review: both forges
# hold existing approvals across a base change, while the only route before this script — close
# the wrong one, open a correctly-targeted one — does not, so repairing four mis-targeted MRs also
# destroyed four approvals that then had to be rebuilt by hand.
#
# It does NOT decide what the right base is. Pass the base the run recorded; if you are guessing,
# stop and read the run's own resolved-base line instead.
#
#   ./retarget-pr.sh 42 --base develop
#   ./retarget-pr.sh 42 --base release/1.4 --dry-run
#
# ⚠️ A WRITER: run it BARE. Never in a pipe, `&&`, `;`, `$( )` or a heredoc — the allow rules
# match the whole command string, so a compound call is denied silently (../../CLAUDE.md).
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: retarget-pr.sh <number> --base <branch> [--dry-run]

Change which branch an open PR/MR targets. Approvals survive; the source branch is untouched.

Arguments:
  <number>        PR/MR number (the iid GitLab prints, the number GitHub prints).

Options:
  --base <branch> The branch it must target. Required.
  --dry-run       Print the call, change nothing.
  -h, --help      Show this help and exit.

Reads the result back from the forge and prints "target_branch=<branch>", so a caller can
assert the change landed rather than trusting the write.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

num=""; base=""; dry=0
need() { [[ -n "${1:-}" ]] || die "$2"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)    need "${2:-}" "--base needs a value"; base="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)         num="$1"; shift ;;
  esac
done

[[ -n "$num" ]]  || die "usage: $(basename "$0") <number> --base <branch>"
[[ -n "$base" ]] || die "--base is required — this script does not infer a base, it applies the one you name"

vcs_pr_retarget "$num" "$base" "$dry"
