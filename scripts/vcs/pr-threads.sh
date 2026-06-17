#!/usr/bin/env bash
# List a PR/MR's resolvable review threads with their thread IDs + resolved state, so a
# pushed fix can be tied back to the exact thread and that thread marked resolved with
# pr-resolve-thread.sh. Plain pr-comments.sh prints the same notes WITHOUT the thread id.
#
#   ./pr-threads.sh 42
#
# Each block:
#   ● thread=<id>  [unresolved|resolved]  <path>:<line>  (<author>)
#     <author>: <comment body…>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for a in "$@"; do case "$a" in -h|--help) echo "Usage: pr-threads.sh <number>"; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"
[[ $# -ge 1 ]] || die "usage: $(basename "$0") <number>"
vcs_pr_threads "$1"
