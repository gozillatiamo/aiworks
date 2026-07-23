#!/usr/bin/env bash
# The reviewer's PASS signal on a PR/MR: register a host-level approval (GitLab MR
# approve / GitHub review APPROVE) AND post BODY as one loud, visible verdict line.
# Provider-neutral: glab mr approve / gh pr review --approve.
#
# Approve is DECOUPLED from merge. It says "this cleared the bar" — it does NOT merge.
# The merge stays gated on vcs.auto_merge (see merge-pr.sh) and is a separate, later
# decision. --body is optional; omit it to register the approval alone.
#
#   ./pr-approve.sh 42 --body "✅ APPROVED — FM-9: requirements met, standards clean, 0 must-fix."
#   ./pr-approve.sh 42                 # approval only, no verdict note
#   ./pr-approve.sh 42 --body "…" --dry-run
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: pr-approve.sh <number> [--body <text>] [--dry-run]

Register a host-level approval on a PR/MR and (optionally) post a one-line verdict.
Approving is NOT merging — the merge stays gated on vcs.auto_merge (see merge-pr.sh).

Options:
  --body <text>  One-line PASS verdict to post alongside the approval (optional).
  --dry-run      Print what would run, without approving or posting.
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
vcs_approve_pr "$num" "$body" "$dry"
