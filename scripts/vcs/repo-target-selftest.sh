#!/usr/bin/env bash
#
# Repo-targeting regression for both VCS providers, offline.
#
# THE BUG THIS EXISTS TO CATCH. `glab api projects/<id>/…` and `gh api …` are scoped explicitly
# by the adapters. The providers' NATIVE subcommands — `glab mr create|note|view|close|merge|
# approve`, `gh pr create|list|view|edit|comment|review|close|merge` — are not: they resolve the
# project from the CURRENT WORKING DIRECTORY's git remote. In a multi-repo run the cwd is the
# workspace root, so every untargeted call acted on the wrong project. Worse, the failure was
# silent: `out="$(glab …)"` under `set -e` aborts on the resulting 404 before the function reaches
# its own `die`, so the caller saw exit 1 with no output at all.
#
# WHY A SINGLE-REPO TEST WOULD NOT CATCH IT. If the cwd's own remote happens to be the target, an
# untargeted call resolves correctly by coincidence and every assertion passes. So this harness
# runs from a checkout whose `origin` is DELIBERATELY a different project than VCS_REPO names —
# the exact multi-repo shape — and asserts the target on the wire, not the result.
#
# `glab` / `gh` are replaced by a stub on PATH that logs every invocation and answers enough JSON
# for the functions to run to completion. The assertions read the log.
#
# Run:  scripts/vcs/repo-target-selftest.sh
# Exit: 0 = all green, 1 = at least one call would have gone to the wrong repo.
#
# No network, no credentials used, no PR/MR touched.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

c_ok=$'\033[1;32m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_ok=; c_err=; c_off=; }
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  %s✓%s %s\n' "$c_ok" "$c_off" "$1"; }
bad()  { fail=$((fail+1)); printf '  %s✗%s %s\n     want %s\n     got  %s\n' "$c_err" "$c_off" "$1" "$2" "$3"; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

TARGET='group/sub/target-repo'   # what VCS_REPO names — the repo the call must land on
WRONG='group/ai-workspace'       # what the cwd's own origin says — the workspace root

# ── The cwd: a real checkout whose origin is the WRONG project. This is the whole point of the
# harness — with a matching origin the bug is invisible.
CWD="$TMP/workspace-root"; mkdir -p "$CWD"
git -C "$CWD" init -q 2>/dev/null
git -C "$CWD" remote add origin "git@gitlab.com:$WRONG.git"

# ── The stub. Logs every invocation, then answers the shapes these functions parse.
cat > "$BIN/glab" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  *"mr create"*)   printf 'https://gitlab.com/group/sub/target-repo/-/merge_requests/42\n' ;;
  *"/approvals"*)  printf '{"approved":false,"approvals_required":1,"approved_by":[]}\n' ;;
  *"/notes"*)      printf '[{"body":"looks fine"}]\n' ;;
  *"merge_requests?source_branch"*) printf '[]\n' ;;
  *"merge_requests/"*) printf '{"state":"opened","target_branch":"main","source_branch":"feature/X"}\n' ;;
  *) printf '{}\n' ;;
esac
STUB
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  *"pr create"*) printf 'https://github.com/group/target-repo/pull/42\n' ;;
  *"pr list"*)   printf '[]\n' ;;
  *"--json reviews"*)  printf '{"reviews":[]}\n' ;;
  *"--json comments"*) printf '{"comments":[]}\n' ;;
  *"pr view"*)   printf '{"state":"OPEN","baseRefName":"main","headRefName":"feature/X"}\n' ;;
  *) printf '{}\n' ;;
esac
STUB
chmod +x "$BIN/glab" "$BIN/gh"
# git must not actually push anywhere; the adapters push best-effort and ignore the result.
cat > "$BIN/git" <<STUB
#!/usr/bin/env bash
[[ "\$1" == push ]] && exit 0
exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="\$HOME" $(command -v git) "\$@"
STUB
chmod +x "$BIN/git"

# run PROVIDER FUNCTION ARGS… -> the invocation log, from a cwd whose origin is the WRONG repo.
run() {
  local provider="$1"; shift
  CALLS="$TMP/calls.$$"; : > "$CALLS"
  ( cd "$CWD" && PATH="$BIN:$PATH" CALLS="$CALLS" VCS_PROVIDER="$provider" VCS_REPO="$TARGET" \
      bash -c '. "$1"/lib.sh; shift; "$@" >/dev/null 2>&1' _ "$DIR" "$@" )
  cat "$CALLS" 2>/dev/null
}

