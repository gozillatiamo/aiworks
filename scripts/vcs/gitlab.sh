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

# The GitLab project every `projects/<…>/merge_requests…` call below acts on. `:fullpath` is
# glab's own placeholder — it resolves from the CURRENT WORKING DIRECTORY's git remote, which is
# exactly the assumption VCS_REPO exists to override. Falls back to `:fullpath` byte-for-byte
# when VCS_REPO is unset, so every existing caller is unaffected.
_gl_project() {
  local r; r="$(vcs_repo_ref)"
  if [[ -n "$r" ]]; then vcs_urlencode_path "$r"; else printf ':fullpath'; fi
}

# Every NATIVE `glab mr <verb>` goes through here. `glab api projects/<id>/…` is scoped by
# _gl_project() above; `glab mr create|note|view|close|merge|approve` are NOT — they resolve the
# project from the CURRENT WORKING DIRECTORY's git remote, which in a multi-repo run is the
# workspace root and not the target repo. Those calls then acted on the wrong project or 404'd,
# and under `set -e` the failing assignment killed the caller before the function reached its own
# `die` — the caller saw a bare exit 1 with no output. One wrapper fixes the targeting in one
# place; the resolved target itself is announced once by lib.sh, deliberately outside any stderr a
# call site captures and then pattern-matches.
_gl_mr() {
  local verb="$1"; shift
  local r; r="$(vcs_repo_ref)"
  # Mutations only, and on fd 9 (see lib.sh): the reads are called from places that parse their
  # output, and a mutation is the call whose silent misfire cost a real run three rounds.
  case "$verb" in create|note|close|merge|approve)
    printf 'vcs[gitlab] mr %s → %s\n' "$verb" "${r:-<cwd git remote>}" >&9 ;;
  esac
  if [[ -n "$r" ]]; then glab mr "$verb" -R "$r" "$@"; else glab mr "$verb" "$@"; fi
}

# vcs_open_pr BASE HEAD TITLE BODY [DRY] -> prints "<url>" then "number=<iid>".
# Every MR is opened with "Squash commits when merge request is accepted" CHECKED
# (--squash-before-merge=true). This guarantees a squash even when a human merges the
# open MR from the web UI (the path taken when vcs.auto_merge is off) — mirroring the
# server-side --squash in vcs_merge_pr below, so the parent branch always gets one commit.

# The OPEN MR for a source branch, or empty. Asked TWICE, deliberately: once before creating one
# (so a re-run reuses instead of duplicating), and again after a `glab mr create` that reported
# failure — because "the CLI exited non-zero" and "the server created nothing" are different
# facts, and only the forge knows the second one. A webhook that errors the response, a body glab
# cannot parse, a connection dropped after the POST: the MR exists and the caller was told it does
# not. Never a mutation, so asking twice costs one read.
_gl_open_mr_url() {
  glab api "projects/$(_gl_project)/merge_requests?source_branch=$1&state=opened" 2>/dev/null \
    | jq -r '.[0].web_url // empty' 2>/dev/null || true
}

