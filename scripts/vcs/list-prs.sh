#!/usr/bin/env bash
# Print every OPEN PR/MR in the repo of the current directory, one TSV line each:
#   <number> <TAB> <draft yes|no> <TAB> <author> <TAB> <updated YYYY-MM-DD> <TAB> <title> <TAB> <url>
#
#   ./list-prs.sh                      # this repo
#   ./list-prs.sh --ready              # skip drafts — the set actually waiting on a reviewer
#
# Read-only; never creates, comments, approves or merges anything. Provider-neutral
# (glab / gh) — this is the sanctioned way to enumerate open PRs/MRs, so nothing else in the
# workspace has to reach for the provider CLI directly.
#
# Sibling to find-prs.sh: that one answers "where is ticket X?" from a key, this one answers
# "what is waiting?" and therefore needs the whole open set plus the fields a reviewer triages on.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ready_only=0
for a in "$@"; do
  case "$a" in
    -h|--help) echo "Usage: list-prs.sh [--ready]"; exit 0 ;;
    --ready)   ready_only=1 ;;
  esac
done
# shellcheck source=lib.sh
. "$DIR/lib.sh"
if [[ "$ready_only" == "1" ]]; then
  vcs_list_prs | awk -F'\t' '$2 == "no"'
else
  vcs_list_prs
fi
