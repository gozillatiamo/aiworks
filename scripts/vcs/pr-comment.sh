#!/usr/bin/env bash
# Comment on a PR/MR — inline at PATH:LINE where the provider supports it, else a
# normal PR/MR comment that references PATH:LINE in its text.
#
# Review-comment convention (all reviewers): a review comment MUST anchor to the
# code — pass --path + --line so it lands inline at the exact spot, AND quote the
# offending line/block as a fenced code snippet in --body. No vague, location-less
# review comments.
#
#   ./pr-comment.sh 42 --path lib/foo.dart --line 88 \
#       --body $'Guard the null case.\n\n```dart\nfinal pet = cache[id]; // can be null\nreturn pet.name;       // NPE if absent\n```'
#   ./pr-comment.sh 42 --body "Overall LGTM."
#   ./pr-comment.sh 42 --path … --line … --body … --dry-run
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: pr-comment.sh <number> --body <text> [--path <file> --line <n>] [--dry-run]

Options:
  --body <text>  Comment body (required).
  --path <file>  File to anchor an inline comment to (optional).
  --line <n>     Line number for the inline comment (optional; needs --path).
  --dry-run      Print what would be posted, without posting.
  -h, --help     Show this help and exit.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

num=""; path=""; line=""; body=""; dry=0
need() { [[ -n "${1:-}" ]] || die "$2"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)    need "${2:-}" "--path needs a value"; path="$2"; shift 2 ;;
    --line)    need "${2:-}" "--line needs a value"; line="$2"; shift 2 ;;
    --body)    need "${2:-}" "--body needs a value"; body="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)         num="$1"; shift ;;
  esac
done

[[ -n "$num" ]]  || die "usage: $(basename "$0") <number> --body <text> [--path <f> --line <n>]"
[[ -n "$body" ]] || die "--body is required (see -h)"
vcs_pr_comment "$num" "$path" "$line" "$body" "$dry"
