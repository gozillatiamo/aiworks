#!/usr/bin/env bash
# Print the web URL (one per line) of every OPEN PR/MR whose title or source branch
# contains KEY (case-insensitive). Read-only — never creates anything.
#   ./find-prs.sh FM-12   ->  https://gitlab.com/org/repo/-/merge_requests/32
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for a in "$@"; do case "$a" in -h|--help) echo "Usage: find-prs.sh <ticket-key>"; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"
[[ $# -ge 1 ]] || die "usage: $(basename "$0") <ticket-key>"
vcs_find_prs "$1"
