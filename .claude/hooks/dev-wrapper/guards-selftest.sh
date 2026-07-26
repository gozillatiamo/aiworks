#!/usr/bin/env bash
#
# Regression suite for the delegation / artifact / git guards in this directory.
# Each case feeds a hook the same JSON shape Claude Code's PreToolUse sends and
# asserts the exit code: 0 = allow, 2 = block.
#
# Run:  .claude/hooks/dev-wrapper/guards-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# The allow cases matter as much as the block cases. A guard that blocks real
# work gets disabled by the first person it annoys, and then it guards nothing.
#
# Path cases run against THROWAWAY repos in a temp dir, not against whatever
# product repos this workspace happens to have cloned — so the suite is portable
# and its result does not depend on one org's directory names.

set -uo pipefail

H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$H/../../.." && pwd)"
export CLAUDE_PROJECT_DIR="$ROOT"

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A product repo: agent_logs/ git-ignored, plus a path hidden only by the LOCAL
# .git/info/exclude so the two kinds of "hidden" can be told apart.
mk_repo() {
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  printf 'agent_logs/\n' > "$d/.gitignore"
  printf 'localonly/\n' > "$d/.git/info/exclude"
  mkdir -p "$d/localonly" "$d/src"
  : > "$d/localonly/wrapper.sh"
  : > "$d/src/main.rs"
}
mk_repo svc      # a code repo
mk_repo db       # a second code repo
mk_repo e2e      # a test-suite repo
# A repo that ignores NOTHING. It exists to pin that `git -C <dir>` is honoured: the
# same path is ignored in svc and not here, so a guard that quietly fell back to its own
# cwd (as a broken -C extraction once did) gets the verdict wrong on one of the two.
mkdir -p "$TMP/plain" && git -C "$TMP/plain" init -q && mkdir -p "$TMP/plain/agent_logs"
# The meta-repo is identified by its own workspace.config.yaml.
mkdir -p "$TMP/meta" && git -C "$TMP/meta" init -q && : > "$TMP/meta/workspace.config.yaml"

pass=0; fail=0
t() { # t <name> <expected-exit> <hook> <json>
  local name=$1 want=$2 hook=$3 json=$4 got
  printf '%s' "$json" | "$H/$hook" >/dev/null 2>&1; got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s (want exit %s, got %s)\n' "$name" "$want" "$got"; fi
}
# tool_name is part of the real payload and some guards dispatch on it — omitting
# it made every env-guard case exit 0 (its `case "$tool"` fell through to the
# catch-all) and report a pass for a guard that had never run.
j()  { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
jw() { jq -cn --arg p "$1" '{tool_name:"Write",tool_input:{file_path:$p}}'; }
jr() { jq -cn --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p}}'; }
ja() { jq -cn --arg a "$1" --arg p "$2" '{tool_input:{subagent_type:$a,prompt:$p}}'; }

