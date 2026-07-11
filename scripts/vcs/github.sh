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

# vcs_find_prs KEY -> print the url (one per line) of every OPEN PR whose TITLE or head
# BRANCH contains KEY (case-insensitive). Read-only — never creates anything. Relies on
# the team convention that a ticket's PR carries the ticket key in its Conventional-Commit
# title (e.g. feat(FM-12): …) and/or branch (feature/FM-12).
vcs_find_prs() {
  local key="$1"
  gh pr list --state open --limit 100 --json url,title,headRefName 2>/dev/null \
    | jq -r --arg k "$key" '
        ($k | ascii_downcase) as $kk
        | .[]
        | select(((.title // "")       | ascii_downcase | contains($kk))
              or  ((.headRefName // "") | ascii_downcase | contains($kk)))
        | .url' 2>/dev/null || true
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
# Posts an inline review comment at PATH:LINE when both are given. On ANY failure we DO NOT
# silently drop the anchor — we surface the reason on stderr (with GitHub's actual error)
# and fall back to a normal PR comment that references PATH:LINE, so the content is never
# lost AND the caller is never told "posted inline" when it didn't anchor to the diff.
vcs_pr_comment() {
  local num="$1" path="$2" line="$3" body="$4" dry="${5:-0}"
  local full="$body"
  [[ -n "$path" ]] && full="${path}${line:+:$line} — ${body}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — comment on PR #%s: %s\n' "$num" "$full"; return 0
  fi
  if [[ -n "$path" && -n "$line" ]]; then
    local sha err
    sha="$(gh pr view "$num" --json headRefOid -q .headRefOid 2>/dev/null || true)"
    if [[ -z "$sha" ]]; then
      printf 'WARN: could not read head SHA for PR #%s — posting %s:%s as a NON-inline comment\n' "$num" "$path" "$line" >&2
    elif err="$(gh api "repos/{owner}/{repo}/pulls/$num/comments" \
        -f body="$body" -f commit_id="$sha" -f path="$path" -F line="$line" -f side=RIGHT 2>&1)"; then
      printf 'Inline comment posted on PR #%s at %s:%s\n' "$num" "$path" "$line"; return 0
    else
      printf 'WARN: inline anchor failed for %s:%s on PR #%s — falling back to a NON-inline comment.\n  GitHub said: %s\n' \
        "$path" "$line" "$num" "$(printf '%s' "$err" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-300)" >&2
    fi
  fi
  gh pr comment "$num" --body "$full" >/dev/null || die "failed to post comment on PR #$num"
  if [[ -n "$path" && -n "$line" ]]; then
    printf 'Comment posted on PR #%s (NON-inline comment — see WARN above for why %s:%s did not anchor)\n' "$num" "$path" "$line"
  else
    printf 'Comment posted on PR #%s\n' "$num"
  fi
}

# vcs_pr_comments NUMBER -> prints the PR's comments/review notes as plain text.
vcs_pr_comments() {
  gh pr view "$1" --comments 2>/dev/null || die "could not read comments for PR #$1"
}

# vcs_pr_threads NUMBER -> list the PR's review threads, one block each:
#   ● thread=<node_id>  [unresolved|resolved]  <path>:<line>  (<author>)
#     <comment body…>
# GitHub review threads are resolvable only over GraphQL, keyed by an opaque node id —
# `vcs_pr_comments` (REST) doesn't expose it, so this is the companion read that lets a
# fix be tied back to the exact thread for vcs_pr_resolve_thread.
vcs_pr_threads() {
  local num="$1" nwo owner repo out
  nwo="$(_gh_nwo)"; owner="${nwo%%/*}"; repo="${nwo##*/}"
  out="$(gh api graphql \
      -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{id isResolved path line comments(first:1){nodes{body author{login}}}}}}}}' \
      -F o="$owner" -F r="$repo" -F n="$num" 2>/dev/null \
    | jq -r '
        .data.repository.pullRequest.reviewThreads.nodes[]
        | . as $t
        | ($t.comments.nodes[0] // {}) as $c
        | (if $t.isResolved then "resolved" else "unresolved" end) as $state
        | "● thread=\($t.id)  [\($state)]  "
          + (if ($t.path // "") != "" then $t.path + (if ($t.line != null) then ":" + ($t.line|tostring) else "" end) else "(general)" end)
          + "  (\($c.author.login // "?"))\n"
          + "  " + (($c.body // "") | gsub("\n"; "\n  "))
          + "\n"
      ' 2>/dev/null)" || die "could not read threads for PR #$num"
  if [[ -z "${out//[$'\n\t ']/}" ]]; then
    printf 'No review threads on PR #%s\n' "$num"
  else
    printf '%s\n' "$out"
  fi
}

# vcs_pr_resolve_thread NUMBER THREAD_ID [RESOLVED=true] [DRY]
# Marks a PR review thread resolved (the "Resolve conversation" button) once the developer
# has addressed it. RESOLVED=false reopens it. THREAD_ID is the GraphQL node id printed by
# vcs_pr_threads. NUMBER is only used for the message — the node id is globally unique.
vcs_pr_resolve_thread() {
  local num="$1" tid="$2" resolved="${3:-true}" dry="${4:-0}"
  local mutation word
  if [[ "$resolved" == false ]]; then mutation=unresolveReviewThread; word=unresolved
  else mutation=resolveReviewThread; word=resolved; fi
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — gh api graphql %s(threadId:%s)\n' "$mutation" "$tid"; return 0
  fi
  gh api graphql \
      -f query="mutation(\$id:ID!){$mutation(input:{threadId:\$id}){thread{isResolved}}}" \
      -f id="$tid" >/dev/null \
    || die "could not mark thread $tid on PR #$num $word"
  printf 'Thread %s on PR #%s marked %s\n' "$tid" "$num" "$word"
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

# vcs_approve_pr NUMBER BODY [DRY] -> the reviewer's PASS signal. Submits an APPROVE review
# carrying BODY as its summary, so one call gives both the loud verdict AND the host-level
# approval. BODY is optional. Approve is DECOUPLED from merge: it says "cleared the bar"
# without merging — the merge stays gated on vcs.auto_merge (vcs_merge_pr).
# NOTE: GitHub forbids approving your OWN PR — fine here, the reviewer is not the author.
vcs_approve_pr() {
  local num="$1" body="${2:-}" dry="${3:-0}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — gh pr review %s --approve%s\n' "$num" "${body:+ --body <verdict>}"
    return 0
  fi
  if [[ -n "$body" ]]; then
    gh pr review "$num" --approve --body "$body" || die "failed to approve PR #$num"
  else
    gh pr review "$num" --approve || die "failed to approve PR #$num"
  fi
  printf 'Approved PR #%s\n' "$num"
}
