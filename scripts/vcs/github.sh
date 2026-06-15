#!/usr/bin/env bash
# GitHub implementation of the VCS interface (the `gh` CLI). Sourced by ../lib.sh.

vcs_require_config() {
  command -v gh >/dev/null || die "gh (GitHub CLI) is required — https://cli.github.com (run 'gh auth login')"
}

# vcs_open_pr BASE HEAD TITLE BODY [DRY] -> prints "<url>" then "number=<n>".
# NOTE: GitHub has no per-PR "squash" checkbox to set at create time (unlike GitLab's
# --squash-before-merge) — the merge method is chosen at merge time. Squash is guaranteed
# two ways: the adapter merges with --squash (vcs_merge_pr below), and for human web-UI
# merges (when vcs.auto_merge is off) the repo should allow ONLY squash merging
# (Settings → General → Pull Requests: enable "Allow squash merging", disable merge
# commits + rebase). That repo setting is the GitHub equivalent of "always squash".
vcs_open_pr() {
  local base="$1" head="$2" title="$3" body="$4" dry="${5:-0}"
  # Reuse an open PR for this head branch (avoid duplicates).
  local existing num
  existing="$(gh pr list --head "$head" --state open --json url -q '.[0].url' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    num="$(gh pr list --head "$head" --state open --json number -q '.[0].number' 2>/dev/null)"
    printf '%s\nnumber=%s\n' "$existing" "$num"
    return 0
  fi
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — git push -u origin %q && gh pr create --base %q --head %q --title %q --body <…>\n' "$head" "$base" "$head" "$title"
    return 0
  fi
  git push -u origin "$head" >/dev/null 2>&1 || true
  local url
  url="$(gh pr create --base "$base" --head "$head" --title "$title" --body "$body")"
  num="${url##*/}" # gh prints the PR URL; the number is the trailing path segment
  printf '%s\nnumber=%s\n' "$url" "$num"
}

# vcs_pr_view NUMBER -> "state=<MERGED|OPEN|CLOSED>" + "merge_sha=<sha>".
vcs_pr_view() {
  local num="$1" json state sha
  if ! json="$(gh pr view "$num" --json state,mergeCommit 2>/dev/null)"; then
    printf 'state=UNKNOWN\nmerge_sha=\n'; return 0
  fi
  state="$(printf '%s' "$json" | jq -r '.state // "UNKNOWN"')"
  sha="$(printf '%s' "$json" | jq -r '.mergeCommit.oid // ""')"
  printf 'state=%s\nmerge_sha=%s\n' "$state" "$sha"
}

# vcs_pr_comment NUMBER PATH LINE BODY [DRY]
# Posts an inline review comment at PATH:LINE when both are given (falls back to a
# normal PR comment that references PATH:LINE if the inline API call fails).
vcs_pr_comment() {
  local num="$1" path="$2" line="$3" body="$4" dry="${5:-0}"
  local full="$body"
  [[ -n "$path" ]] && full="${path}${line:+:$line} — ${body}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — comment on PR #%s: %s\n' "$num" "$full"; return 0
  fi
  if [[ -n "$path" && -n "$line" ]]; then
    local sha
    sha="$(gh pr view "$num" --json headRefOid -q .headRefOid 2>/dev/null || true)"
    if [[ -n "$sha" ]] && gh api "repos/{owner}/{repo}/pulls/$num/comments" \
        -f body="$body" -f commit_id="$sha" -f path="$path" -F line="$line" -f side=RIGHT >/dev/null 2>&1; then
      printf 'Inline comment posted on PR #%s at %s:%s\n' "$num" "$path" "$line"; return 0
    fi
  fi
  gh pr comment "$num" --body "$full" >/dev/null
  printf 'Comment posted on PR #%s\n' "$num"
}

# vcs_pr_comments NUMBER -> prints the PR's comments/review notes as plain text.
vcs_pr_comments() {
  gh pr view "$1" --comments 2>/dev/null || die "could not read comments for PR #$1"
}

# vcs_close_pr NUMBER [DRY] -> close the PR without merging (branch kept), then pr-view.
vcs_close_pr() {
  local num="$1" dry="${2:-0}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — gh pr close %s\n' "$num"; return 0
  fi
  gh pr close "$num"
  vcs_pr_view "$num"
}

# vcs_upload_media KEY FILE [DRY] -> host one file and print its embeddable markdown line.
# GitHub has no token-scriptable "attach to the PR body" endpoint (the web drag-and-drop uses
# a private browser session, unreachable from a token), so we host media as assets on a single
# dedicated release (tag: $VCS_MEDIA_RELEASE, default "pr-media") and link the download URL.
# This keeps media OUT of git history (unlike committing it to the branch, which a squash-merge
# would bake into the repo). Images at a release-download URL render inline in markdown; video
# shows as a download link — GitHub only inline-plays its own web uploads, so a link is honest.
# Asset names are namespaced "<KEY>-<file>" and uploaded with --clobber so re-runs overwrite.
# owner/repo for building a release-download URL: ask gh, falling back to parsing the
# origin remote (so a --dry-run preview works offline, before auth or a real repo exists).
_gh_nwo() {
  local nwo url
  nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [[ -n "$nwo" ]] && { printf '%s' "$nwo"; return 0; }
  url="$(git remote get-url origin 2>/dev/null || true)"; url="${url%.git}"
  case "$url" in *github.com[:/]*) printf '%s' "${url#*github.com[:\/]}" ;; *) printf '%s' "$url" ;; esac
}

vcs_upload_media() {
  local key="$1" file="$2" dry="${3:-0}"
  local base; base="$(basename "$file")"
  local asset; asset="$(vcs_media_asset_name "$key" "$base")"
  local label; label="$(printf '%s%s' "${key:+$key }" "$base")"
  local tag="${VCS_MEDIA_RELEASE:-pr-media}"
  local repo; repo="$(_gh_nwo)"
  local url="https://github.com/${repo}/releases/download/${tag}/${asset}"
  if [[ "$dry" -eq 1 ]]; then
    vcs_media_md "$label" "$url" "$base"; return 0
  fi
  [[ -f "$file" ]] || { echo "warn: media file not found: $file" >&2; return 1; }
  [[ -n "$repo" ]] || { echo "warn: could not resolve owner/repo via gh" >&2; return 1; }
  # Ensure the media release exists (idempotent); ignore "already exists".
  gh release view "$tag" >/dev/null 2>&1 \
    || gh release create "$tag" --title "PR media" \
         --notes "Auto-hosted media for PR visual results. Managed by scripts/vcs/." >/dev/null 2>&1 || true
  # gh keys an asset by its on-disk filename, so stage a copy under the namespaced name.
  local tmp; tmp="$(mktemp -d)"
  cp "$file" "$tmp/$asset"
  if gh release upload "$tag" "$tmp/$asset" --clobber >/dev/null 2>&1; then
    rm -rf "$tmp"
    vcs_media_md "$label" "$url" "$base"
  else
    rm -rf "$tmp"
    echo "warn: gh release upload failed for $file" >&2; return 1
  fi
}

# vcs_merge_pr NUMBER SUBJECT [DRY] -> server-side squash-merge (PR shows Merged), then pr-view.
vcs_merge_pr() {
  local num="$1" subject="$2" dry="${3:-0}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — gh pr merge %s --squash --subject %q\n' "$num" "$subject"; return 0
  fi
  # --admin can be added if branch protection blocks a self-merge.
  gh pr merge "$num" --squash --subject "$subject"
  vcs_pr_view "$num"
}
