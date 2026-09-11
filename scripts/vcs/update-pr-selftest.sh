#!/usr/bin/env bash
#
# `vcs_pr_describe` regression for both providers, offline.
#
# WHY THIS EXISTS. The adapter could open a PR/MR and retarget one, but never re-describe one —
# so a description that went stale (a design that changed under review, a claim a later commit
# disproved) had no adapter route at all, and the only alternatives were leaving it wrong or
# reaching for `gh`/`glab` directly, which this workspace forbids.
#
# WHY IT IS STUBBED RATHER THAN LIVE. Same reasons as open-pr-selftest.sh: the failure paths are
# the point, and you cannot ask a healthy forge to fail on demand. `gh` and `glab` are stubs on
# PATH that answer from canned fixtures and APPEND EVERY INVOCATION to a log, so the assertions
# are on what the adapter SENDS and what it passes back.
#
# Run:  scripts/vcs/update-pr-selftest.sh
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

cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$CALLS"
case "$FIXTURE" in
  fail_loud) printf 'pull request edit failed: HTTP 422 Unprocessable Entity\n' >&2; exit 1 ;;
esac
case "$*" in
  *"--json title"*) printf '{"title":"the new title"}\n' ;;
esac
exit 0
STUB

cat > "$BIN/glab" <<'STUB'
#!/usr/bin/env bash
printf 'glab %s\n' "$*" >> "$CALLS"
case "$FIXTURE" in
  fail_loud) printf 'PUT https://gitlab.example.com/api/v4/...: 403 Forbidden\n' >&2; exit 1 ;;
esac
printf '{"iid":42,"title":"the new title","description":"the new body"}\n'
exit 0
STUB
chmod +x "$BIN/gh" "$BIN/glab"

# run <provider> <fixture> <title> <body> <dry> -> combined output; $CALLS holds the CLI log.
run() {
  local provider="$1" fixture="$2"
  CALLS="$TMP/calls"; : > "$CALLS"
  PATH="$BIN:$PATH" FIXTURE="$fixture" CALLS="$CALLS" \
  VCS_PROVIDER="$provider" VCS_REPO="g/p" VCS_REMOTE="origin" \
    bash -c '. "$1"/lib.sh; vcs_pr_describe 42 "$2" "$3" "$4"' _ "$DIR" "$3" "$4" "$5" 2>&1
}
calls() { cat "$TMP/calls" 2>/dev/null; }

echo "── github: a title and a body both reach the forge"
out="$(run github ok "the new title" "the new body" 0)"
has "gh pr edit is invoked for the number"  "pr edit --repo g/p 42"     "$(calls)"
has "the title is sent"                     "--title"        "$(calls)"
# The body goes through a FILE, never argv: a description is markdown of unbounded length and a
# multi-kilobyte argv is how this call would start failing on someone else's machine, not ours.
has "the body is sent as a file, not argv"  "--body-file"    "$(calls)"
hasnt "the body text never reaches argv"    "the new body"   "$(calls)"
has "it reports what it changed"            "updated=42"     "$out"

echo "── gitlab: description is the field, and the body may contain anything"
out="$(run gitlab ok "" "the new body" 0)"
has "a PUT on the merge request"            "merge_requests/42" "$(calls)"
has "the body lands in description"         "description="      "$(calls)"
hasnt "a title nobody passed is not sent"   "title="            "$(calls)"
has "it reports what it changed"            "updated=42"        "$out"

echo "── a forge that refuses must SAY so (never zero bytes)"
out="$(run github fail_loud "t" "b" 0)"
has "github passes the refusal on"          "422"            "$out"
out="$(run gitlab fail_loud "" "b" 0)"
has "gitlab passes the refusal on"          "403"            "$out"

echo "── --dry-run touches nothing"
out="$(run github ok "t" "b" 1)"
has "it says what it would do"              "DRY RUN"        "$out"
hasnt "and invokes no CLI at all"           "gh "            "$(calls)"
out="$(run gitlab ok "" "b" 1)"
hasnt "same for gitlab"                     "glab "          "$(calls)"

echo "── the CLI refuses a call that would change nothing"
out="$(PATH="$BIN:$PATH" VCS_PROVIDER=github VCS_REPO=g/p "$DIR/update-pr.sh" 42 2>&1)"
has "neither --title nor --body is an error" "nothing to update" "$out"

printf '\n%s\n' "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
