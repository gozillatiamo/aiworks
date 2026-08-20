#!/usr/bin/env bash
#
# Approval regression for both VCS providers — the read (`vcs_pr_approved`) and the
# write (`vcs_approve_pr`), offline.
#
# WHY IT IS STUBBED RATHER THAN LIVE. The two branches that matter here are the ones a
# live call cannot show you without side effects on somebody's real MR:
#
#   * the IDEMPOTENT early return — proving it means proving that NOTHING was posted,
#     and "nothing happened" is invisible from the outside. The only way to assert it is
#     to watch the CLI and see that `mr note` / `mr approve` were never invoked.
#   * the ZERO-REQUIRED-APPROVALS trap — GitLab answers `"approved": true` on an MR
#     nobody has approved when the project requires no approvals. Reproducing that live
#     needs a project configured that way on hand; canned JSON reproduces it exactly.
#   * the UNKNOWN path — an approvals endpoint that refuses. You cannot ask a working
#     forge to fail on demand.
#
# So `glab` / `gh` are replaced by a stub on PATH that answers from canned JSON and
# APPENDS EVERY INVOCATION to a log file. The assertions then read both: what the
# function printed, and — the part that matters — what it did or did not call.
#
# Run:  scripts/vcs/approve-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# No network, no credentials used, no MR touched.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

c_ok=$'\033[1;32m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_ok=; c_err=; c_off=; }
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  %s✓%s %s\n' "$c_ok" "$c_off" "$1"; }
bad()  { fail=$((fail+1)); printf '  %s✗%s %s\n     want %s\n     got  %s\n' "$c_err" "$c_off" "$1" "$2" "$3"; }
is()   { [[ "$3" == "$2" ]] && ok "$1" || bad "$1" "$2" "$3"; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1" "must NOT contain: $2" "$3" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# ── The stub. FIXTURE names a canned scenario; CALLS is the invocation log.
# It answers only the calls these two functions make, and exits non-zero for a
# scenario that is meant to model an endpoint refusing — that is the `unknown` input.
cat > "$BIN/glab" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1 $2" in
  "api projects"*) : ;;
  *) exit 0 ;;                                  # mr note / mr approve: succeed, log only
esac
case "$*" in
  *"/approvals"*)
    case "$FIXTURE" in
      approved)      printf '{"approved":true,"approvals_required":1,"approved_by":[{"user":{"username":"a-reviewer"}}]}\n' ;;
      zero_required) printf '{"approved":true,"approvals_required":0,"approved_by":[]}\n' ;;   # THE TRAP
      note_only)     printf '{"approved":false,"approvals_required":1,"approved_by":[]}\n' ;;
      unapproved)    printf '{"approved":false,"approvals_required":1,"approved_by":[]}\n' ;;
      endpoint_down) exit 22 ;;              # 401/403 on the approvals API, and NO marker note either
                                             # (approvals down + a marker note is note_only, and is a real yes)
      *)             printf '{"approved":false,"approved_by":[]}\n' ;;
    esac ;;
  *"/notes"*)
    case "$FIXTURE" in
      note_only)     printf '[{"body":"✅ APPROVED (host-level approval is unavailable on this project; recording the verdict as a note)."}]\n' ;;
      *)             printf '[{"body":"looks fine to me"}]\n' ;;   # endpoint_down included: no marker anywhere
    esac ;;
  *) printf '{}\n' ;;
esac
STUB

cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  *"--json reviews"*)
    case "$FIXTURE" in
      approved)   printf '{"reviews":[{"author":{"login":"a-reviewer"},"state":"APPROVED"}]}\n' ;;
      superseded) printf '{"reviews":[{"author":{"login":"a-reviewer"},"state":"APPROVED"},{"author":{"login":"a-reviewer"},"state":"CHANGES_REQUESTED"}]}\n' ;;
      note_only)  printf '{"reviews":[]}\n' ;;
      endpoint_down) exit 22 ;;
      *)          printf '{"reviews":[{"author":{"login":"someone"},"state":"COMMENTED"}]}\n' ;;
    esac ;;
  *"--json comments"*)
    case "$FIXTURE" in
      note_only)     printf '{"comments":[{"body":"✅ APPROVED (host-level approval is unavailable on this repository; recording the verdict as a comment.)"}]}\n' ;;
      *)             printf '{"comments":[{"body":"nice"}]}\n' ;;   # endpoint_down included: no marker anywhere
    esac ;;
  *) printf '{}\n' ;;
esac
STUB
chmod +x "$BIN/glab" "$BIN/gh"

# run <provider> <fixture> <function> [args…] -> stdout+stderr of the call; $CALLS holds the log.
# A fresh $CALLS per call, so "was it invoked" is answered per case and never leaks between them.
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

