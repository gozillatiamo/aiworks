#!/usr/bin/env bash
# VCS adapter — shared dispatch for the PR/MR scripts.
# Sourced by the entry scripts (open-pr/pr-view/pr-comment/merge-pr/default-branch).
#
# Selects a provider implementation by VCS_PROVIDER (github | gitlab) and sources
# scripts/vcs/<provider>.sh, which defines the provider interface:
#
#   vcs_require_config                          — ensure the provider CLI is installed
#   vcs_open_pr   BASE HEAD TITLE BODY [DRY]    — create (or reuse) a PR/MR; print URL + number=
#   vcs_find_prs  KEY                           — print URLs of OPEN PRs/MRs whose title/branch contains KEY (read-only)
#   vcs_pr_view   NUMBER                        — print state=<MERGED|OPEN|CLOSED> + merge_sha=
#   vcs_pr_comment NUMBER PATH LINE BODY [DRY]  — comment (inline at PATH:LINE where supported)
#   vcs_pr_comments NUMBER                      — print the PR/MR's comments as plain text
#   vcs_pr_threads NUMBER                       — list resolvable review threads + their ids/state
#   vcs_pr_resolve_thread NUMBER THREAD_ID [RESOLVED=true] [DRY] — check/uncheck "Resolve thread"
#   vcs_merge_pr  NUMBER SUBJECT [DRY]          — server-side squash-merge, then print pr-view
#   vcs_close_pr  NUMBER [DRY]                  — close without merging (branch kept), then pr-view
#   vcs_upload_media KEY FILE [DRY]             — host one media file, print its embeddable markdown line
#
# default-branch and the media helpers below are provider-neutral, so they live here.
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

# ── Media helpers (shared by the providers' vcs_upload_media) ─────────────────────
# Images render inline in a PR/MR body; everything else (video, zip, log) is linked,
# because most hosts only inline-play video for their own native web uploads — a link
# is the honest, always-works fallback. Extension-based, lowercased.
vcs_is_image() {
  case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
    png|jpg|jpeg|gif|webp|svg|bmp|avif) return 0 ;;
    *) return 1 ;;
  esac
}

# A file is "media" worth attaching if it's an image or a common screen-capture video.
vcs_is_media() {
  vcs_is_image "$1" && return 0
  case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
    mp4|mov|webm|m4v|mkv) return 0 ;;
    *) return 1 ;;
  esac
}

# Render one embeddable markdown line: image syntax for images, a link otherwise.
vcs_media_md() {
  local label="$1" url="$2" name="$3"
  if vcs_is_image "$name"; then printf '![%s](%s)\n' "$label" "$url"
  else printf '[%s](%s)\n' "$label" "$url"; fi
}

# Asset names live in URLs/headers — keep them URL-safe and namespaced by ticket.
vcs_media_asset_name() {
  local key="$1" base="$2" name
  name="$(printf '%s' "$base" | tr ' ' '-' | sed 's/[^A-Za-z0-9._-]//g')"
  printf '%s%s' "${key:+${key}-}" "$name"
}

VCS_PROVIDER="${VCS_PROVIDER:-$(vcs_detect_provider)}"
IMPL="$VCS_DIR/$VCS_PROVIDER.sh"
[[ -f "$IMPL" ]] || die "unknown VCS_PROVIDER '$VCS_PROVIDER' (no $IMPL) — use 'github' or 'gitlab', or add $VCS_PROVIDER.sh"

# shellcheck disable=SC1090
. "$IMPL"
vcs_require_config
