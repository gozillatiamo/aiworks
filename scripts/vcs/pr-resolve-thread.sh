#!/usr/bin/env bash
# Check "Resolve thread" on a PR/MR review thread once the developer has addressed the
# comment. Get the <thread-id> from pr-threads.sh. Pass --unresolve to reopen a thread.
#
#   ./pr-resolve-thread.sh 42 <thread-id>              # mark resolved
#   ./pr-resolve-thread.sh 42 <thread-id> --unresolve  # reopen
#   ./pr-resolve-thread.sh 42 <thread-id> --dry-run
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: pr-resolve-thread.sh <number> <thread-id> [--unresolve] [--dry-run]

Marks a PR/MR review thread (a GitLab discussion / GitHub review thread) resolved —
the "Resolve thread" checkbox. The <thread-id> is the `thread=<id>` printed by
pr-threads.sh.

Options:
  --unresolve   Reopen the thread instead of resolving it.
  --dry-run     Print what would be sent, without sending.
  -h, --help    Show this help and exit.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

num=""; tid=""; resolved=true; dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --unresolve) resolved=false; shift ;;
    --dry-run)   dry=1; shift ;;
    -*)          die "unknown option: $1   (see -h)" ;;
    *)           if [[ -z "$num" ]]; then num="$1"; elif [[ -z "$tid" ]]; then tid="$1"; else die "unexpected argument: $1"; fi; shift ;;
  esac
done

[[ -n "$num" && -n "$tid" ]] || die "usage: $(basename "$0") <number> <thread-id> [--unresolve] [--dry-run]"
vcs_pr_resolve_thread "$num" "$tid" "$resolved" "$dry"
