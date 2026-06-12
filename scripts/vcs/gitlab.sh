#!/usr/bin/env bash
# GitLab implementation of the VCS interface (the `glab` CLI). Sourced by ../lib.sh.
#
# Flags target a recent glab (≥ ~1.40). If your glab differs, this single file is the
# only place to adjust — the rest of the workspace calls the provider-neutral entries.
# "PR" in the interface == GitLab "merge request" (MR); a PR number == the MR IID.

vcs_require_config() {
  command -v glab >/dev/null || die "glab (GitLab CLI) is required — https://gitlab.com/gitlab-org/cli (run 'glab auth login')"
  command -v jq   >/dev/null || die "jq is required for the GitLab adapter"
}

# vcs_open_pr BASE HEAD TITLE BODY [DRY] -> prints "<url>" then "number=<iid>".
# Every MR is opened with "Squash commits when merge request is accepted" CHECKED
# (--squash-before-merge=true). This guarantees a squash even when a human merges the
# open MR from the web UI (the path taken when vcs.auto_merge is off) — mirroring the
# server-side --squash in vcs_merge_pr below, so the parent branch always gets one commit.
vcs_open_pr() {
  local base="$1" head="$2" title="$3" body="$4" dry="${5:-0}"
  # Reuse an open MR for this source branch (avoid duplicates).
  local existing url iid
  existing="$(glab api "projects/:fullpath/merge_requests?source_branch=$head&state=opened" 2>/dev/null \
              | jq -r '.[0].web_url // empty' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    iid="${existing##*/}"
    printf '%s\nnumber=%s\n' "$existing" "$iid"
    return 0
  fi
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — git push -u origin %q && glab mr create -s %q -b %q -t %q -d <…> --squash-before-merge=true -y\n' "$head" "$head" "$base" "$title"
    return 0
  fi
  git push -u origin "$head" >/dev/null 2>&1 || true
  local out
  out="$(glab mr create --source-branch "$head" --target-branch "$base" --title "$title" --description "$body" --squash-before-merge=true --yes 2>&1)"
  url="$(printf '%s' "$out" | grep -oE 'https?://[^ ]+/merge_requests/[0-9]+' | head -n1)"
  [[ -n "$url" ]] || { printf '%s\n' "$out" >&2; die "could not parse the MR URL from glab output"; }
  iid="${url##*/}"
  printf '%s\nnumber=%s\n' "$url" "$iid"
}

# vcs_pr_view NUMBER -> "state=<MERGED|OPEN|CLOSED>" + "merge_sha=<sha>".
vcs_pr_view() {
  local num="$1" json state sha up
  if ! json="$(glab api "projects/:fullpath/merge_requests/$num" 2>/dev/null)"; then
    printf 'state=UNKNOWN\nmerge_sha=\n'; return 0
  fi
  state="$(printf '%s' "$json" | jq -r '.state // "unknown"')"
  sha="$(printf '%s' "$json" | jq -r '.merge_commit_sha // .squash_commit_sha // ""')"
  # Normalize GitLab states to the interface's vocabulary.
  case "$state" in
    merged)        up=MERGED ;;
    opened)        up=OPEN ;;
    closed|locked) up=CLOSED ;;
    *)             up="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')" ;;
  esac
  printf 'state=%s\nmerge_sha=%s\n' "$up" "$sha"
}

# vcs_pr_comment NUMBER PATH LINE BODY [DRY] — posts an MR note (referencing PATH:LINE
# in the text). Positioned inline discussions are GitLab-version-specific; a note is
# the robust cross-version choice and keeps the reviewer's content intact.
vcs_pr_comment() {
  local num="$1" path="$2" line="$3" body="$4" dry="${5:-0}"
  local full="$body"
  [[ -n "$path" ]] && full="${path}${line:+:$line} — ${body}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — glab mr note %s --message %q\n' "$num" "$full"; return 0
  fi
  glab mr note "$num" --message "$full" >/dev/null
  printf 'Comment posted on MR !%s\n' "$num"
}

# vcs_pr_comments NUMBER -> prints the MR's notes as plain text.
vcs_pr_comments() {
  local num="$1"
  glab mr view "$num" --comments 2>/dev/null && return 0
  # Fallback: render notes via the API.
  glab api "projects/:fullpath/merge_requests/$num/notes" 2>/dev/null \
    | jq -r '.[] | select(.system==false) | "\(.author.name)  \(.created_at)\n  \(.body)\n"' 2>/dev/null \
    || die "could not read notes for MR !$num"
}

# vcs_close_pr NUMBER [DRY] -> close the MR without merging (branch kept), then pr-view.
vcs_close_pr() {
  local num="$1" dry="${2:-0}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — glab mr close %s\n' "$num"; return 0
  fi
  glab mr close "$num"
  vcs_pr_view "$num"
}

# vcs_merge_pr NUMBER SUBJECT [DRY] -> squash-merge server-side (MR shows Merged), then pr-view.
# The squash commit message defaults to the MR title (== SUBJECT, since we open the MR with it).
vcs_merge_pr() {
  local num="$1" subject="$2" dry="${3:-0}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — glab mr merge %s --squash --remove-source-branch --yes\n' "$num"; return 0
  fi
  glab mr merge "$num" --squash --remove-source-branch --yes
  vcs_pr_view "$num"
}
