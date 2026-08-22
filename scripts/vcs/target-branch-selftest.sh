#!/usr/bin/env bash
#
# Target-branch regression for both VCS providers — reading what a PR/MR actually targets
# (`vcs_pr_view`) and repointing it (`vcs_pr_retarget`), offline.
#
# WHY THIS SUITE EXISTS. `vcs_pr_view` always fetched the WHOLE PR/MR object — target_branch
# included — and printed three of its fields. So the one question a pipeline needs to ask,
# "does this PR/MR target the branch the run said?", had no answer through the sanctioned
# tool, and the workspace correctly forbids reaching past the adapter to glab/gh. The result,
# measured on a four-repo ticket: the run reported its designed clean finish — reviewed,
# validated, MRs left open for a human — with every single MR pointed at a branch nobody had
# asked for, one of them at a branch that repo's own documented policy forbids. A human found
# it after the pipeline called itself done. There was also no way to REPAIR one: the adapter
# had `--target-branch` exactly once, at create, so the fix was close + reopen + re-approve,
# and GitLab does not carry approvals across that.
#
# The cases below are exactly the ones a live call cannot demonstrate safely:
#   * a PR/MR that targets the WRONG branch — you would have to mis-target somebody's real MR
#   * the API refusing — you cannot ask a working forge to fail on demand
#   * a retarget that took effect — asserted by watching what the CLI was actually asked to do,
#     which is the half that matters and is invisible from the outside
#
# Run:  scripts/vcs/target-branch-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
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
hasnt(){ case "$3" in *"$2"*) bad "$1" "must NOT contain: $2" "$3" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# ── The stubs. FIXTURE names a canned scenario; CALLS is the invocation log.
cat > "$BIN/glab" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  *"--method PUT"*)
    case "$FIXTURE" in
      retarget_refused) printf 'PUT forbidden\n' >&2; exit 22 ;;
      *)                printf '{"target_branch":"release/1.4"}\n' ;;
    esac ;;
  *"/approvals"*) printf '{"approved":false,"approvals_required":1,"approved_by":[]}\n' ;;
  *"/notes"*)     printf '[]\n' ;;
  *"merge_requests/"*)
    case "$FIXTURE" in
      on_target)  printf '{"state":"opened","target_branch":"develop","source_branch":"feature/APP-1"}\n' ;;
      off_target) printf '{"state":"opened","target_branch":"main","source_branch":"feature/APP-1"}\n' ;;
      api_down)   exit 22 ;;
      *)          printf '{"state":"opened","target_branch":"develop","source_branch":"feature/APP-1"}\n' ;;
    esac ;;
  *) printf '{}\n' ;;
esac
STUB

cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  "pr edit"*)
    case "$FIXTURE" in
      retarget_refused) printf 'could not update pull request\n' >&2; exit 1 ;;
      *)                printf 'https://github.com/o/r/pull/7\n' ;;
    esac ;;
  *"--json baseRefName -q"*) printf 'release/1.4\n' ;;
  *"--json state,mergeCommit,baseRefName,headRefName"*)
    case "$FIXTURE" in
      on_target)  printf '{"state":"OPEN","mergeCommit":null,"baseRefName":"develop","headRefName":"feature/APP-1"}\n' ;;
      off_target) printf '{"state":"OPEN","mergeCommit":null,"baseRefName":"main","headRefName":"feature/APP-1"}\n' ;;
      api_down)   exit 22 ;;
      *)          printf '{"state":"OPEN","mergeCommit":null,"baseRefName":"develop","headRefName":"feature/APP-1"}\n' ;;
    esac ;;
  *"--json reviews"*)  printf '{"reviews":[]}\n' ;;
  *"--json comments"*) printf '{"comments":[]}\n' ;;
  *) printf '{}\n' ;;
esac
STUB
chmod +x "$BIN/glab" "$BIN/gh"

run() {
  local provider="$1" fixture="$2"; shift 2
  CALLS="$TMP/calls.$$"; : > "$CALLS"
  PATH="$BIN:$PATH" FIXTURE="$fixture" CALLS="$CALLS" VCS_PROVIDER="$provider" VCS_REPO="group/project" \
    bash -c '
      . "$1"/lib.sh
      shift
      "$@"
    ' _ "$DIR" "$@" 2>&1
}
calls() { cat "$TMP/calls.$$" 2>/dev/null; }

for p in gitlab github; do
  echo "── $p: vcs_pr_view prints the branches"
  out="$(run "$p" on_target vcs_pr_view 7)"
  has "target_branch is printed at all"          "target_branch=develop"       "$out"
  has "…and so is the source branch"             "source_branch=feature/APP-1" "$out"
  has "the pre-existing fields are unchanged"    "state=OPEN"                  "$out"
  has "…including the approval line"             "approved="                   "$out"

  # The whole point: a gate must be able to tell these two apart through the adapter alone.
  out="$(run "$p" off_target vcs_pr_view 7)"
  has "a mis-targeted PR/MR reports its REAL target" "target_branch=main"      "$out"

  # An API that refuses must not answer with a plausible-looking branch. A gate that cannot
  # read the target has to record "unknown", never "fine" — the same never-fail-open rule the
  # test-suite audit runs on.
  out="$(run "$p" api_down vcs_pr_view 7)"
  has "an API refusal reports UNKNOWN state"      "state=UNKNOWN"              "$out"
  has "…and an EMPTY target, never a guess"       "target_branch="             "$out"
  hasnt "…so no branch name is invented"          "target_branch=develop"      "$out"

  echo "── $p: vcs_pr_retarget"
  out="$(run "$p" on_target vcs_pr_retarget 7 release/1.4)"
  has "the new target is read BACK from the forge" "target_branch=release/1.4"  "$out"

  out="$(run "$p" on_target vcs_pr_retarget 7 release/1.4 1)"
  has "--dry-run says what it would do"            "DRY RUN"                   "$out"
  has "…naming the branch"                         "release/1.4"               "$out"
  hasnt "…and calls no write"                      "PUT"                       "$(calls)"

  out="$(run "$p" retarget_refused vcs_pr_retarget 7 release/1.4)"
  hasnt "a refused retarget does not claim success" "target_branch=release/1.4" "$out"
done

echo "── the entry point"
out="$(PATH="$BIN:$PATH" bash "$DIR/retarget-pr.sh" --help 2>&1)"
has "--help documents --base"           "--base <branch>"  "$out"
out="$(PATH="$BIN:$PATH" VCS_PROVIDER=gitlab VCS_REPO=g/p bash "$DIR/retarget-pr.sh" 7 2>&1)"
has "a missing --base is refused, not guessed" "--base is required" "$out"
hasnt "…and it says it does not infer one"     "inferred a base"    "$out"

echo
if [[ "$fail" -gt 0 ]]; then printf '%s%d passed, %d FAILED%s\n' "$c_err" "$pass" "$fail" "$c_off"; exit 1; fi
printf '%s%d passed%s\n' "$c_ok" "$pass" "$c_off"
