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
  # Name the repo explicitly. gh otherwise infers it from the cwd's `origin`, which is the WRONG
  # repo whenever VCS_REMOTE names an upstream (see _gh_nwo) — and inferring also fails outright
  # when the cwd is not inside a checkout of the target.
  local nwo; nwo="$(_gh_nwo_once)"
  existing="$(_gh_pr list --head "$head" --state open --json url -q '.[0].url' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    num="$(_gh_pr list --head "$head" --state open --json number -q '.[0].number' 2>/dev/null)"
    printf '%s\nnumber=%s\n' "$existing" "$num"
    return 0
  fi
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — git push -u %s %q && gh pr create --repo %q --base %q --head %q --title %q --body <…>\n' "$VCS_REMOTE" "$head" "$nwo" "$base" "$head" "$title"
    return 0
  fi
  git push -u "$VCS_REMOTE" "$head" >/dev/null 2>&1 || true
  local url
  url="$(_gh_pr create --base "$base" --head "$head" --title "$title" --body "$body")"
  num="${url##*/}" # gh prints the PR URL; the number is the trailing path segment
  printf '%s\nnumber=%s\n' "$url" "$num"
}

# vcs_find_prs KEY -> print the url (one per line) of every OPEN PR whose TITLE or head
# BRANCH contains KEY (case-insensitive). Read-only — never creates anything. Relies on
# the team convention that a ticket's PR carries the ticket key in its Conventional-Commit
# title (e.g. feat(FM-12): …) and/or branch (feature/FM-12).
vcs_find_prs() {
  local key="$1"
  _gh_pr list --state open --limit 100 --json url,title,headRefName 2>/dev/null \
    | jq -r --arg k "$key" '
        ($k | ascii_downcase) as $kk
        | .[]
        | select(((.title // "")       | ascii_downcase | contains($kk))
              or  ((.headRefName // "") | ascii_downcase | contains($kk)))
        | .url' 2>/dev/null || true
}

# vcs_list_prs -> one TSV line per OPEN PR in the repo of the current directory:
#   number <TAB> draft(yes|no) <TAB> author <TAB> updated(YYYY-MM-DD) <TAB> target <TAB> title <TAB> url
# Read-only. Same contract as the GitLab implementation; see the note there on why this exists
# alongside the key-filtered vcs_find_prs.
vcs_list_prs() {
  _gh_pr list --state open --limit 100 \
      --json number,isDraft,author,updatedAt,baseRefName,title,url 2>/dev/null \
    | jq -r '.[] | [ (.number|tostring),
                     (if .isDraft then "yes" else "no" end),
                     (.author.login // "-"),
                     ((.updatedAt // "")[0:10]),
                     (.baseRefName // "-"),
                     (.title // ""),
                     (.url // "") ] | @tsv' 2>/dev/null || true
}

# vcs_pr_view NUMBER -> "state=", "merge_sha=", "approved=", "target_branch=", "source_branch=".
# See the GitLab implementation for why the branches are printed: a gate cannot assert what the
# sanctioned tool refuses to show, and this call already fetched the PR.
vcs_pr_view() {
  local num="$1" json state sha tgt src
  if ! json="$(_gh_pr view "$num" --json state,mergeCommit,baseRefName,headRefName 2>/dev/null)"; then
    printf 'state=UNKNOWN\nmerge_sha=\napproved=unknown\ntarget_branch=\nsource_branch=\n'; return 0
  fi
  state="$(printf '%s' "$json" | jq -r '.state // "UNKNOWN"')"
  sha="$(printf '%s' "$json" | jq -r '.mergeCommit.oid // ""')"
  tgt="$(printf '%s' "$json" | jq -r '.baseRefName // ""')"
  src="$(printf '%s' "$json" | jq -r '.headRefName // ""')"
  printf 'state=%s\nmerge_sha=%s\napproved=%s\ntarget_branch=%s\nsource_branch=%s\n' \
    "$state" "$sha" "$(vcs_pr_approved "$num")" "$tgt" "$src"
}

# vcs_pr_retarget NUMBER BASE -> repoint an OPEN PR at a different base branch.
# `gh pr edit --base` is the supported route (PATCH /pulls/:n with `base` underneath). GitHub
# dismisses no approval for a base change by default, so this is the non-destructive repair —
# unlike close + reopen, which loses review state.
vcs_pr_retarget() {
  local num="$1" base="$2" dry="${3:-0}" out
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — gh pr edit %s --base %s\n' "$num" "$base"; return 0
  fi
  out="$(_gh_pr edit "$num" --base "$base" 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }
  printf 'target_branch=%s\n' "$(_gh_pr view "$num" --json baseRefName -q '.baseRefName' 2>/dev/null || printf '%s' "$base")"
}

# vcs_pr_approved NUMBER -> prints yes | no | unknown, the forge's own record of whether this
# PR already carries a review approval. "unknown" is NOT "no": it means GitHub would not
# answer, and a caller must never skip a review gate on an unanswered question — treat unknown
# as unapproved and review.
#
# The state is per REVIEWER, latest review wins: an APPROVED that a later CHANGES_REQUESTED
# from the same person superseded is not an approval. Second tier is the approval marker on a
# PR comment, which is what vcs_approve_pr leaves when the repo's rules refuse a review
# (a self-approval, most often) — and what keeps a re-run from stacking a second verdict.
vcs_pr_approved() {
  local num="$1" json
  if json="$(_gh_pr view "$num" --json reviews 2>/dev/null)"; then
    if printf '%s' "$json" | jq -e '
          [(.reviews // [])[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")]
          | group_by(.author.login) | map(last)
          | map(select(.state == "APPROVED")) | length > 0' >/dev/null 2>&1; then
      printf 'yes\n'; return 0
    fi
    if _gh_has_approval_note "$num"; then printf 'yes\n'; return 0; fi
    printf 'no\n'; return 0
  fi
  if _gh_has_approval_note "$num"; then printf 'yes\n'; return 0; fi
  printf 'unknown\n'
}

# _gh_has_approval_note NUMBER -> 0 when a PR comment starts with the approval marker that
# vcs_approve_pr posts when the host-level review is refused.
_gh_has_approval_note() {
  _gh_pr view "$1" --json comments 2>/dev/null \
    | jq -e --arg m "$VCS_APPROVAL_MARKER" 'any((.comments // [])[]; (.body // "") | startswith($m))' >/dev/null 2>&1
}

# vcs_pr_comment NUMBER PATH LINE BODY [DRY]
# Posts an inline review comment at PATH:LINE. LINE is either a single line "N" or an INCLUSIVE
# RANGE "N-M" — a range highlights the WHOLE block (GitHub's multi-line review comment: start_line
# + line), so a finding about a multi-line span selects all of it instead of anchoring the top
# line and re-pasting the rest of the code into the comment body. A rejected range retries as a
# single-line anchor at the last line. On ANY failure we DO NOT silently drop the anchor — we
# surface the reason on stderr (with GitHub's actual error) and fall back to a normal PR comment
# that references PATH:LINE, so the content is never lost AND the caller is never told "posted
# inline" when it didn't anchor to the diff.
vcs_pr_comment() {
  local num="$1" path="$2" line="$3" body="$4" dry="${5:-0}"
  local full="$body"
  [[ -n "$path" ]] && full="${path}${line:+:$line} — ${body}"

  # LINE is "N" or an inclusive range "N-M" (normalized so start <= end).
  local sline="" eline=""
  if [[ -n "$line" ]]; then
    if [[ "$line" == *-* ]]; then sline="${line%%-*}"; eline="${line##*-}"; else sline="$line"; eline="$line"; fi
    if [[ "$sline" =~ ^[0-9]+$ && "$eline" =~ ^[0-9]+$ && "$sline" -gt "$eline" ]]; then
      local _t="$sline"; sline="$eline"; eline="$_t"
    fi
  fi

  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — comment on PR #%s: %s\n' "$num" "$full"; return 0
  fi
  if [[ -n "$path" && -n "$line" ]]; then
    local sha err
    sha="$(_gh_pr view "$num" --json headRefOid -q .headRefOid 2>/dev/null || true)"
    if [[ -z "$sha" ]]; then
      printf 'WARN: could not read head SHA for PR #%s — posting %s:%s as a NON-inline comment\n' "$num" "$path" "$line" >&2
    else
      # RIGHT side = the new version of the file (where review findings live).
      local -a args=( -f body="$body" -f commit_id="$sha" -f path="$path" -f side=RIGHT )
      if [[ "$sline" != "$eline" ]]; then args+=( -F start_line="$sline" -f start_side=RIGHT -F line="$eline" )
      else                                 args+=( -F line="$eline" ); fi
      if err="$(gh api "repos/$(_gh_nwo_once)/pulls/$num/comments" "${args[@]}" 2>&1)"; then
        if [[ "$sline" != "$eline" ]]; then printf 'Inline comment posted on PR #%s at %s:%s-%s (range)\n' "$num" "$path" "$sline" "$eline"
        else                                printf 'Inline comment posted on PR #%s at %s:%s\n' "$num" "$path" "$eline"; fi
        return 0
      elif [[ "$sline" != "$eline" ]]; then
        # Range rejected — retry a single-line anchor at the last line before giving up on inline.
        printf 'WARN: range anchor %s:%s-%s rejected on PR #%s — retrying single-line at %s.\n  GitHub said: %s\n' \
          "$path" "$sline" "$eline" "$num" "$eline" "$(printf '%s' "$err" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-300)" >&2
        if err="$(gh api "repos/$(_gh_nwo_once)/pulls/$num/comments" -f body="$body" -f commit_id="$sha" -f path="$path" -F line="$eline" -f side=RIGHT 2>&1)"; then
          printf 'Inline comment posted on PR #%s at %s:%s\n' "$num" "$path" "$eline"; return 0
        fi
        printf 'WARN: inline anchor failed for %s:%s on PR #%s — falling back to a NON-inline comment.\n  GitHub said: %s\n' \
          "$path" "$line" "$num" "$(printf '%s' "$err" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-300)" >&2
      else
        printf 'WARN: inline anchor failed for %s:%s on PR #%s — falling back to a NON-inline comment.\n  GitHub said: %s\n' \
          "$path" "$line" "$num" "$(printf '%s' "$err" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-300)" >&2
      fi
    fi
  fi
  _gh_pr comment "$num" --body "$full" >/dev/null || die "failed to post comment on PR #$num"
  if [[ -n "$path" && -n "$line" ]]; then
    printf 'Comment posted on PR #%s (NON-inline comment — see WARN above for why %s:%s did not anchor)\n' "$num" "$path" "$line"
  else
    printf 'Comment posted on PR #%s\n' "$num"
  fi
}

# vcs_pr_comments NUMBER -> prints the PR's comments/review notes as plain text.
vcs_pr_comments() {
  _gh_pr view "$1" --comments 2>/dev/null || die "could not read comments for PR #$1"
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

# vcs_pr_reply NUMBER THREAD_ID BODY [DRY]
# Post a threaded reply INSIDE an existing PR review thread (nested under the thread's first
# comment) — unlike vcs_pr_comment, which starts a NEW comment. THREAD_ID is the GraphQL
# review-thread node id printed by vcs_pr_threads (thread=<id>) — the same id resolveThread
# takes — so a reply anchors to the exact thread over GraphQL (the REST replies endpoint
# needs a numeric comment id vcs_pr_threads doesn't expose). NUMBER is only for the message.
vcs_pr_reply() {
  local num="$1" tid="$2" body="$3" dry="${4:-0}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — gh api graphql addPullRequestReviewThreadReply(threadId:%s)\n' "$tid"; return 0
  fi
  gh api graphql \
      -f query='mutation($id:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id,body:$b}){comment{id}}}' \
      -f id="$tid" -f b="$body" >/dev/null \
    || die "could not post reply to thread $tid on PR #$num"
  printf 'Reply posted to thread %s on PR #%s\n' "$tid" "$num"
}

# vcs_close_pr NUMBER [DRY] -> close the PR without merging (branch kept), then pr-view.
vcs_close_pr() {
  local num="$1" dry="${2:-0}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — gh pr close %s\n' "$num"; return 0
  fi
  _gh_pr close "$num"
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
# owner/repo for the API calls and for building a release-download URL.
#
# VCS_REMOTE FIRST. When the caller named a remote other than `origin`, that remote IS the
# target — the whole point of VCS_REMOTE is contributing to an UPSTREAM repo from a clone whose
# `origin` points somewhere else entirely (a different host, even a different provider). Asking
# `gh repo view` there answers from `origin`, so the PR would be aimed at the wrong repository
# while the branch was pushed to the right one. Resolve from the named remote's own URL instead.
# Otherwise: ask gh, falling back to parsing `origin` (so a --dry-run preview works offline,
# before auth or a real repo exists).
_gh_nwo() {
  local nwo url
  if [[ "${VCS_REMOTE:-origin}" != origin ]]; then
    url="$(git remote get-url "$VCS_REMOTE" 2>/dev/null || true)"; url="${url%.git}"
    case "$url" in
      *github.com[:/]*) printf '%s' "${url#*github.com[:\/]}"; return 0 ;;
      "") die "VCS_REMOTE=$VCS_REMOTE is not a remote of this repo (git remote get-url $VCS_REMOTE failed)" ;;
      *) die "VCS_REMOTE=$VCS_REMOTE points at '$url', which is not a github.com remote — set VCS_PROVIDER to match it" ;;
    esac
  fi
  nwo="$(vcs_repo_ref)"
  [[ -n "$nwo" ]] || nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [[ -n "$nwo" ]] && { printf '%s' "$nwo"; return 0; }
  url="$(git remote get-url origin 2>/dev/null || true)"; url="${url%.git}"
  case "$url" in *github.com[:/]*) printf '%s' "${url#*github.com[:\/]}" ;; *) printf '%s' "$url" ;; esac
}

# _gh_nwo can shell out to `gh repo view` (a network call) on its last resort, and one adapter
# process asks for the same answer several times. Resolve once per process.
_GH_NWO=''
_gh_nwo_once() { [[ -n "$_GH_NWO" ]] || _GH_NWO="$(_gh_nwo)"; printf '%s' "$_GH_NWO"; }

# Every `gh pr <verb>` goes through here. gh resolves the repository from the CURRENT WORKING
# DIRECTORY's git remote unless told otherwise, so in a multi-repo run — where the cwd is the
# workspace root, not the target repo — every untargeted call acted on the wrong repository or
# failed outright. `vcs_open_pr` was the only function that passed `--repo`; the rest inherited
# the cwd. One wrapper names the repo for all of them; the resolved target itself is announced
# once by lib.sh, deliberately outside any stderr a call site captures and then pattern-matches.
_gh_pr() {
  local verb="$1"; shift
  local nwo; nwo="$(_gh_nwo_once)"
  # Mutations only, and on fd 9 (see lib.sh): the reads are called from places that parse their
  # output, and a mutation is the call whose silent misfire cost a real run three rounds.
  case "$verb" in create|edit|comment|review|close|merge)
    printf 'vcs[github] pr %s → %s\n' "$verb" "${nwo:-<cwd git remote>}" >&9 ;;
  esac
  if [[ -n "$nwo" ]]; then gh pr "$verb" --repo "$nwo" "$@"; else gh pr "$verb" "$@"; fi
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
  # Merge stays FAIL-CLOSED — never report a merge that did not happen. Branch protection is the
  # usual refusal here, and it has a real alternative, so the adapter names it rather than
  # letting the caller guess. (--admin can be added above if a self-merge must be forced.)
  local err
  if ! err=$(_gh_pr merge "$num" --squash --subject "$subject" 2>&1); then
    printf '%s\n' "$err" >&2
    case "$err" in
      *"protected"*|*"Protected"*|*"not authorized"*|*"required status"*|*"review is required"*)
        die "PR #$num: branch protection refuses this merge. The PR is still OPEN and unmerged. Satisfy the protection rule (reviews / checks) or merge from the web UI — do NOT report it as merged." ;;
      *)
        die "PR #$num: merge failed — see the error above. The PR is still OPEN and unmerged." ;;
    esac
  fi
  printf '%s\n' "$err"
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
  # IDEMPOTENT. A review gate that already passed is frozen, and a later invocation must be able
  # to call this without consequence: the APPROVE review is harmless to repeat but its body is
  # not — it would stack a second identical verdict on the PR every run. An UNKNOWN answer is
  # not a yes: when GitHub won't say, approve again rather than skip, because a missing approval
  # is the failure mode that actually costs something.
  if [[ "$(vcs_pr_approved "$num")" == "yes" ]]; then
    printf 'PR #%s is already approved — nothing to do (no second verdict posted)\n' "$num"
    return 0
  fi
  if [[ -n "$body" && "$body" != "$VCS_APPROVAL_MARKER"* ]]; then body="$VCS_APPROVAL_MARKER — $body"; fi
  # Approvals can be refused by the repo's own rules (and GitHub always refuses a self-approval).
  # That is a capability of this repo, not a failed review: degrade to a comment carrying the
  # same verdict rather than exiting 1 and leaving the gate recorded as broken.
  local err
  if err=$(_gh_pr review "$num" --approve ${body:+--body "$body"} 2>&1); then
    printf 'Approved PR #%s\n' "$num"
    return 0
  fi
  printf 'WARN: host-level approval unavailable on PR #%s — %s\n' "$num" "${err##*$'\n'}" >&2
  _gh_pr comment "$num" --body "${body:-$VCS_APPROVAL_MARKER} (host-level approval is unavailable on this repository; recording the verdict as a comment.)" >/dev/null \
    || die "PR #$num: approval was refused AND the fallback verdict comment failed — nothing records this review"
  printf 'Approved PR #%s (verdict recorded as a COMMENT — host-level approval unavailable on this repository)\n' "$num"
}
