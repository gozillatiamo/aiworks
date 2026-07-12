#!/usr/bin/env bash
# The reviewer's PASS signal — register a host approval (GitHub review APPROVE /
# GitLab MR approve) and post BODY as one loud verdict line. Decoupled from
# merging: approve says "cleared the bar"; merging stays gated on vcs.auto_merge
# (see merge-pr.sh).
#
#   ./pr-approve.sh 42 --body "✅ APPROVED — FM-9: requirements met, standards clean, 0 must-fix."
#   ./pr-approve.sh 42 --body "…" --dry-run
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: pr-approve.sh <number> [--body <text>] [--dry-run]

Options:
  --body <text>  Verdict line posted as the approval's summary (optional).
  --dry-run      Print what would run, without approving.
  -h, --help     Show this help and exit.
USAGE
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

num=""; body=""; dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --body)    body="${2:-}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)         num="$1"; shift ;;
  esac
done

[[ -n "$num" ]] || die "usage: $(basename "$0") <number> [--body <text>]"
vcs_approve_pr "$num" "$body" "$dry"