# Every native invocation in the log must name the target. A line that names none is the bug —
# and so is a log with no native invocation at all: "nothing was called" must never read as
# "everything was targeted", which is the same fail-open shape as an un-run gate reporting green.
every_call_targeted() {
  local name="$1" flag="$2" verb_re="$3" log="$4" untargeted='' seen=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ $verb_re ]] || continue                 # api calls are scoped another way
    seen=$((seen+1))
    case "$line" in *"$flag $TARGET"*) ;; *) untargeted="$untargeted[$line] " ;; esac
  done <<< "$log"
  if [[ "$seen" -eq 0 ]]; then bad "$name" "at least one native call, all carrying $flag $TARGET" "no native call reached the CLI at all"
  elif [[ -z "$untargeted" ]]; then ok "$name ($seen call(s))"
  else bad "$name" "every native call carries $flag $TARGET" "$untargeted"; fi
}

echo "── gitlab: every native \`glab mr <verb>\` targets VCS_REPO, not the cwd remote"
for case in \
  "vcs_open_pr main feature/X title body" \
  "vcs_pr_comment 7 '' '' body" \
  "vcs_pr_comments 7" \
  "vcs_close_pr 7" \
  "vcs_merge_pr 7 subject" \
  "vcs_approve_pr 7 verdict"
do
  # shellcheck disable=SC2086
  log="$(run gitlab $case)"
  every_call_targeted "${case%% *}" "-R" '^mr ' "$log"
done

echo "── github: every native \`gh pr <verb>\` targets the resolved repo, not the cwd remote"
for case in \
  "vcs_open_pr main feature/X title body" \
  "vcs_pr_comment 7 '' '' body" \
  "vcs_pr_comments 7" \
  "vcs_close_pr 7" \
  "vcs_merge_pr 7 subject" \
  "vcs_approve_pr 7 verdict"
do
  # shellcheck disable=SC2086
  log="$(run github $case)"
  every_call_targeted "${case%% *}" "--repo" '^pr ' "$log"
done

# The wrapper announces the resolved target on stderr BEFORE the call. Several call sites capture
# stderr (`err=$(… 2>&1)`) or discard it (`2>/dev/null`) — that is the point rather than a gap: a
# capturing site folds the line into the error the caller then reports, which is exactly where a
# wrong-target call needs to be readable. `vcs_close_pr` leaves stderr alone, so it is where the
# line itself can be asserted.
echo "── the resolved target is announced, so a wrong-repo call is readable in the transcript"
for provider in gitlab github; do
  CALLS="$TMP/calls.$$"; : > "$CALLS"
  note="$( cd "$CWD" && PATH="$BIN:$PATH" CALLS="$CALLS" VCS_PROVIDER="$provider" VCS_REPO="$TARGET" \
      bash -c '. "$1"/lib.sh; vcs_close_pr 7' _ "$DIR" 2>&1 >/dev/null )"
  has "$provider: stderr names the resolved target" "$TARGET" "$note"
done

# The diagnostic must not be able to change a diagnosis. `vcs_merge_pr` captures its command's
# stderr and CLASSIFIES it (`*405*` ⇒ "this project refuses API merges"), so a target line written
# to fd 2 inside that call would let a repo whose NAME contains 405 turn any failure into that
# verdict. It goes to fd 9 instead. This asserts the outcome, not the plumbing.
echo "── a repo name that looks like an error code cannot rewrite the error"
CALLS="$TMP/calls.$$"; : > "$CALLS"
cat > "$BIN/glab" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in *"mr merge"*) printf 'dial tcp: connection refused\n' >&2; exit 1 ;; *) printf '{}\n' ;; esac
STUB
chmod +x "$BIN/glab"
err="$( cd "$CWD" && PATH="$BIN:$PATH" CALLS="$CALLS" VCS_PROVIDER=gitlab VCS_REPO='group/svc-405' \
    bash -c '. "$1"/lib.sh; vcs_merge_pr 7 subject' _ "$DIR" 2>&1 >/dev/null )"
has  "the real failure is reported"        'merge failed'            "$err"
case "$err" in *"refuses API merges"*) bad "not misread as a 405 refusal" "the generic merge failure" "$err" ;; *) ok "not misread as a 405 refusal" ;; esac

echo
if [[ "$fail" -eq 0 ]]; then printf '%s%d passed%s\n' "$c_ok" "$pass" "$c_off"; exit 0; fi
printf '%s%d passed · %d FAILED%s\n' "$c_err" "$pass" "$fail" "$c_off"; exit 1
