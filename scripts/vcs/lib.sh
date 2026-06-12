#!/usr/bin/env bash
# VCS adapter — shared dispatch for the PR/MR scripts.
# Sourced by the entry scripts (open-pr/pr-view/pr-comment/merge-pr/default-branch).
#
# Selects a provider implementation by VCS_PROVIDER (github | gitlab) and sources
# scripts/vcs/<provider>.sh, which defines the provider interface:
#
#   vcs_require_config                          — ensure the provider CLI is installed
#   vcs_open_pr   BASE HEAD TITLE BODY [DRY]    — create (or reuse) a PR/MR; print URL + number=
#   vcs_pr_view   NUMBER                        — print state=<MERGED|OPEN|CLOSED> + merge_sha=
#   vcs_pr_comment NUMBER PATH LINE BODY [DRY]  — comment (inline at PATH:LINE where supported)
#   vcs_pr_comments NUMBER                      — print the PR/MR's comments as plain text
#   vcs_merge_pr  NUMBER SUBJECT [DRY]          — server-side squash-merge, then print pr-view
#   vcs_close_pr  NUMBER [DRY]                  — close without merging (branch kept), then pr-view
#
# default-branch is provider-neutral (git), so it lives here.
#
# All commands run against the repo in the current working directory.

set -euo pipefail

VCS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$VCS_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$VCS_DIR/.env"
  set +a
fi

die() { echo "error: $*" >&2; exit 1; }
command -v git >/dev/null || die "git is required"

# Resolve the provider: explicit VCS_PROVIDER wins; else sniff the origin remote host.
vcs_detect_provider() {
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  case "$url" in
    *gitlab*) echo gitlab ;;
    *github*) echo github ;;
    *)        echo github ;; # default for github.com-style or unknown remotes
  esac
}

# Provider-neutral default-branch resolution (used by every provider).
vcs_default_branch() {
  local b
  b="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
  [[ -n "$b" ]] || b="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -n1 || true)"
  printf '%s' "${b:-main}"
}

VCS_PROVIDER="${VCS_PROVIDER:-$(vcs_detect_provider)}"
IMPL="$VCS_DIR/$VCS_PROVIDER.sh"
[[ -f "$IMPL" ]] || die "unknown VCS_PROVIDER '$VCS_PROVIDER' (no $IMPL) — use 'github' or 'gitlab', or add $VCS_PROVIDER.sh"

# shellcheck disable=SC1090
. "$IMPL"
vcs_require_config