echo "--- pretool-git-guard ---"
t "push -o merge_request.create blocked"  2 pretool-git-guard.sh "$(j 'git push -o merge_request.create origin feature/APP-1')"
t "push --push-option= blocked"           2 pretool-git-guard.sh "$(j 'git push --push-option=merge_request.create origin x')"
t "plain push -u allowed"                 0 pretool-git-guard.sh "$(j 'git push -u origin feature/APP-1')"
t "add -f past .gitignore blocked"        2 pretool-git-guard.sh "$(j "git -C $TMP/svc add -f agent_logs/APP-1-svc-plan.md")"
t "add -f past info/exclude allowed"      0 pretool-git-guard.sh "$(j "git -C $TMP/svc add -f localonly/wrapper.sh")"
t "add -f mixed (one ignored) blocked"    2 pretool-git-guard.sh "$(j "git -C $TMP/svc add -f localonly/wrapper.sh agent_logs/APP-1-svc-plan.md")"
t "add -f . blocked (too broad)"          2 pretool-git-guard.sh "$(j "git -C $TMP/svc add -f .")"
t "add -f glob blocked (unresolvable)"    2 pretool-git-guard.sh "$(j "git -C $TMP/svc add -f agent_logs/*.md")"
t "add -f on a normal path allowed"       0 pretool-git-guard.sh "$(j "git -C $TMP/svc add -f src/main.rs")"
# -C must decide WHICH repo's ignore rules apply — same path, opposite verdicts.
t "-C honoured: ignoring repo blocks"     2 pretool-git-guard.sh "$(j "git -C $TMP/svc   add -f agent_logs/x.md")"
t "-C honoured: plain repo allows"        0 pretool-git-guard.sh "$(j "git -C $TMP/plain add -f agent_logs/x.md")"
t "-C quoted dir blocked"                 2 pretool-git-guard.sh "$(j "git -C \"$TMP/svc\" add -f agent_logs/x.md")"
t "git add -A allowed"                    0 pretool-git-guard.sh "$(j 'git add -A')"
t "git add <path> allowed"                0 pretool-git-guard.sh "$(j 'git add src/main.rs')"
t "commit with clean index allowed"       0 pretool-git-guard.sh "$(j "git -C $TMP/db commit -m 'chore: nothing staged'")"
t "git status allowed"                    0 pretool-git-guard.sh "$(j 'git status --short')"
t "non-git command allowed"               0 pretool-git-guard.sh "$(j 'cargo test')"
# A compound command must be read per SEGMENT: an unrelated -f flag elsewhere in
# the line is not a force-add, and a violation in a later segment still counts.
FA="add -f"   # kept out of the literals below so this suite's own command text
              # does not trip the guard when it is edited via a shell heredoc
t "compound: add + rm -rf is not force-add" 0 pretool-git-guard.sh "$(j "git -C $TMP/svc add src/main.rs && rm -rf $TMP/nothing")"
t "compound: push then tail -f allowed"     0 pretool-git-guard.sh "$(j 'git push origin x && tail -f log')"
t "force-add in a later segment caught"     2 pretool-git-guard.sh "$(j "echo hi && git -C $TMP/svc $FA agent_logs/APP-1-svc-plan.md")"

echo "--- pretool-notify-guard ---"
t "agent_logs path blocked"   2 pretool-notify-guard.sh "$(j "$ROOT/scripts/notify/send.sh --channel C1 \"plan at agent_logs/APP-1-svc-plan.html\"")"
t "/Users abs path blocked"   2 pretool-notify-guard.sh "$(j "$ROOT/scripts/notify/send.sh --channel C1 \"see /Users/someone/x/y.md\"")"
t ".html without url blocked" 2 pretool-notify-guard.sh "$(j "$ROOT/scripts/notify/send.sh --channel C1 \"rendered plan.html for you\"")"
t ".html with url allowed"    0 pretool-notify-guard.sh "$(j "$ROOT/scripts/notify/send.sh --channel C1 \"doc: https://claude.ai/code/artifact/x plan.html\"")"
t "--file attachment allowed" 0 pretool-notify-guard.sh "$(j "$ROOT/scripts/notify/send.sh --channel C1 --file .aiworks/out/r.pdf \"report\"")"
t "MR url text allowed"       0 pretool-notify-guard.sh "$(j "$ROOT/scripts/notify/send.sh --channel C1 \"MR: https://gitlab.com/x/-/merge_requests/1 ready\"")"
t "file:line ref allowed"     0 pretool-notify-guard.sh "$(j "$ROOT/scripts/notify/send.sh --channel C1 \"bug at src/dao/x.rs:256\"")"
t "unrelated command ignored"  0 pretool-notify-guard.sh "$(j 'echo agent_logs/whatever.html')"

echo "--- pretool-plan-path-guard ---"
t "flat <KEY>-plan.md blocked"   2 pretool-plan-path-guard.sh "$(jw "$TMP/svc/agent_logs/APP-1-plan.md")"
t "canonical .md allowed"        0 pretool-plan-path-guard.sh "$(jw "$TMP/svc/agent_logs/development-planner/APP-1-svc-plan.md")"
t "canonical .html allowed"      0 pretool-plan-path-guard.sh "$(jw "$TMP/svc/agent_logs/APP-1-svc-plan.html")"
t "foreign repo suffix blocked"  2 pretool-plan-path-guard.sh "$(jw "$TMP/svc/agent_logs/development-planner/APP-1-db-plan.md")"
t "second repo canonical ok"     0 pretool-plan-path-guard.sh "$(jw "$TMP/db/agent_logs/development-planner/APP-1-db-plan.md")"
t "automation-plan allowed"      0 pretool-plan-path-guard.sh "$(jw "$TMP/e2e/agent_logs/APP-1-automation-plan.md")"
t "testcases untouched"          0 pretool-plan-path-guard.sh "$(jw "$TMP/svc/agent_logs/APP-1-testcases.md")"
t "meta-repo plan blocked"       2 pretool-plan-path-guard.sh "$(jw "$TMP/meta/agent_logs/APP-1-plan.md")"
t "source file untouched"        0 pretool-plan-path-guard.sh "$(jw "$TMP/svc/src/main.rs")"
t ".html in subdir blocked"      2 pretool-plan-path-guard.sh "$(jw "$TMP/svc/agent_logs/development-planner/APP-1-svc-plan.html")"
t "no ticket key untouched"      0 pretool-plan-path-guard.sh "$(jw "$TMP/svc/agent_logs/rollout-plan.md")"
t "outside any repo fails open"  0 pretool-plan-path-guard.sh "$(jw "/nonexistent-root-xyz/agent_logs/APP-1-plan.md")"

echo "--- pretool-agent-brief-guard ---"
t "planner told to open MR blocked"   2 pretool-agent-brief-guard.sh "$(ja development-planner 'Produce the plan, then commit it and open a PR/MR for human review via the VCS adapter.')"
t "developer told to open MR ok"      0 pretool-agent-brief-guard.sh "$(ja developer 'Implement it, then open a PR/MR for human review via the VCS adapter.')"
t "brief ordering force-add blocked"  2 pretool-agent-brief-guard.sh "$(ja development-planner 'Write the plan and git add -f it since agent_logs is ignored.')"
t "brief with flat plan path blocked" 2 pretool-agent-brief-guard.sh "$(ja development-planner 'Publish the plan to agent_logs/APP-1-plan.md in the relevant repo.')"
t "clean brief allowed"               0 pretool-agent-brief-guard.sh "$(ja development-planner 'Plan APP-1 across every repo it touches; publish per docs/agents/plan-artifacts.md.')"
t "unknown agent fails open"          0 pretool-agent-brief-guard.sh "$(ja some-unknown-agent 'open a PR/MR please')"
t "empty prompt ignored"              0 pretool-agent-brief-guard.sh "$(ja development-planner '')"
# qa-planner is the QA-side planner: same plan-only boundary, so the same brief is a defect.
t "qa-planner told to open MR blocked" 2 pretool-agent-brief-guard.sh "$(ja qa-planner 'Design the BDD plan, then open a merge request for it.')"
t "qa-planner told to merge blocked"   2 pretool-agent-brief-guard.sh "$(ja qa-planner 'Once the suite is green, merge the PR yourself.')"
t "qa-planner clean brief allowed"     0 pretool-agent-brief-guard.sh "$(ja qa-planner 'Plan the tests for APP-1 in the e2e repo; publish onto the ticket and hand off to qa-runner.')"
# qa-runner DOES own the MR, so the same instruction must pass for it.
t "qa-runner told to merge allowed"    0 pretool-agent-brief-guard.sh "$(ja qa-runner 'Implement the suite, then open and merge the PR once green.')"

# --- 1b: the brief names a literal tool the agent's tools: list does not grant.
# Prose intent (above) only catches phrasings we thought of; these fire on the actual
# command handed to the agent, so they generalise past PR/MR to every adapter.
t "planner handed the notify adapter blocked" 2 pretool-agent-brief-guard.sh "$(ja development-planner 'Plan APP-1, then announce it with scripts/notify/send.sh.')"
t "code-reviewer may use notify"              0 pretool-agent-brief-guard.sh "$(ja code-reviewer 'Review the diff, then post the verdict with scripts/notify/send.sh.')"
t "product-owner handed the vcs adapter blocked" 2 pretool-agent-brief-guard.sh "$(ja product-owner 'Write the tickets, then run scripts/vcs/open-pr.sh for each.')"
t "product-owner may use the tracker"         0 pretool-agent-brief-guard.sh "$(ja product-owner 'Create the tickets with scripts/tracker/upsert-ticket-details.sh.')"
t "planner told to git commit blocked"        2 pretool-agent-brief-guard.sh "$(ja development-planner 'Plan it, then git commit the result on the ticket branch.')"
t "developer told to git commit allowed"      0 pretool-agent-brief-guard.sh "$(ja developer 'Implement it and git commit as you go.')"
# A grant the agent DOES hold must never trip 1b just because the path is named.
t "planner reading git status allowed"        0 pretool-agent-brief-guard.sh "$(ja development-planner 'Start from git status and git log to see what changed.')"
# The comment in development-planner/qa-planner frontmatter EXPLAINS that Bash(git *)
# was removed. Reading the file rather than the tools: list would credit them with it.
t "grant comment is not a grant"              2 pretool-agent-brief-guard.sh "$(ja qa-planner 'Plan the tests, then git push the branch.')"
# gh/glab belong to nobody — every provider goes through scripts/vcs/.
t "gh pr create blocked"                      2 pretool-agent-brief-guard.sh "$(ja developer 'Ship it with gh pr create --fill.')"
t "glab mr create blocked"                    2 pretool-agent-brief-guard.sh "$(ja qa-runner 'Then glab mr create --source-branch x.')"

echo "--- pretool-env-guard ---"
# This guard had no cases at all, which is how `rtk read <.env>` walked past it:
# the suite only ever proved the verbs someone had already thought of. The .env
# literals are assembled from $E so that editing this file through a shell
# heredoc cannot trip the guard on the suite's own text.
E='.env'
t "cat .env blocked"                2 pretool-env-guard.sh "$(j "cat scripts/tracker/$E")"
t "head .env blocked"               2 pretool-env-guard.sh "$(j "head -5 scripts/notify/$E")"
t "grep .env blocked"               2 pretool-env-guard.sh "$(j "grep TOKEN scripts/notify/$E")"
t "grep -q .env allowed (no print)" 0 pretool-env-guard.sh "$(j "grep -q '^SLACK_BOT_TOKEN=.\\+' scripts/notify/$E")"
t "Read of .env blocked"            2 pretool-env-guard.sh "$(jr "$TMP/svc/$E")"
t ".env.example readable"           0 pretool-env-guard.sh "$(jr "$TMP/svc/$E.example")"
t "bash -x near scripts/ blocked"   2 pretool-env-guard.sh "$(j 'bash -x scripts/tracker/get-ticket-details.sh APP-1')"
# rtk renames the reading verbs; the rtk hook rewrites `cat X` into `rtk read X`,
# so these are shapes the model reads back out of its own transcript.
t "rtk read .env blocked"           2 pretool-env-guard.sh "$(j "rtk read scripts/tracker/$E")"
t "rtk pipe < .env blocked"         2 pretool-env-guard.sh "$(j "rtk pipe < scripts/tracker/$E")"
t "rtk diff of two .env blocked"    2 pretool-env-guard.sh "$(j "rtk diff scripts/tracker/$E scripts/notify/$E")"
t "rtk read with a flag blocked"    2 pretool-env-guard.sh "$(j "rtk --ultra-compact read scripts/tracker/$E")"
t "rtk read .env.example allowed"   0 pretool-env-guard.sh "$(j "rtk read scripts/tracker/$E.example")"
# Names-only verbs stay allowed: over-blocking them buys no secrecy and the first
# person a guard annoys is the person who turns it off.
t "rtk find by name allowed"        0 pretool-env-guard.sh "$(j "rtk find . -name '*$E'")"
t "rtk ls of the dir allowed"       0 pretool-env-guard.sh "$(j 'rtk ls -la scripts/tracker')"
t "rtk wc of .env allowed"          0 pretool-env-guard.sh "$(j "rtk wc scripts/tracker/$E")"
# `read` and `diff` unanchored are ordinary words — blocking them would be noise.
t "bare diff of .env.example ok"    0 pretool-env-guard.sh "$(j "diff a/$E.example b/$E.example")"
t "unrelated rtk read allowed"      0 pretool-env-guard.sh "$(j 'rtk read src/main.rs')"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