echo "── gitlab: vcs_pr_approved"
is  "real approver -> yes"            "yes"     "$(run gitlab approved      vcs_pr_approved 7)"
# The single most important case in this file: GitLab reports approved:true whenever the MR
# SATISFIES its rules, and zero-required is satisfied by nobody. Trusting .approved would
# freeze every review gate in a workspace whose projects require no approvals.
is  "zero required, nobody -> no"     "no"      "$(run gitlab zero_required vcs_pr_approved 7)"
is  "no approver -> no"               "no"      "$(run gitlab unapproved    vcs_pr_approved 7)"
is  "marker note is 2nd tier -> yes"  "yes"     "$(run gitlab note_only     vcs_pr_approved 7)"
is  "approvals API refuses -> unknown" "unknown" "$(run gitlab endpoint_down vcs_pr_approved 8)"

echo "── github: vcs_pr_approved"
is  "APPROVED review -> yes"          "yes"     "$(run github approved      vcs_pr_approved 7)"
# Latest review per author wins: an APPROVED a later CHANGES_REQUESTED superseded is not one.
is  "superseded approval -> no"       "no"      "$(run github superseded    vcs_pr_approved 7)"
is  "only a comment -> no"            "no"      "$(run github unapproved    vcs_pr_approved 7)"
is  "marker comment -> yes"           "yes"     "$(run github note_only     vcs_pr_approved 7)"
is  "reviews API refuses -> unknown"  "unknown" "$(run github endpoint_down vcs_pr_approved 8)"

echo "── the idempotent early return (nothing is posted twice)"
out="$(run gitlab approved vcs_approve_pr 7 "APPROVED — FM-1: 0 must-fix, tests green")"; log="$(calls)"
has   "gitlab: says already approved"        "already approved — nothing to do" "$out"
hasnt "gitlab: posts NO second verdict note" "mr note"                          "$log"
hasnt "gitlab: does NOT re-approve"          "mr approve"                       "$log"

out="$(run github approved vcs_approve_pr 7 "APPROVED — FM-1: 0 must-fix, tests green")"; log="$(calls)"
has   "github: says already approved"        "already approved — nothing to do" "$out"
hasnt "github: posts NO second verdict"      "pr review"                        "$log"
hasnt "github: posts NO comment"             "pr comment"                       "$log"

echo "── an UNAPPROVED MR still gets the tick (the early return is not a blanket skip)"
out="$(run gitlab unapproved vcs_approve_pr 7 "requirements met, tests green")"; log="$(calls)"
has "gitlab: approves"                "mr approve 7"    "$log"
has "gitlab: posts the verdict note"  "mr note"         "$log"
has "gitlab: marker prepended"        "✅ APPROVED — requirements met" "$log"
has "gitlab: reports success"         "Approved MR !7"  "$out"

out="$(run github unapproved vcs_approve_pr 7 "requirements met, tests green")"; log="$(calls)"
has "github: submits APPROVE review"  "pr review 7 --approve" "$log"
has "github: marker prepended"        "✅ APPROVED — requirements met" "$log"

echo "── UNKNOWN is not YES: a forge that won't answer still gets approved"
# The read treats unknown as unapproved (never skip a gate on an unanswered question); the
# write must agree, or an instance with approvals disabled would never be ticked at all.
out="$(run gitlab endpoint_down vcs_approve_pr 9 "tests green")"; log="$(calls)"
hasnt "gitlab: not short-circuited"   "already approved" "$out"
has   "gitlab: still attempts approve" "mr approve 9"    "$log"

echo "── empty --body: the documented 'approval only, no verdict note' call"
# REGRESSION. This was `[[ -n "$body" ]] && { … }`, whose exit status is 1 when the body is
# empty — and under `set -e` that killed the function before `glab mr approve` ever ran, so
# the documented approval-only call silently did nothing at all.
out="$(run gitlab unapproved vcs_approve_pr 7 "")"; log="$(calls)"
has   "gitlab: approves with no body" "mr approve 7" "$log"
hasnt "gitlab: posts no note"         "mr note"      "$log"
has   "gitlab: reports success"       "Approved MR !7" "$out"

out="$(run github unapproved vcs_approve_pr 7 "")"; log="$(calls)"
has "github: approves with no body"   "pr review 7 --approve" "$log"

echo "── pr-view.sh surfaces the state as a field"
has "gitlab: pr-view prints approved=" "approved=yes" \
    "$(CALLS="$TMP/v" PATH="$BIN:$PATH" FIXTURE=approved VCS_PROVIDER=gitlab VCS_REPO="group/project" "$DIR/pr-view.sh" 7 2>&1)"
is  "gitlab: --approved prints one word" "no" \
    "$(CALLS="$TMP/v" PATH="$BIN:$PATH" FIXTURE=zero_required VCS_PROVIDER=gitlab VCS_REPO="group/project" "$DIR/pr-view.sh" 7 --approved 2>&1)"

printf '\n%s\n' "$( [[ "$fail" -eq 0 ]] && printf '%s%d passed%s' "$c_ok" "$pass" "$c_off" || printf '%s%d passed · %d FAILED%s' "$c_err" "$pass" "$fail" "$c_off" )"
[[ "$fail" -eq 0 ]]