vcs_open_pr() {
  local base="$1" head="$2" title="$3" body="$4" dry="${5:-0}"
  # Reuse an open MR for this source branch (avoid duplicates).
  local existing url iid
  existing="$(_gl_open_mr_url "$head")"
  if [[ -n "$existing" ]]; then
    iid="${existing##*/}"
    printf '%s\nnumber=%s\n' "$existing" "$iid"
    return 0
  fi
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — git push -u %s %q && glab mr create -s %q -b %q -t %q -d <…> --squash-before-merge=true -y\n' "$VCS_REMOTE" "$head" "$head" "$base" "$title"
    return 0
  fi
  git push -u "$VCS_REMOTE" "$head" >/dev/null 2>&1 || true
  local out rc=0
  # `|| rc=$?` is the other half of the fix in _gl_mr: without it a failing `glab mr create` makes
  # this assignment non-zero, `set -e` kills the function HERE, and the caller sees exit 1 with no
  # output at all — the silent failure that took a source read to diagnose. Keeping the STATUS as
  # well as the output is what lets the diagnostic below name glab's own exit code, which is the
  # single most useful fact about a create that failed and the one thing `|| true` threw away.
  out="$(_gl_mr create --source-branch "$head" --target-branch "$base" --title "$title" --description "$body" --squash-before-merge=true --yes 2>&1)" || rc=$?
  # `|| true` HERE, and it is not decoration — it is the bug this line used to BE. `grep` exits 1
  # when it matches nothing, `set -o pipefail` promotes that to the pipeline's status, and an
  # assignment from a failing command substitution is a failing simple command, so `set -e` killed
  # the function ON THIS LINE. The diagnostic on the next line — the whole reason the output was
  # captured — never ran. What the caller saw was exit 1 and ZERO bytes, for every failing create:
  # not a glab that printed nothing (it had printed its error into `out`), but an adapter that
  # exited before it could pass it on. Nine reproductions across two runs were read as a broken
  # `glab`; the missing two words were here. github.sh:40 has carried them since it was written.
  url="$(printf '%s' "$out" | grep -oE 'https?://[^ ]+/merge_requests/[0-9]+' | head -n1)" || true
  # A create that REPORTED failure may still have landed the MR (see _gl_open_mr_url). Ask the
  # forge before telling the caller nothing exists: the run that follows this call is deciding
  # whether to open one, and a false "nothing was created" is what makes it try forever.
  if [[ -z "$url" ]]; then
    url="$(_gl_open_mr_url "$head")"
    [[ -z "$url" ]] || printf 'vcs[gitlab] mr create exited %s, but %s already has an open MR on the forge — reusing %s\n' "$rc" "$head" "$url" >&9
  fi
  [[ -n "$url" ]] || { printf '%s\n' "$out" >&2; die "glab mr create exited $rc and printed no MR URL — the MR was NOT created (project ${VCS_REPO:-<cwd git remote>}, $head -> $base). glab's own output is on the line above; an EMPTY line above means glab itself printed nothing."; }
  iid="${url##*/}"
  printf '%s\nnumber=%s\n' "$url" "$iid"
}

