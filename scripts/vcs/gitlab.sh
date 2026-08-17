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

# vcs_open_pr BASE HEAD TITLE BODY [DRY] -> prints "<url>" then "number=<iid>".
# Every MR is opened with "Squash commits when merge request is accepted" CHECKED
# (--squash-before-merge=true). This guarantees a squash even when a human merges the
# open MR from the web UI (the path taken when vcs.auto_merge is off) — mirroring the
# server-side --squash in vcs_merge_pr below, so the parent branch always gets one commit.
vcs_open_pr() {
  local base="$1" head="$2" title="$3" body="$4" dry="${5:-0}"
  # Reuse an open MR for this source branch (avoid duplicates).
  local existing url iid
  existing="$(glab api "projects/$(_gl_project)/merge_requests?source_branch=$head&state=opened" 2>/dev/null \
              | jq -r '.[0].web_url // empty' 2>/dev/null || true)"
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
  local out
  out="$(glab mr create --source-branch "$head" --target-branch "$base" --title "$title" --description "$body" --squash-before-merge=true --yes 2>&1)"
  url="$(printf '%s' "$out" | grep -oE 'https?://[^ ]+/merge_requests/[0-9]+' | head -n1)"
  [[ -n "$url" ]] || { printf '%s\n' "$out" >&2; die "could not parse the MR URL from glab output"; }
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
#   iid <TAB> draft(yes|no) <TAB> author <TAB> updated(YYYY-MM-DD) <TAB> title <TAB> url
# Read-only. The key-filtered vcs_find_prs answers "where is ticket X?"; this answers "what is
# waiting?", which needs the whole open set and the fields a reviewer triages on.
vcs_list_prs() {
  glab api "projects/$(_gl_project)/merge_requests?state=opened&per_page=100&order_by=updated_at" 2>/dev/null \
    | jq -r '.[] | [ (.iid|tostring),
                     (if .draft then "yes" else "no" end),
                     (.author.username // "-"),
                     ((.updated_at // "")[0:10]),
                     (.title // ""),
                     (.web_url // "") ] | @tsv' 2>/dev/null || true
}

# vcs_pr_view NUMBER -> "state=<MERGED|OPEN|CLOSED>" + "merge_sha=<sha>".
vcs_pr_view() {
  local num="$1" json state sha up
  if ! json="$(glab api "projects/$(_gl_project)/merge_requests/$num" 2>/dev/null)"; then
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
  glab mr note "$num" --message "$full" >/dev/null || die "failed to post note on MR !$num"
  if [[ -n "$path" && -n "$line" ]]; then
    printf 'Comment posted on MR !%s (NON-inline note — see WARN above for why %s:%s did not anchor)\n' "$num" "$path" "$line"
  else
    printf 'Comment posted on MR !%s\n' "$num"
  fi
}

# vcs_pr_comments NUMBER -> prints the MR's notes as plain text.
vcs_pr_comments() {
  local num="$1"
  glab mr view "$num" --comments 2>/dev/null && return 0
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
  glab mr close "$num"
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
  if ! err=$(glab mr merge "$num" --squash --remove-source-branch --yes 2>&1); then
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
  local noted=0 err
  [[ -n "$body" ]] && { glab mr note "$num" --message "$body" >/dev/null || die "failed to post verdict note on MR !$num"; noted=1; }
  # A project can disable MR approvals outright (the API then answers 401/403). That is a
  # capability of this instance, not a failure of the review — and dying here used to leave a
  # half state: the verdict note was already posted, yet the script exited 1 and the caller
  # recorded the whole gate as broken. Degrade the way vcs_pr_comment does: fall to the tier
  # that DOES work (the note is the durable record), say so on stdout, and let the run continue.
  if err=$(glab mr approve "$num" 2>&1); then
    printf 'Approved MR !%s%s\n' "$num" "${body:+ (verdict note posted)}"
    return 0
  fi
  printf 'WARN: host-level approval unavailable on MR !%s — %s\n' "$num" "${err##*$'\n'}" >&2
  if [[ "$noted" -eq 0 ]]; then
    glab mr note "$num" --message "PASS (host-level approval is unavailable on this project; recording the verdict as a note)." >/dev/null \
      || die "MR !$num: approval was refused AND the fallback verdict note failed — nothing records this review"
  fi
  printf 'Approved MR !%s (verdict recorded as a NOTE — host-level approval unavailable on this project)\n' "$num"
}
