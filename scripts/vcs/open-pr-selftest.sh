#!/usr/bin/env bash
#
# `vcs_open_pr` regression for both providers, offline — specifically the FAILURE paths.
#
# WHY IT IS STUBBED RATHER THAN LIVE. The bug this file exists to keep dead was invisible
# from the outside and impossible to provoke on a healthy forge:
#
#   * `glab mr create` exits non-zero while PRINTING its reason. The adapter captured that
#     text and then died on the very next line — `url="$(… | grep -oE …)"`, where grep's
#     no-match exit 1 becomes the pipeline's status under `pipefail` and a failing
#     assignment is fatal under `set -e`. The caller got exit 1 and ZERO bytes. Nine
#     reproductions of that silence were read as "glab prints nothing for this project";
#     the text had been there every time. You cannot ask a working forge to fail on demand,
#     so the failing `glab` is a stub and the assertion is on what the adapter passes on.
#   * `glab mr create` fails AFTER the server created the MR (a webhook erroring the
#     response, a dropped connection after the POST). Reproducing that live means finding a
#     project configured to break; canned answers reproduce it exactly.
#   * the reuse short-circuit — proving it means proving `mr create` was NEVER invoked, and
#     "nothing happened" is only visible by watching the CLI.
#
# So `glab` / `gh` / `git` are replaced by stubs on PATH that answer from canned fixtures and
# APPEND EVERY INVOCATION to a log. `git` is stubbed too, and not for convenience: this
# function runs `git push -u <remote> <head>` and the suite must never touch a real remote.
#
# Run:  scripts/vcs/open-pr-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# No network, no credentials used, no PR/MR touched, nothing pushed.
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
isnt_empty() { [[ -n "${2//[[:space:]]/}" ]] && ok "$1" || bad "$1" "any output at all" "<zero bytes>"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# ── The stubs. FIXTURE names the scenario; CALLS is the invocation log.
#
# The fixtures, and the one fact each isolates:
#   ok                  create succeeds and prints the URL              — the happy path still works
#   fail_loud           create exits 1 PRINTING its reason              — the reason reaches the caller
#   fail_silent         create exits 1 printing NOTHING                 — the adapter is the reporter
#   fail_but_created    create exits 1, the forge HAS the MR            — reported as success, not failure
#   already_open        an open MR exists before we start               — create is never invoked
cat > "$BIN/glab" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1 $2" in
  "api projects"*)
    case "$FIXTURE" in
      already_open)     printf '[{"web_url":"https://gitlab.example.com/g/p/-/merge_requests/41"}]\n' ;;
      fail_but_created)
        # FIRST call (the reuse probe, before create) answers empty; the SECOND (after the
        # failed create) answers with the MR the server made anyway. The call log is the clock.
        if [[ "$(grep -c '^api projects' "$CALLS")" -le 1 ]]; then printf '[]\n'
        else printf '[{"web_url":"https://gitlab.example.com/g/p/-/merge_requests/77"}]\n'; fi ;;
      *)                printf '[]\n' ;;
    esac ;;
  "mr create")
    case "$FIXTURE" in
      ok)               printf 'https://gitlab.example.com/g/p/-/merge_requests/9\n'; exit 0 ;;
      fail_loud)        printf 'GitLab: 403 Forbidden - the merge request description template is required\n' >&2; exit 1 ;;
      fail_silent)      exit 1 ;;
      fail_but_created) exit 1 ;;
      *)                exit 1 ;;
    esac ;;
  *) printf '{}\n' ;;
esac
STUB

cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  *"repo view"*)   printf 'octo/repo\n'; exit 0 ;;
  *"pr create"*)
    case "$FIXTURE" in
      ok)               printf 'https://github.com/octo/repo/pull/9\n'; exit 0 ;;
      fail_loud)        printf 'GraphQL: A pull request already exists (createPullRequest)\n' >&2; exit 1 ;;
      fail_but_created) exit 1 ;;
      *)                exit 1 ;;
    esac ;;
  *"pr list"*)
    case "$FIXTURE" in
      already_open)     printf 'https://github.com/octo/repo/pull/41\n' ;;
      fail_but_created)
        if [[ "$(grep -c 'pr list' "$CALLS")" -le 1 ]]; then :
        else printf 'https://github.com/octo/repo/pull/77\n'; fi ;;
      *)                : ;;
    esac ;;
  *) printf '\n' ;;
esac
STUB

# The suite must never reach a real remote. `vcs_open_pr` pushes the head branch before it
# creates anything, so `git` is a stub that logs and agrees.
cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$CALLS"
exit 0
STUB
chmod +x "$BIN/glab" "$BIN/gh" "$BIN/git"

# run <provider> <fixture> -> combined stdout+stderr of one vcs_open_pr call; $CALLS holds the log.
run() {
  local provider="$1" fixture="$2"
  CALLS="$TMP/calls"; : > "$CALLS"
  PATH="$BIN:$PATH" FIXTURE="$fixture" CALLS="$CALLS" \
  VCS_PROVIDER="$provider" VCS_REPO="g/p" VCS_REMOTE="origin" \
    bash -c '
      . "$1"/lib.sh
      vcs_open_pr develop feature/FM-1 "feat(FM-1): thing" "body"
    ' _ "$DIR" 2>&1
}
calls() { cat "$TMP/calls" 2>/dev/null; }

echo "── gitlab: a create that FAILS must say so (the silent-exit regression)"
out="$(run gitlab fail_loud)"
# THE regression. Before the fix this was zero bytes: `set -e` killed the function at the
# url= assignment, one line before the code that prints all of this.
isnt_empty "a failing create is never silent"            "$out"
has        "glab's own reason reaches the caller"        "403 Forbidden"                  "$out"
has        "names glab's exit code"                      "glab mr create exited 1"        "$out"
has        "says plainly nothing was created"            "the MR was NOT created"         "$out"
has        "names the project it acted on"               "project g/p"                    "$out"
has        "names the branches"                          "feature/FM-1 -> develop"        "$out"

echo "── gitlab: a create that fails printing NOTHING still gets a diagnostic"
out="$(run gitlab fail_silent)"
isnt_empty "the adapter reports even when glab won't" "$out"
has        "still names the exit code"                   "glab mr create exited 1"        "$out"
has        "tells the reader the blank line is glab's"   "glab itself printed nothing"    "$out"

echo "── gitlab: a create that failed AFTER the server made the MR is a success"
out="$(run gitlab fail_but_created)"
has   "the MR the forge already has is returned"  "/merge_requests/77" "$out"
has   "and its number is parsed"                  "number=77"          "$out"
hasnt "no false 'NOT created'"                    "was NOT created"    "$out"

echo "── gitlab: the happy path and the reuse short-circuit are unchanged"
out="$(run gitlab ok)"
has   "creates and prints the URL"    "/merge_requests/9" "$out"
has   "and the number"                "number=9"          "$out"
out="$(run gitlab already_open)"; log="$(calls)"
has   "an open MR is reused"          "number=41"         "$out"
hasnt "create is NEVER invoked"       "mr create"         "$log"
hasnt "and nothing is pushed"         "git push"          "$log"

echo "── github: the same two failure contracts (siblings of one bug, not one provider's)"
out="$(run github fail_loud)"
isnt_empty "a failing create is never silent"      "$out"
has        "gh's own reason reaches the caller"    "A pull request already exists" "$out"
has        "names gh's exit code"                  "gh pr create exited 1"         "$out"
out="$(run github fail_but_created)"
has   "the PR the forge already has is returned"   "/pull/77"           "$out"
hasnt "no false 'NOT created'"                     "was NOT created"    "$out"
out="$(run github ok)"
has   "happy path unchanged"                       "/pull/9"            "$out"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