# vcs_find_prs KEY -> print the web_url (one per line) of every OPEN MR whose TITLE or
# source BRANCH contains KEY (case-insensitive). Read-only — never creates anything.
# Relies on the team convention that a ticket's MR carries the ticket key in its
# Conventional-Commit title (e.g. feat(FM-12): …) and/or branch (feature/FM-12).
vcs_find_prs() {
  local key="$1"
  glab api "projects/$(_gl_project)/merge_requests?state=opened&per_page=100" 2>/dev/null \
    | jq -r --arg k "$key" '
        ($k | ascii_downcase) as $kk
        | .[]
        | select(((.title // "")         | ascii_downcase | contains($kk))
              or  ((.source_branch // "") | ascii_downcase | contains($kk)))
        | .web_url' 2>/dev/null || true
}

# vcs_list_prs -> one TSV line per OPEN MR in the repo of the current directory:
#   iid <TAB> draft(yes|no) <TAB> author <TAB> updated(YYYY-MM-DD) <TAB> target <TAB> title <TAB> url
# Read-only. The key-filtered vcs_find_prs answers "where is ticket X?"; this answers "what is
# waiting?", which needs the whole open set and the fields a reviewer triages on.
vcs_list_prs() {
  glab api "projects/$(_gl_project)/merge_requests?state=opened&per_page=100&order_by=updated_at" 2>/dev/null \
    | jq -r '.[] | [ (.iid|tostring),
                     (if .draft then "yes" else "no" end),
                     (.author.username // "-"),
                     ((.updated_at // "")[0:10]),
                     (.target_branch // "-"),
                     (.title // ""),
                     (.web_url // "") ] | @tsv' 2>/dev/null || true
}

# vcs_pr_view NUMBER -> "state=", "merge_sha=", "approved=", "target_branch=", "source_branch=".
#
# target_branch/source_branch are printed because a gate cannot assert what the sanctioned tool
# refuses to show. This function always fetched the whole MR object — target_branch included — and
# threw the field away, so "does this MR target the branch the run said?" had no answer through the
# adapter, and one measured run reported its clean terminal state with every MR pointed at a branch
# nobody had asked for. The data was already on the wire.
vcs_pr_view() {
  local num="$1" json state sha up tgt src
  if ! json="$(glab api "projects/$(_gl_project)/merge_requests/$num" 2>/dev/null)"; then
    printf 'state=UNKNOWN\nmerge_sha=\napproved=unknown\ntarget_branch=\nsource_branch=\n'; return 0
  fi
  state="$(printf '%s' "$json" | jq -r '.state // "unknown"')"
  sha="$(printf '%s' "$json" | jq -r '.merge_commit_sha // .squash_commit_sha // ""')"
  tgt="$(printf '%s' "$json" | jq -r '.target_branch // ""')"
  src="$(printf '%s' "$json" | jq -r '.source_branch // ""')"
  # Normalize GitLab states to the interface's vocabulary.
  case "$state" in
    merged)        up=MERGED ;;
    opened)        up=OPEN ;;
    closed|locked) up=CLOSED ;;
    *)             up="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')" ;;
  esac
  printf 'state=%s\nmerge_sha=%s\napproved=%s\ntarget_branch=%s\nsource_branch=%s\n' \
    "$up" "$sha" "$(vcs_pr_approved "$num")" "$tgt" "$src"
}

# vcs_pr_retarget NUMBER BASE -> repoint an OPEN MR at a different target branch.
# GitLab keeps existing approvals across a retarget, which is why this exists at all: the only
# route before was close + reopen against the right base, and GitLab does NOT carry approvals
# across that — so repairing four mis-targeted MRs also destroyed four approvals that then had to
# be rebuilt by hand. One PUT does it, and the field was supported all along.
vcs_pr_retarget() {
  local num="$1" base="$2" dry="${3:-0}" out
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — PUT merge_requests/%s target_branch=%s\n' "$num" "$base"; return 0
  fi
  out="$(glab api --method PUT "projects/$(_gl_project)/merge_requests/$num" \
          -f "target_branch=$base" 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }
  printf 'target_branch=%s\n' "$(printf '%s' "$out" | jq -r '.target_branch // ""')"
}

# vcs_pr_approved NUMBER -> prints yes | no | unknown, the forge's own record of whether this
# MR already carries a review approval. "unknown" is NOT "no": it means this instance would not
# answer, and a caller must never skip a review gate on an unanswered question — treat unknown
# as unapproved and review.
#
# Two tiers, because GitLab MR approvals are an instance/edition capability the API can refuse
# outright (401/403 — the same refusal vcs_approve_pr already degrades around). When the
# approvals endpoint is unavailable, vcs_approve_pr's fallback leaves the verdict as a NOTE
# starting with the approval marker, so that note is the second-tier record of the same fact.
vcs_pr_approved() {
  local num="$1" json n
  if json="$(glab api "projects/$(_gl_project)/merge_requests/$num/approvals" 2>/dev/null)"; then
    # COUNT approved_by; do NOT read `.approved`. GitLab reports `"approved": true` whenever the
    # MR SATISFIES its approval rules — and a project with zero required approvals satisfies them
    # with nobody having approved anything. Measured against a live instance: an untouched MR
    # answered `{"approved":true,"approved_by":[]}`, next to a genuinely approved one's
    # `{"approved":true,"approvals_required":1,"approved_by":["<a reviewer>"]}`. Trusting `.approved`
    # would answer "yes" for every MR in this workspace and freeze every review gate that exists.
    n="$(printf '%s' "$json" | jq -r '(.approved_by // []) | length' 2>/dev/null || printf '0')"
    if [[ "${n:-0}" -gt 0 ]]; then printf 'yes\n'; return 0; fi
    if _gl_has_approval_note "$num"; then printf 'yes\n'; return 0; fi
    printf 'no\n'; return 0
  fi
  if _gl_has_approval_note "$num"; then printf 'yes\n'; return 0; fi
  printf 'unknown\n'
}

# _gl_has_approval_note NUMBER -> 0 when an MR note starts with the approval marker that
# vcs_approve_pr posts. This is what makes the approval readable on an instance whose
# approvals API is disabled, and what keeps a re-run from stacking a second verdict note.
_gl_has_approval_note() {
  glab api "projects/$(_gl_project)/merge_requests/$1/notes?per_page=100" 2>/dev/null \
    | jq -e --arg m "$VCS_APPROVAL_MARKER" 'any(.[]; (.body // "") | startswith($m))' >/dev/null 2>&1
}

# SHA-1 of a string — portable across GNU coreutils (sha1sum) and macOS (shasum).
_gl_sha1() {
  if command -v sha1sum >/dev/null 2>&1; then printf '%s' "$1" | sha1sum | awk '{print $1}'
  else printf '%s' "$1" | shasum -a 1 | awk '{print $1}'; fi
}

# _gl_line_code PATH OLD NEW -> GitLab's line_code for a diff line: SHA-1(path)_old_new.
# Required for EACH endpoint of a multi-line comment's position[line_range] (a single-line
# comment needs no line_code). For an added line OLD is the running old-side counter, which
# is exactly what GitLab stores in an added line's own line_code.
_gl_line_code() { printf '%s_%s_%s' "$(_gl_sha1 "$1")" "$2" "$3"; }

# _gl_diff_line_at NUMBER PATH NEW_LINE -> classify a NEW-side line against the MR diff and
# print "<kind>\t<old_pos>\t<new_pos>" (empty when the line isn't in the diff at all):
#   kind "added"     the line was ADDED (+)  — anchor with position[new_line] only
#   kind "context"   the line is UNCHANGED   — GitLab needs BOTH new_line AND old_line to
#                    anchor it (the #1 reason review comments fell to the overview: most
#                    findings sit on context lines, and new_line-alone is rejected)
# old_pos/new_pos feed both the top-level anchor and the line_range line codes (_gl_line_code).
# Reads GitLab's OWN diff (the /diffs endpoint) so the computed position matches exactly what
# the server will accept. Walks the unified hunks tracking old/new line counters.
_gl_diff_line_at() {
  local num="$1" path="$2" target="$3" diff
  diff="$(glab api "projects/$(_gl_project)/merge_requests/$num/diffs?per_page=100" 2>/dev/null \
          | jq -r --arg p "$path" '.[] | select(.new_path==$p) | .diff' 2>/dev/null || true)"
  [[ -n "$diff" ]] || return 0
  printf '%s' "$diff" | awk -v target="$target" '
    /^@@/ {
      h=$0; sub(/^@@ -/,"",h); split(h, a, " ")
      split(a[1], o, ","); oln=o[1]+0
      nb=a[2]; sub(/^\+/,"",nb); split(nb, n, ","); nln=n[1]+0
      inhunk=1; next
    }
    !inhunk { next }
    {
      c=substr($0,1,1)
      if (c=="+")      { if (nln==target){print "added\t" oln "\t" nln; exit} nln++ }
      else if (c=="-") { oln++ }
      else if (c=="\\"){ }                                  # "\ No newline at end of file"
      else             { if (nln==target){print "context\t" oln "\t" nln; exit} oln++; nln++ }
    }
  '
}

# vcs_pr_comment NUMBER PATH LINE BODY [DRY]
# Posts a positioned (inline) MR discussion at PATH:LINE on the new side of the diff. LINE is
# either a single line "N" or an INCLUSIVE RANGE "N-M" — a range highlights the WHOLE block on
# the MR (every line it spans), so a finding about a multi-line span selects all of it instead
# of anchoring the top line and re-pasting the rest of the code into the comment body.
#
# Each targeted line is classified against the MR's own diff (_gl_diff_line_at): an added line
# anchors with new_line; an UNCHANGED/context line anchors with BOTH new_line and old_line
# (GitLab rejects new_line-alone for those — the main reason comments used to fall to the
# overview). A range additionally sends position[line_range] with a GitLab line_code
# (_gl_line_code) for each endpoint. If the range is rejected we retry as a single-line anchor
# at the range's last line; if THAT can't anchor either (line not in the diff at all) we fall
# back to a plain MR note referencing PATH:LINE — the reviewer's content is never lost. On any
# fallback we WARN to stderr with GitLab's actual error AND mark the stdout line NON-inline, so
# a caller is NEVER told "posted inline" when the comment didn't anchor.
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
    if [[ -n "$path" && -n "$line" ]]; then
      if [[ "$sline" != "$eline" ]]; then
        printf 'DRY RUN — glab api …/merge_requests/%s/discussions (inline range %s:%s-%s; falls back to single-line then a note)\n' "$num" "$path" "$sline" "$eline"
      else
        printf 'DRY RUN — glab api …/merge_requests/%s/discussions (inline %s:%s; falls back to a note)\n' "$num" "$path" "$line"
      fi
    else
      printf 'DRY RUN — glab mr note %s --message %q\n' "$num" "$full"
    fi
    return 0
  fi
  # Try a positioned discussion first. GitLab's text-diff position needs the MR's three
  # diff refs (base/head/start SHAs) plus old_path+new_path, and the RIGHT line key:
  # new_line for an added line, BOTH new_line+old_line for an unchanged/context line.
  # On ANY failure we DO NOT silently drop the anchor — we surface the reason on stderr and
  # fall back to a plain note so the content is never lost AND the caller knows it isn't inline.
  if [[ -n "$path" && -n "$line" ]]; then
    local refs base head start err
    refs="$(glab api "projects/$(_gl_project)/merge_requests/$num" 2>/dev/null \
            | jq -r '[.diff_refs.base_sha, .diff_refs.head_sha, .diff_refs.start_sha] | @tsv' 2>/dev/null || true)"
    IFS=$'\t' read -r base head start <<<"$refs"
    if [[ -z "$base" || -z "$head" || -z "$start" ]]; then
      printf 'WARN: could not read diff refs for MR !%s — posting %s:%s as a NON-inline note\n' "$num" "$path" "$line" >&2
    else
      # Classify the anchor (last) line and build the single-line position array.
      # CRITICAL: the position MUST go as multipart form (--form), NOT --field/--raw-field.
      # glab's -f/-F encode params into a JSON body, where "position[new_line]" becomes a
      # FLAT key GitLab doesn't understand — so GitLab accepts the note but SILENTLY DROPS
      # the position, landing every comment on the overview. --form sends Rails-style
      # bracketed fields that parse into the nested `position` object the API expects.
      local kind_e old_e new_e
      IFS=$'\t' read -r kind_e old_e new_e <<<"$(_gl_diff_line_at "$num" "$path" "$eline")"
      local -a pos=(
        --form "body=$body"
        --form "position[position_type]=text"
        --form "position[base_sha]=$base"
        --form "position[head_sha]=$head"
        --form "position[start_sha]=$start"
        --form "position[old_path]=$path"
        --form "position[new_path]=$path"
      )
      case "$kind_e" in
        # Unchanged/context line: GitLab needs BOTH new_line and old_line to anchor it.
        context) pos+=( --form "position[new_line]=$eline" --form "position[old_line]=$old_e" ) ;;
        # Added line (or a line we couldn't classify): new_line alone.
        added|*) pos+=( --form "position[new_line]=$eline" ) ;;
      esac

      # For a range, build a second array that ALSO carries position[line_range] (a line_code
      # per endpoint). Kept separate from `pos` so a rejected range can retry single-line.
      local -a posr=(); local ranged=0
      if [[ "$sline" != "$eline" ]]; then
        local kind_s old_s new_s
        IFS=$'\t' read -r kind_s old_s new_s <<<"$(_gl_diff_line_at "$num" "$path" "$sline")"
        if [[ -n "$kind_s" && -n "$kind_e" ]]; then
          ranged=1
          posr=( "${pos[@]}"
            --form "position[line_range][start][line_code]=$(_gl_line_code "$path" "$old_s" "$new_s")"
            --form "position[line_range][end][line_code]=$(_gl_line_code "$path" "$old_e" "$new_e")" )
          # type is "new" for an added endpoint; omitted for a context line (both sides exist).
          [[ "$kind_s" == added ]] && posr+=( --form "position[line_range][start][type]=new" )
          [[ "$kind_e" == added ]] && posr+=( --form "position[line_range][end][type]=new" )
        else
          printf 'WARN: MR !%s could not classify range %s:%s-%s against the diff — anchoring single-line at %s\n' "$num" "$path" "$sline" "$eline" "$eline" >&2
        fi
      fi

      # Attempt the range first (when built); a hard rejection retries single-line below.
      if [[ "$ranged" -eq 1 ]]; then
        if err="$(glab api --method POST "projects/$(_gl_project)/merge_requests/$num/discussions" "${posr[@]}" 2>&1)"; then
          if [[ -n "$(printf '%s' "$err" | jq -r '.notes[0].position // empty' 2>/dev/null)" ]]; then
            printf 'Inline comment posted on MR !%s at %s:%s-%s (range)\n' "$num" "$path" "$sline" "$eline"; return 0
          fi
          # Accepted but un-anchored: a note already exists on the overview — don't double-post.
          printf 'WARN: MR !%s accepted %s:%s-%s but DROPPED the position — it landed on the overview, not inline.\n' "$num" "$path" "$sline" "$eline" >&2
          printf 'Comment posted on MR !%s (NON-inline — position dropped for %s:%s-%s)\n' "$num" "$path" "$sline" "$eline"; return 0
        fi
        printf 'WARN: range anchor %s:%s-%s rejected on MR !%s — retrying single-line at %s.\n  GitLab said: %s\n' \
          "$path" "$sline" "$eline" "$num" "$eline" "$(printf '%s' "$err" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-300)" >&2
      fi

      # Single-line anchor (no range requested, or the range was rejected above).
      if err="$(glab api --method POST "projects/$(_gl_project)/merge_requests/$num/discussions" "${pos[@]}" 2>&1)"; then
        if [[ -n "$(printf '%s' "$err" | jq -r '.notes[0].position // empty' 2>/dev/null)" ]]; then
          printf 'Inline comment posted on MR !%s at %s:%s (%s)\n' "$num" "$path" "$eline" "${kind_e:-added}"; return 0
        fi
        printf 'WARN: MR !%s accepted %s:%s but DROPPED the diff position — it landed on the overview, not inline (diff-kind=%s).\n' \
          "$num" "$path" "$eline" "${kind_e:-not-in-diff}" >&2
        printf 'Comment posted on MR !%s (NON-inline — position dropped for %s:%s)\n' "$num" "$path" "$line"; return 0
      else
        printf 'WARN: inline anchor failed for %s:%s on MR !%s (diff-kind=%s) — falling back to a NON-inline note.\n  GitLab said: %s\n' \
          "$path" "$line" "$num" "${kind_e:-not-in-diff}" "$(printf '%s' "$err" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-300)" >&2
      fi
    fi
  fi
  _gl_mr note "$num" --message "$full" >/dev/null || die "failed to post note on MR !$num"
  if [[ -n "$path" && -n "$line" ]]; then
    printf 'Comment posted on MR !%s (NON-inline note — see WARN above for why %s:%s did not anchor)\n' "$num" "$path" "$line"
  else
    printf 'Comment posted on MR !%s\n' "$num"
  fi
}

# vcs_pr_comments NUMBER -> prints the MR's notes as plain text.
vcs_pr_comments() {
  local num="$1"
  _gl_mr view "$num" --comments 2>/dev/null && return 0
  # Fallback: render notes via the API.
  glab api "projects/$(_gl_project)/merge_requests/$num/notes" 2>/dev/null \
    | jq -r '.[] | select(.system==false) | "\(.author.name)  \(.created_at)\n  \(.body)\n"' 2>/dev/null \
    || die "could not read notes for MR !$num"
}

# vcs_pr_threads NUMBER -> list the MR's RESOLVABLE discussion threads, one block each:
#   ● thread=<discussion_id>  [unresolved|resolved]  <path>:<line>  (<author>)
#     <author>: <note body…>
# The `thread=<id>` is what vcs_pr_resolve_thread needs — plain `vcs_pr_comments` prints
# the same notes but WITHOUT the discussion id, so a fix can't be tied back to its thread.
# Only resolvable threads (review discussions) are listed; plain notes have no checkbox.
vcs_pr_threads() {
  local num="$1" out
  out="$(glab api "projects/$(_gl_project)/merge_requests/$num/discussions?per_page=100" 2>/dev/null \
    | jq -r '
        .[]
        | select(any(.notes[]; .resolvable == true))
        | . as $d
        | ($d.notes | map(select(.resolvable))) as $rn
        | $rn[0] as $first
        | ($first.position // {}) as $pos
        | ($pos.new_path // $pos.old_path // "") as $path
        | ($pos.new_line // $pos.old_line // "") as $line
        | (if ($rn | all(.resolved)) then "resolved" else "unresolved" end) as $state
        | "● thread=\($d.id)  [\($state)]  "
          + (if $path != "" then $path + (if ($line|tostring) != "" then ":" + ($line|tostring) else "" end) else "(general)" end)
          + "  (\($first.author.name))\n"
          + ($d.notes | map("  " + .author.name + ": " + (.body | gsub("\n"; "\n  "))) | join("\n"))
          + "\n"
      ' 2>/dev/null)" || die "could not read threads for MR !$num"
  if [[ -z "${out//[$'\n\t ']/}" ]]; then
    printf 'No resolvable threads on MR !%s\n' "$num"
  else
    printf '%s\n' "$out"
  fi
}

# vcs_pr_resolve_thread NUMBER THREAD_ID [RESOLVED=true] [DRY]
# Checks "Resolve thread" on a MR discussion once the developer has addressed it (PUT
# resolved=true on the whole discussion). RESOLVED=false reopens it. THREAD_ID is the
# discussion id printed by vcs_pr_threads.
vcs_pr_resolve_thread() {
  local num="$1" tid="$2" resolved="${3:-true}" dry="${4:-0}"
  local word; word="$([[ "$resolved" == false ]] && echo unresolved || echo resolved)"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — glab api --method PUT …/merge_requests/%s/discussions/%s?resolved=%s\n' "$num" "$tid" "$resolved"
    return 0
  fi
  glab api --method PUT "projects/$(_gl_project)/merge_requests/$num/discussions/$tid?resolved=$resolved" >/dev/null \
    || die "could not mark thread $tid on MR !$num $word"
  printf 'Thread %s on MR !%s marked %s\n' "$tid" "$num" "$word"
}

# vcs_pr_reply NUMBER THREAD_ID BODY [DRY]
# Post a threaded reply INSIDE an existing MR discussion (nested under the thread's first
# note) — unlike vcs_pr_comment, which starts a NEW note/thread. THREAD_ID is the
# discussion id printed by vcs_pr_threads (thread=<id>). POSTs a note to that discussion.
# --form is used (not -f/-F) so a multiline body with special chars is sent as a real
# form field, matching the positioned-comment path above.
vcs_pr_reply() {
  local num="$1" tid="$2" body="$3" dry="${4:-0}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — glab api POST …/merge_requests/%s/discussions/%s/notes\n' "$num" "$tid"; return 0
  fi
  glab api --method POST "projects/$(_gl_project)/merge_requests/$num/discussions/$tid/notes" \
      --form "body=$body" >/dev/null \
    || die "could not post reply to thread $tid on MR !$num"
  printf 'Reply posted to thread %s on MR !%s\n' "$tid" "$num"
}

# vcs_close_pr NUMBER [DRY] -> close the MR without merging (branch kept), then pr-view.
vcs_close_pr() {
  local num="$1" dry="${2:-0}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — glab mr close %s\n' "$num"; return 0
  fi
  _gl_mr close "$num"
  vcs_pr_view "$num"
}

# vcs_upload_media KEY FILE [DRY] -> upload one file to the project, print its embeddable
# markdown line for the MR description. GitLab has a first-class uploads API: a POST returns
# a relative /uploads/<hash>/<file> URL that renders inline in any description/note in the
# project (images inline, video as a player). We rewrite the alt text to "<KEY> <file>" so
# the reviewer sees which ticket/screen each shot belongs to.
vcs_upload_media() {
  local key="$1" file="$2" dry="${3:-0}"
  local base; base="$(basename "$file")"
  local label; label="$(printf '%s%s' "${key:+$key }" "$base")"
  if [[ "$dry" -eq 1 ]]; then
    # The /uploads/<hash> path isn't known until the file is actually uploaded — show the shape.
    vcs_media_md "$label" "/uploads/<sha>/$base" "$base"; return 0
  fi
  [[ -f "$file" ]] || { echo "warn: media file not found: $file" >&2; return 1; }
  local json url
  json="$(glab api --method POST "projects/$(_gl_project)/uploads" -F "file=@${file}" 2>/dev/null)" \
    || { echo "warn: gitlab upload failed for $file" >&2; return 1; }
  url="$(printf '%s' "$json" | jq -r '.url // empty' 2>/dev/null)"
  [[ -n "$url" ]] || { echo "warn: no upload url in gitlab response for $file" >&2; return 1; }
  vcs_media_md "$label" "$url" "$base"
}

# vcs_merge_pr NUMBER SUBJECT [DRY] -> squash-merge server-side (MR shows Merged), then pr-view.
# The squash commit message defaults to the MR title (== SUBJECT, since we open the MR with it).
vcs_merge_pr() {
  local num="$1" subject="$2" dry="${3:-0}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — glab mr merge %s --squash --remove-source-branch --yes\n' "$num"; return 0
  fi
  # Merge stays FAIL-CLOSED — never report a merge that did not happen. But the caller needs to
  # know WHICH kind of no: an instance that refuses API merges (405 / "not allowed") has a real
  # alternative, a network error does not. Naming it here keeps the knowledge in the adapter,
  # where the provider's quirks belong, instead of leaking into the workflow or the config.
  local err
  if ! err=$(_gl_mr merge "$num" --squash --remove-source-branch --yes 2>&1); then
    printf '%s\n' "$err" >&2
    case "$err" in
      *405*|*"Method Not Allowed"*|*"not allowed"*|*"Not allowed"*)
        die "MR !$num: this GitLab project refuses API merges (405). The MR is still OPEN and unmerged. Merge it from the web UI, or land the branch directly (git push origin <base>) and close the MR — do NOT report it as merged." ;;
      *)
        die "MR !$num: merge failed — see the error above. The MR is still OPEN and unmerged." ;;
    esac
  fi
  printf '%s\n' "$err"
  vcs_pr_view "$num"
}

# vcs_approve_pr NUMBER BODY [DRY] -> the reviewer's PASS signal. Posts BODY as a one-line
# verdict note (loud + visible on the MR) and registers a host-level MR approval. BODY is
# optional; empty -> approval only. Approve is DECOUPLED from merge: it says "cleared the
# bar" without merging — the merge stays gated on vcs.auto_merge (vcs_merge_pr).
# Approving your own MR may be blocked by the project's approval rules — fine here, the
# reviewer is not the MR author.
vcs_approve_pr() {
  local num="$1" body="${2:-}" dry="${3:-0}"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — %sglab mr approve %s\n' "${body:+glab mr note $num --message <verdict> && }" "$num"
    return 0
  fi
  # IDEMPOTENT. A review gate that already passed is frozen, and a later invocation must be
  # able to call this without consequence: re-approving is harmless to the forge but the
  # verdict note is not — it would stack a second identical "APPROVED" on the MR every run.
  # An UNKNOWN answer is not a yes: when the instance won't say, approve again rather than
  # skip, because a missing approval is the failure mode that actually costs something.
  if [[ "$(vcs_pr_approved "$num")" == "yes" ]]; then
    printf 'MR !%s is already approved — nothing to do (no second verdict note posted)\n' "$num"
    return 0
  fi
  if [[ -n "$body" && "$body" != "$VCS_APPROVAL_MARKER"* ]]; then body="$VCS_APPROVAL_MARKER — $body"; fi
  local noted=0 err
  # `[[ … ]] && { … }` was wrong here: with an EMPTY body the test fails, the statement exits 1,
  # and `set -e` killed the whole approval before `glab mr approve` ever ran — which is exactly
  # the documented "approval only, no verdict note" call. An if/fi has no exit status to leak.
  if [[ -n "$body" ]]; then
    _gl_mr note "$num" --message "$body" >/dev/null || die "failed to post verdict note on MR !$num"
    noted=1
  fi
  # A project can disable MR approvals outright (the API then answers 401/403). That is a
  # capability of this instance, not a failure of the review — and dying here used to leave a
  # half state: the verdict note was already posted, yet the script exited 1 and the caller
  # recorded the whole gate as broken. Degrade the way vcs_pr_comment does: fall to the tier
  # that DOES work (the note is the durable record), say so on stdout, and let the run continue.
  if err=$(_gl_mr approve "$num" 2>&1); then
    printf 'Approved MR !%s%s\n' "$num" "${body:+ (verdict note posted)}"
    return 0
  fi
  printf 'WARN: host-level approval unavailable on MR !%s — %s\n' "$num" "${err##*$'\n'}" >&2
  if [[ "$noted" -eq 0 ]]; then
    _gl_mr note "$num" --message "$VCS_APPROVAL_MARKER (host-level approval is unavailable on this project; recording the verdict as a note)." >/dev/null \
      || die "MR !$num: approval was refused AND the fallback verdict note failed — nothing records this review"
  fi
  printf 'Approved MR !%s (verdict recorded as a NOTE — host-level approval unavailable on this project)\n' "$num"
}
