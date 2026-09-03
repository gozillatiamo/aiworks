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
# Write/Edit WITH the payload text — the config-comment guard judges what is about to land
# in the file, not just which file it is.
jwc() { jq -cn --arg p "$1" --arg c "$2" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}'; }
jec() { jq -cn --arg p "$1" --arg s "$2" '{tool_name:"Edit",tool_input:{file_path:$p,new_string:$s}}'; }
jr() { jq -cn --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p}}'; }
ja() { jq -cn --arg a "$1" --arg p "$2" '{tool_input:{subagent_type:$a,prompt:$p}}'; }

echo "--- pretool-git-guard ---"
t "push -o merge_request.create blocked"  2 pretool-git-guard.sh "$(j 'git push -o merge_request.create origin feature/APP-1')"
t "push --push-option= blocked"           2 pretool-git-guard.sh "$(j 'git push --push-option=merge_request.create origin x')"
t "plain push -u allowed"                 0 pretool-git-guard.sh "$(j 'git push -u origin feature/APP-1')"
t "add -f past .gitignore blocked"        2 pretool-git-guard.sh "$(j "git -C $TMP/svc add -f agent_logs/APP-1-svc-plan.md")"
# Untracking a file that JUST became ignored is the one flow the ignored-path commit
# check must not block: `git rm --cached` stages a DELETION, which removes the path
# from the index rather than committing it. Before --diff-filter=d the guard saw the
# staged path, matched it against .gitignore, and made the untrack commit impossible.
# Its own repo, not svc: these two cases MUTATE the index, and a shared fixture would
# leak that state into whatever case runs next.
IGN="$TMP/ignoretrack"
mkdir -p "$IGN/agent_logs" && git -C "$IGN" init -q
printf 'agent_logs/\n' > "$IGN/.gitignore"
git -C "$IGN" add .gitignore && git -C "$IGN" commit -q -m base
: > "$IGN/agent_logs/legacy.md"
git -C "$IGN" add -f agent_logs/legacy.md && git -C "$IGN" commit -q -m "tracked before the rule"
git -C "$IGN" rm -q --cached agent_logs/legacy.md
t "untrack of a newly-ignored path allowed"  0 pretool-git-guard.sh "$(j "git -C $IGN commit -m untrack")"
# ...while ADDING an ignored path is still blocked, which is what the guard is for.
: > "$IGN/agent_logs/fresh.md"
git -C "$IGN" add -f agent_logs/fresh.md
t "commit that ADDS an ignored path blocked" 2 pretool-git-guard.sh "$(j "git -C $IGN commit -m add-ignored")"
t "add -f past info/exclude allowed"      0 pretool-git-guard.sh "$(j "git -C $TMP/svc add -f localonly/wrapper.sh")"
t "add -f mixed (one ignored) blocked"    2 pretool-git-guard.sh "$(j "git -C $TMP/svc add -f localonly/wrapper.sh agent_logs/APP-1-svc-plan.md")"
t "add -f . blocked (too broad)"          2 pretool-git-guard.sh "$(j "git -C $TMP/svc add -f .")"
t "add -f glob blocked (unresolvable)"    2 pretool-git-guard.sh "$(j "git -C $TMP/svc add -f agent_logs/*.md")"
t "add -f on a normal path allowed"       0 pretool-git-guard.sh "$(j "git -C $TMP/svc add -f src/main.rs")"
# Provider CLI — the same guard's rule 0. A mutating subcommand is a side-door around
# scripts/vcs/; a read-only one is not. Unknown verbs fail CLOSED, and a mention (quoted
# prose, a grep argument) is never an invocation — an agent has to be able to WRITE about
# the prohibition it is under.
t "glab mr create blocked"                2 pretool-git-guard.sh "$(j 'glab mr create --title x --yes')"
t "gh pr merge blocked"                   2 pretool-git-guard.sh "$(j 'gh pr merge 42 --squash')"
t "glab mr update blocked"                2 pretool-git-guard.sh "$(j 'glab mr update 20 --description y')"
t "glab issue create blocked"             2 pretool-git-guard.sh "$(j 'glab issue create --title x')"
t "unknown provider verb fails closed"    2 pretool-git-guard.sh "$(j 'glab mr frobnicate 7')"
t "cd && glab mr update blocked"          2 pretool-git-guard.sh "$(j 'cd /tmp/x && glab mr update 20 --description y')"
t "glab api POST blocked"                 2 pretool-git-guard.sh "$(j 'glab api --method POST projects/1/notes')"
t "gh api -X DELETE blocked"              2 pretool-git-guard.sh "$(j 'gh api -X DELETE repos/o/r/issues/1')"
t "glab mr view allowed"                  0 pretool-git-guard.sh "$(j 'glab mr view 20')"
t "gh pr list allowed"                    0 pretool-git-guard.sh "$(j 'gh pr list')"
t "glab api GET allowed"                  0 pretool-git-guard.sh "$(j 'glab api projects/123/merge_requests')"
t "grep of a provider cmd allowed"        0 pretool-git-guard.sh "$(j 'grep -n glab scripts/vcs/gitlab.sh')"
t "quoted mention allowed"                0 pretool-git-guard.sh "$(j 'echo "never run glab mr create by hand"')"
t "adapter call itself allowed"           0 pretool-git-guard.sh "$(j 'scripts/vcs/open-pr.sh --title x --body y')"
t "word containing gh allowed"            0 pretool-git-guard.sh "$(j 'echo the throughput is high tonight')"
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
t "run-state json ignored"       0 pretool-plan-path-guard.sh "$(jw "$TMP/svc/agent_logs/APP-1-dev-cycle-state/svc-built.json")"

echo "--- pretool-config-comment-guard ---"
HASH='#'   # kept out of the literals so editing this suite through a heredoc stays honest
t "comment-only line blocked"    2 pretool-config-comment-guard.sh "$(jwc "$TMP/meta/workspace.config.yaml" "$HASH the org
org:
  name: Acme")"
t "trailing comment blocked"     2 pretool-config-comment-guard.sh "$(jwc "$TMP/meta/workspace.config.yaml" "language: th  $HASH personal")"
t "clean config allowed"         0 pretool-config-comment-guard.sh "$(jwc "$TMP/meta/workspace.config.yaml" "org:
  name: Acme
language: th")"
# The one edit most likely to be legitimate — a Slack channel is a value that STARTS with #.
t "quoted hash value allowed"    0 pretool-config-comment-guard.sh "$(jwc "$TMP/meta/workspace.config.yaml" "notify:
  channel: \"${HASH}dev-acme\"")"
t "url fragment allowed"         0 pretool-config-comment-guard.sh "$(jwc "$TMP/meta/workspace.config.yaml" "url: git@host:org/repo${HASH}tag")"
# A block scalar's body is verbatim text, so a # in it is content.
t "block scalar body allowed"    0 pretool-config-comment-guard.sh "$(jwc "$TMP/meta/workspace.config.yaml" "desc: |
  ${HASH} still data
  x")"
t "local config blocked too"     2 pretool-config-comment-guard.sh "$(jwc "$TMP/meta/workspace.config.local.yaml" "$HASH mine
language: th")"
t "Edit new_string blocked"      2 pretool-config-comment-guard.sh "$(jec "$TMP/meta/workspace.config.yaml" "  enabled: true   $HASH turned on")"
t "Edit clean allowed"           0 pretool-config-comment-guard.sh "$(jec "$TMP/meta/workspace.config.yaml" "  enabled: true")"
# The templates are the DOCUMENTATION — comments there are the whole point.
t "example template allowed"     0 pretool-config-comment-guard.sh "$(jwc "$TMP/meta/workspace.config.example.yaml" "$HASH what this key does
language: en")"
t "local example allowed"        0 pretool-config-comment-guard.sh "$(jwc "$TMP/meta/workspace.config.local.example.yaml" "$HASH copy me
language: th")"
t "other yaml untouched"         0 pretool-config-comment-guard.sh "$(jwc "$TMP/meta/mani.d/acme.yaml" "$HASH GENERATED
projects: {}")"
t "no payload fails open"        0 pretool-config-comment-guard.sh "$(jw "$TMP/meta/workspace.config.yaml")"

echo "--- yaml_comments scanner (the guard's # detection) ---"
if python3 "$ROOT/scripts/lib/yaml_comments.py" --selftest >/dev/null 2>&1; then
  pass=$((pass+1)); printf 'ok   %s\n' "scanner fixtures green"
else
  fail=$((fail+1)); printf 'FAIL %s\n' "scanner fixtures (run scripts/lib/yaml_comments.py --selftest)"
fi

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
# The GATES no longer hold notify: announcing a verdict to chat is orchestrator-owned (the
# dev-cycle Notify phase / ultra-review §4 gather every gate across every repo and send once).
# A gate-owned announcement is non-deterministic — a gate that runs out of turns posts nothing —
# and duplicates the digest the orchestrator sends anyway. This guard reads the grant straight
# out of the agent definition, so dropping it there is what makes these two cases block.
t "code-reviewer handed the notify adapter blocked" 2 pretool-agent-brief-guard.sh "$(ja code-reviewer 'Review the diff, then post the verdict with scripts/notify/send.sh.')"
t "perf gate handed the notify adapter blocked"     2 pretool-agent-brief-guard.sh "$(ja performance-engineer 'Profile the MR, then thread the verdict with scripts/notify/send.sh.')"
t "code-reviewer may still use vcs"           0 pretool-agent-brief-guard.sh "$(ja code-reviewer 'Review the diff, then post each finding with scripts/vcs/pr-comment.sh.')"
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
# This guard once had no cases at all, which is how a renamed reading verb walked
# past it: the suite only ever proved the verbs someone had already thought of. The
# .env literals are assembled from $E so that editing this file through a shell
# heredoc cannot trip the guard on the suite's own text.
E='.env'
t "cat .env blocked"                2 pretool-env-guard.sh "$(j "cat scripts/tracker/$E")"
t "head .env blocked"               2 pretool-env-guard.sh "$(j "head -5 scripts/notify/$E")"
t "grep .env blocked"               2 pretool-env-guard.sh "$(j "grep TOKEN scripts/notify/$E")"
t "grep -q .env allowed (no print)" 0 pretool-env-guard.sh "$(j "grep -q '^SLACK_BOT_TOKEN=.\\+' scripts/notify/$E")"
t "Read of .env blocked"            2 pretool-env-guard.sh "$(jr "$TMP/svc/$E")"
t ".env.example readable"           0 pretool-env-guard.sh "$(jr "$TMP/svc/$E.example")"
t "bash -x near scripts/ blocked"   2 pretool-env-guard.sh "$(j 'bash -x scripts/tracker/get-ticket-details.sh APP-1')"
# Names-only verbs stay allowed: over-blocking them buys no secrecy and the first
# person a guard annoys is the person who turns it off.
t "find by name allowed"            0 pretool-env-guard.sh "$(j "find . -name '*$E'")"
t "ls of the dir allowed"           0 pretool-env-guard.sh "$(j 'ls -la scripts/tracker')"
t "wc of .env allowed"              0 pretool-env-guard.sh "$(j "wc -l scripts/tracker/$E")"
# `read` and `diff` unanchored are ordinary words — blocking them would be noise.
t "bare diff of .env.example ok"    0 pretool-env-guard.sh "$(j "diff a/$E.example b/$E.example")"
# hcat is the headroom plugin's compress-at-the-source reader: a RENAMED cat, and exactly the
# case the comment above warns about. It needs its OWN alternative because `\bcat\b` cannot
# match "hcat" — the leading h is a word character, so there is no boundary before "cat".
t "hcat .env blocked"               2 pretool-env-guard.sh "$(j "hcat scripts/tracker/$E")"
t "hcat quoted .env blocked"        2 pretool-env-guard.sh "$(j "hcat \"scripts/notify/$E\"")"
t "hcat .env after && blocked"      2 pretool-env-guard.sh "$(j "cd /tmp && hcat $E")"
t "hcat .env.example allowed"       0 pretool-env-guard.sh "$(j "hcat scripts/tracker/$E.example")"
t "hcat of ordinary json allowed"   0 pretool-env-guard.sh "$(j 'hcat build/report.json')"
# A word merely ENDING in cat must not inherit the verb match in either direction.
t "whcat is not a reading verb"     0 pretool-env-guard.sh "$(j "./whcat report.json")"
# A template is any path ENDING in .example, not just the exact `.env.example`.
# Real files here: .env.amb.example and .env.local.example — both were blocked as
# secrets by an exemption that matched one literal string. They hold no values, and
# over-blocking is how a guard gets switched off. `.env.example.bak` is NOT a
# template (it does not end in .example) and must stay blocked.
t "hcat .env.amb.example allowed"    0 pretool-env-guard.sh "$(j "hcat dev-script/x/$E.amb.example")"
t "hcat .env.local.example allowed"  0 pretool-env-guard.sh "$(j "hcat app/$E.local.example")"
t "cat .env.local.example allowed"   0 pretool-env-guard.sh "$(j "cat app/$E.local.example")"
t "Read .env.amb.example allowed"    0 pretool-env-guard.sh "$(jr "$TMP/svc/$E.amb.example")"
t "Read .env.local.example allowed"  0 pretool-env-guard.sh "$(jr "$TMP/svc/$E.local.example")"
t "proxy.env.example allowed"        0 pretool-env-guard.sh "$(jr "$TMP/svc/proxy${E#.}.example")"
t "env.config.example.json allowed"  0 pretool-env-guard.sh "$(jr "$TMP/svc/${E#.}.config.example.json")"
# ...and the variants they were confused with are still secrets.
t "hcat .env.amb blocked"            2 pretool-env-guard.sh "$(j "hcat dev-script/x/$E.amb")"
t "Read .env.local blocked"          2 pretool-env-guard.sh "$(jr "$TMP/svc/$E.local")"
t "Read .env.example.bak blocked"    2 pretool-env-guard.sh "$(jr "$TMP/svc/$E.example.bak")"

echo "--- pretool-hcat-size-guard ---"
# hcat has no upper bound of its own, and headroom passes content through UNCHANGED when
# compression would not help — measured on a 250 MB log: 0.0% saved, 262 MB printed, 80s.
# The size guard is the ceiling. Fixtures are sparse files so the suite stays instant.
mkdir -p "$TMP/big"
: > "$TMP/big/small.json"; printf '{"a":1}' > "$TMP/big/small.json"
dd if=/dev/zero of="$TMP/big/huge.log" bs=1 count=0 seek=3145728 2>/dev/null   # 3 MiB > the 2 MiB cap
jc() { jq -cn --arg c "$1" --arg d "$TMP/big" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
t "hcat of a 3 MiB file blocked"    2 pretool-hcat-size-guard.sh "$(jc "hcat $TMP/big/huge.log")"
t "hcat quoted huge blocked"        2 pretool-hcat-size-guard.sh "$(jc "hcat \"$TMP/big/huge.log\"")"
t "hcat huge relative to cwd blocked" 2 pretool-hcat-size-guard.sh "$(jc 'hcat huge.log')"
t "hcat huge after && blocked"      2 pretool-hcat-size-guard.sh "$(jc "cd /tmp && hcat $TMP/big/huge.log")"
t "hcat of a small file allowed"    0 pretool-hcat-size-guard.sh "$(jc "hcat $TMP/big/small.json")"
# Scope is the verb this workspace introduced. A bare `cat` of a huge file is pre-existing
# behaviour that posttool-output-warden.sh already reports on.
t "plain cat of huge allowed"       0 pretool-hcat-size-guard.sh "$(jc "cat $TMP/big/huge.log")"
# The escape hatch this guard's own message documents. It has to be parsed out of the COMMAND:
# a hook runs in its own process, so an inline `VAR=x <cmd>` assignment never reaches its
# environment, and reading it from there made the promise a no-op.
t "inline HCAT_MAX_BYTES honoured"  0 pretool-hcat-size-guard.sh "$(jc "HCAT_MAX_BYTES=99999999 hcat $TMP/big/huge.log")"
t "missing file fails open"         0 pretool-hcat-size-guard.sh "$(jc 'hcat /nonexistent/x.json')"
t "the word hcat alone allowed"     0 pretool-hcat-size-guard.sh "$(jc 'echo hcat')"
t "non-Bash tool ignored"           0 pretool-hcat-size-guard.sh "$(jr "$TMP/big/huge.log")"

echo "--- pretool-hrun-pipe-guard ---"
# hrun prints a RENDERING, not data: above its threshold the output carries hcat's receipt header
# and may be a compressed body. Measured: `hrun cat t.json > y.json` yields a y.json no JSON parser
# accepts, silently. hrun cannot detect this itself — under the Bash tool stdout is never a TTY
# whether the output is about to be read or about to be swallowed — so the shape is judged here.
t "hrun bare allowed"                  0 pretool-hrun-pipe-guard.sh "$(j 'hrun cargo test')"
t "hrun redirected to a file blocked"  2 pretool-hrun-pipe-guard.sh "$(j 'hrun cat t.json > y.json')"
t "hrun appended to a file blocked"    2 pretool-hrun-pipe-guard.sh "$(j 'hrun ls >> out.txt')"
t "hrun piped blocked"                 2 pretool-hrun-pipe-guard.sh "$(j 'hrun git diff | head -20')"
t "hrun in \$() blocked"                2 pretool-hrun-pipe-guard.sh "$(j 'X=$(hrun cat f.json)')"
# Backticks are an ACCEPTED MISS, not an oversight. When they counted, the guard blocked its own
# commit — the message quoted the hazard in backticks. Prose about the verb outnumbers legacy
# backtick substitution of it, and a guard that blocks writing about a tool gets switched off.
t "backtick substitution is a known miss" 0 pretool-hrun-pipe-guard.sh "$(j 'X=`hrun cat f.json`')"
t "prose quoting hrun in backticks ok"    0 pretool-hrun-pipe-guard.sh "$(j 'git commit -m "explains `hrun x > y` is unsafe"')"
t "modern \$() substitution still blocked" 2 pretool-hrun-pipe-guard.sh "$(j 'X=$(scripts/hrun cat f.json)')"
# stdin going INTO hrun is untouched passthrough — it is hrun's own stdout that must not be eaten.
t "piping INTO hrun allowed"           0 pretool-hrun-pipe-guard.sh "$(j 'cat f | hrun grep needle')"
# hrun merges stderr into stdout itself, so a numbered redirect changes nothing — denying it would
# be a false positive, and a guard that cries wolf gets switched off.
t "numbered redirect allowed"          0 pretool-hrun-pipe-guard.sh "$(j 'hrun cargo test 2>/dev/null')"
t "the word hrun alone allowed"        0 pretool-hrun-pipe-guard.sh "$(j 'echo hrun')"
t "hrunner is not hrun"                0 pretool-hrun-pipe-guard.sh "$(j 'hrunner --list | head')"
# MENTION vs CALL. `\bhrun\b` matches inside "pretool-hrun-pipe-guard.sh", so grepping for this
# guard's own filename got blocked for "piping hrun" — the first real command after it was written.
# Command position is the test; a hyphen after the name is not whitespace, so a filename cannot
# qualify. Same failure class as the adapter pipe guard's.
t "grep for the guard's filename ok"   0 pretool-hrun-pipe-guard.sh "$(j 'grep -n "hrun-pipe-guard" scripts/aiworks-add.sh | head')"
# hrun ships at scripts/hrun and is documented to be called that way, so a bare-name-only rule
# left this guard inert on every real invocation. Found by piping scripts/hrun in its own test.
t "path-prefixed hrun piped blocked"   2 pretool-hrun-pipe-guard.sh "$(j 'scripts/hrun cat big.log | head -1')"
t "./-prefixed hrun redirect blocked"  2 pretool-hrun-pipe-guard.sh "$(j './scripts/hrun ls > out.txt')"
t "absolute-path hrun piped blocked"   2 pretool-hrun-pipe-guard.sh "$(j '/usr/local/bin/hrun ls | wc -l')"
t "path-prefixed hrun bare allowed"    0 pretool-hrun-pipe-guard.sh "$(j 'scripts/hrun cargo test')"
t "ls of the guard file ok"            0 pretool-hrun-pipe-guard.sh "$(j 'ls .claude/hooks/dev-wrapper/pretool-hrun-pipe-guard.sh | head -1')"
t "hrun quoted inside echo ok"         0 pretool-hrun-pipe-guard.sh "$(j 'echo "run hrun bare, never hrun x | y"')"
# The escape hatch has to be read off the command string: a VAR=1 prefix never reaches this hook's
# own environment, so an env-only check would document a hatch that does not work.
t "inline HRUN_ALLOW_PIPE opts out"    0 pretool-hrun-pipe-guard.sh "$(j 'HRUN_ALLOW_PIPE=1 hrun ls | head')"
t "non-Bash tool ignored"              0 pretool-hrun-pipe-guard.sh "$(jr /tmp/x.json)"

echo "--- pretool-env-guard: hrun is a reading verb too ---"
# hrun runs ANY command and prints what it printed, so `hrun cat .env` leaks exactly as `cat .env`
# does — and unlike hcat its name contains no "cat" for the existing alternation to catch.
t "hrun cat .env blocked"              2 pretool-env-guard.sh "$(j 'hrun cat scripts/notify/.env')"
t "hrun cat .env.example allowed"      0 pretool-env-guard.sh "$(j 'hrun cat scripts/notify/.env.example')"

echo "== pretool-agent-context: the spawn brief carries the resolved language =="
# This hook REWRITES rather than blocks, so exit-code cases prove nothing on their own —
# every case here asserts what came out. A fixture root per language, because the real
# workspace resolves to whatever this org configured and a suite must not depend on that.
mkdir -p "$TMP/th/.claude/agents" "$TMP/en/.claude/agents"
printf 'language: en\n' > "$TMP/th/workspace.config.yaml"
printf 'language: th\n' > "$TMP/th/workspace.config.local.yaml"   # personal override WINS
printf 'language: en\n' > "$TMP/en/workspace.config.yaml"
# A named agent preloads caveman in its own frontmatter; a def-less type cannot.
for r in th en; do printf 'skills:\n  - caveman:caveman\ntools:\n  - Read\n' > "$TMP/$r/.claude/agents/namedagent.md"; done

ac() { # ac <root> <subagent_type> <prompt> -> the rewritten prompt ('' when no rewrite)
  jq -cn --arg a "$2" --arg p "$3" \
    '{tool_name:"Agent",tool_input:{subagent_type:$a,description:"d",prompt:$p}}' \
  | CLAUDE_PROJECT_DIR="$TMP/$1" "$H/pretool-agent-context.sh" 2>/dev/null \
  | jq -r '.hookSpecificOutput.updatedInput.prompt // ""' 2>/dev/null
}
has() { # has <name> <yes|no> <haystack> <needle>
  local got=no; case "$3" in *"$4"*) got=yes ;; esac
  if [ "$got" = "$2" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL %s (wanted %s)\n' "$1" "$2"; fi
}

out=$(ac th namedagent 'Do the thing.')
has "th: named agent gets the language" yes "$out" 'OUTPUT LANGUAGE = th'
# A definition that already preloads caveman must not be told again — 16 definitions
# paying for the same paragraph twice is the whole cost of getting this wrong.
has "th: named agent not re-told caveman" no "$out" 'CAVEMAN_DIRECTIVE'
has "th: original brief kept intact"  yes "$out" 'Do the thing.'

out=$(ac th general-purpose 'Find X.')
has "th: def-less gets the language"  yes "$out" 'OUTPUT LANGUAGE = th'
has "th: def-less gets caveman"       yes "$out" 'CAVEMAN_DIRECTIVE'

# The local override is the case the prose-only fix kept missing: two of five probe agents
# read the SHARED file and announced en on a workspace resolved to th.
out=$(ac en general-purpose 'Find X.')
has "en: no language directive"       no  "$out" 'OUTPUT LANGUAGE'
has "en: caveman still injected"      yes "$out" 'CAVEMAN_DIRECTIVE'

# Idempotence. A workflow already bakes both in; appending a second copy would double a
# ~200-word paragraph on every spawn of a 26-agent run.
out=$(ac th general-purpose 'X LANGUAGE_DIRECTIVE — OUTPUT LANGUAGE = th … CAVEMAN_DIRECTIVE — …')
has "already-injected brief untouched" no "$out" 'OUTPUT LANGUAGE = th, already resolved'

# The rewrite must carry the WHOLE tool_input. Emitting only `prompt` would drop
# subagent_type, and the spawn would silently become some other agent.
keep=$(jq -cn '{tool_name:"Agent",tool_input:{subagent_type:"general-purpose",description:"d",prompt:"p",model:"haiku"}}' \
  | CLAUDE_PROJECT_DIR="$TMP/th" "$H/pretool-agent-context.sh" 2>/dev/null \
  | jq -r '[.hookSpecificOutput.updatedInput.subagent_type, .hookSpecificOutput.updatedInput.model, .hookSpecificOutput.updatedInput.description] | join(",")')
if [ "$keep" = "general-purpose,haiku,d" ]; then pass=$((pass+1)); printf 'ok   %s\n' "rewrite preserves subagent_type/model/description"
else fail=$((fail+1)); printf 'FAIL %s (got %s)\n' "rewrite preserves subagent_type/model/description" "$keep"; fi

t "agent-context never blocks"      0 pretool-agent-context.sh "$(ja general-purpose 'anything at all')"
t "agent-context on empty prompt"   0 pretool-agent-context.sh "$(ja general-purpose '')"
has "unknown agent type treated as def-less" yes "$(ac th no-such-agent 'Find X.')" 'CAVEMAN_DIRECTIVE'

echo "== pretool-agent-context: ponytail carve-outs reach the code-shaping agents only =="
# The LADDER is the ponytail plugin's own SubagentStart injection and is not this hook's job.
# What is asserted here is the workspace half: who gets the carve-outs, and who must not.
for r in th en; do
  printf 'skills:\n  - caveman:caveman\n' > "$TMP/$r/.claude/agents/ponytailagent.md"
  printf 'PONYTAIL_GUARDRAILS carried inline by this definition.\n' >> "$TMP/$r/.claude/agents/ponytailagent.md"
  printf 'skills:\n  - caveman:caveman\nRun /ponytail-review on the diff.\n' > "$TMP/$r/.claude/agents/reviewmention.md"
done
PT_M='^(developer|ponytailagent|reviewmention)$|cavecrew-builder'

acm() { # acm <root> <matcher> <subagent_type> <prompt> -> the rewritten prompt
  jq -cn --arg a "$3" --arg p "$4" \
    '{tool_name:"Agent",tool_input:{subagent_type:$a,description:"d",prompt:$p}}' \
  | PONYTAIL_SUBAGENT_MATCHER="$2" CLAUDE_PROJECT_DIR="$TMP/$1" "$H/pretool-agent-context.sh" 2>/dev/null \
  | jq -r '.hookSpecificOutput.updatedInput.prompt // ""' 2>/dev/null
}

has "matcher: code-shaping type gets carve-outs" yes "$(acm th "$PT_M" developer 'Build X.')" 'PONYTAIL_GUARDRAILS'
# The cost lever. An oncall/designer/planner spawn receives no ladder from the plugin, so
# handing it carve-outs for a ladder it never got is pure tokens — and the two must agree.
has "matcher: non-code type gets none"           no  "$(acm th "$PT_M" oncall 'Investigate X.')" 'PONYTAIL_GUARDRAILS'
has "matcher: plugin agent type matches"         yes "$(acm th "$PT_M" 'caveman:cavecrew-builder' 'Edit X.')" 'PONYTAIL_GUARDRAILS'
# Unset matcher = the plugin injects into every subagent, so the carve-outs follow it there.
has "no matcher: everyone gets carve-outs"       yes "$(acm th '' documentor 'Write X.')" 'PONYTAIL_GUARDRAILS'
# A regex grep cannot parse must fail OPEN: carve-outs where they were not needed cost
# tokens, a money path built without them costs more.
has "unparseable matcher fails open"             yes "$(acm th '*[' developer 'Build X.')" 'PONYTAIL_GUARDRAILS'
# Idempotence — dev-cycle bakes its own copy into the plan/build/pr-fix prompts.
has "already-injected brief untouched (ponytail)" no "$(acm th "$PT_M" developer 'X PONYTAIL_GUARDRAILS — …')" 'ponytail (`/ponytail:ponytail`'
# Opt-out is the literal TOKEN, never the word: a definition naming /ponytail-review as a
# review lens is asking for MORE ponytail, not waiving the carve-outs.
has "definition carrying the token opts out"     no  "$(acm th "$PT_M" ponytailagent 'Do X.')" 'PONYTAIL_GUARDRAILS —'
has "mentioning /ponytail-review does not"       yes "$(acm th "$PT_M" reviewmention 'Review X.')" 'PONYTAIL_GUARDRAILS'
# Language and compression are unaffected by any of it.
out=$(acm th "$PT_M" developer 'Build X.')
has "carve-outs coexist with language"           yes "$out" 'OUTPUT LANGUAGE = th'
has "original brief still intact"                yes "$out" 'Build X.'

echo "--- pretool-submodule-guard ---"
#
# Fixture: a real superproject with a real submodule mount, built in the temp dir so
# the suite does not depend on which product repos this workspace happens to have
# cloned. `protocol.file.allow` is required because git refuses the file:// transport
# for submodules by default since 2.38.
mk_submodule() {
  local src="$TMP/subsrc" sup="$TMP/super"
  mkdir -p "$src/changelog"
  git -C "$src" init -q
  : > "$src/changelog/main.yml"
  git -C "$src" add -A >/dev/null 2>&1
  git -C "$src" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
  mkdir -p "$sup/src"
  git -C "$sup" init -q
  : > "$sup/src/main.rs"
  git -C "$sup" add -A >/dev/null 2>&1
  git -C "$sup" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
  git -C "$sup" -c protocol.file.allow=always -c user.email=t@t -c user.name=t \
      submodule add -q "$src" sub >/dev/null 2>&1
}
mk_submodule
SUB="$TMP/super/sub"

# The guard's ALLOW verdict is exit 0 WITH a permissionDecision on stdout, which the
# exit-code-only `t` cannot tell apart from "no opinion" — and the difference is the
# whole point of the guard, so it needs its own assert.
ta() { # ta <name> <allow|silent> <json>
  local name=$1 want=$2 json=$3 out got
  out=$(printf '%s' "$json" | "$H/pretool-submodule-guard.sh" 2>/dev/null)
  case "$out" in *'"permissionDecision":"allow"'*) got=allow ;; *) got=silent ;; esac
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s (want %s, got %s)\n' "$name" "$want" "$got"; fi
}

G=pretool-submodule-guard.sh

# --- the rule: creating / editing / committing inside the checkout is blocked -----
t  "submodule commit blocked"        2 $G "$(j "git -C $SUB commit -m x")"
t  "submodule add blocked"           2 $G "$(j "git -C $SUB add .")"
t  "submodule push blocked"          2 $G "$(j "git -C $SUB push origin HEAD")"
t  "submodule checkout -b blocked"   2 $G "$(j "git -C $SUB checkout -b feature/x")"
t  "submodule switch -c blocked"     2 $G "$(j "git -C $SUB switch -c feature/x")"
t  "submodule restore blocked"       2 $G "$(j "git -C $SUB restore changelog/main.yml")"
t  "submodule stash push blocked"    2 $G "$(j "git -C $SUB stash push")"
t  "Write into submodule blocked"    2 $G "$(jw "$SUB/changelog/main.yml")"
t  "Edit into submodule blocked"     2 $G "$(jq -cn --arg p "$SUB/changelog/main.yml" '{tool_name:"Edit",tool_input:{file_path:$p}}')"
t  "sed -i into submodule blocked"   2 $G "$(j "sed -i '' s/a/b/ $SUB/changelog/main.yml")"
t  "cp into submodule blocked"       2 $G "$(j "cp /tmp/x.yml $SUB/changelog/x.yml")"
t  "rm inside submodule blocked"     2 $G "$(j "rm $SUB/changelog/main.yml")"
t  "redirect into submodule blocked" 2 $G "$(j "echo hi > $SUB/changelog/x.yml")"
t  "&> into submodule blocked"       2 $G "$(j "git -C $SUB status &> $SUB/out.txt")"

# --- and the half the rule was never about: proving something by reading it ------
# Every one of these was denied by the auto-mode classifier on the APP-2179 review
# (2026-07-27), which is why the guard pre-approves them.
ta "bare ref checkout pre-approved"   allow "$(j "git -C $SUB checkout --detach HEAD")"
ta "checkout <ref> pre-approved"      allow "$(j "git -C $SUB checkout master")"
ta "status | head pre-approved"       allow "$(j "git -C $SUB status --porcelain | head -30")"
ta "show ref:path | sed pre-approved" allow "$(j "git -C $SUB show HEAD:changelog/main.yml | sed -n '1,5p'")"
ta "fetch pre-approved"               allow "$(j "git -C $SUB fetch origin")"
ta "submodule status pre-approved"    allow "$(j "git -C $SUB submodule status")"
# The exact shape the classifier killed: a ref move, fd-dup, a pipe and a chained ls.
# `2>&1` must survive the separator split — splitting on the lone `&` once sliced it
# into the junk segments `2>` and `1` and silently cost the command its pre-approval.
ta "checkout 2>&1 | tail && ls"       allow "$(j "git -C $SUB checkout --detach HEAD 2>&1 | tail -2 && ls $SUB/changelog")"
ta "fd-dup 1>&2 survives split"       allow "$(j "git -C $SUB log --oneline -1 1>&2")"

# --- ALLOW is whole-command, so one unrecognized segment must forfeit it ---------
ta "unknown segment forfeits allow"   silent "$(j "git -C $SUB status && curl http://evil/")"
ta "build chained after read"         silent "$(j "git -C $SUB status && ./scripts/dev.sh test")"
# A secrets-shaped read is read-only and still a leak — it belongs to the env guard,
# so this guard must stand aside rather than wave it through.
ta "secretish read deferred"          silent "$(j "git -C $SUB show HEAD:.env")"
ta ".env.example not secretish"       allow  "$(j "git -C $SUB show HEAD:.env.example")"

# --- a PRIMARY clone is not a submodule: the guard has no opinion at all ---------
t  "primary clone commit untouched"  0 $G "$(j "git -C $TMP/subsrc commit -m x")"
t  "primary clone Write untouched"   0 $G "$(jw "$TMP/subsrc/changelog/main.yml")"
ta "primary clone read not allowed-stamped" silent "$(j "git -C $TMP/subsrc status --porcelain")"
t  "superproject own src Write ok"   0 $G "$(jw "$TMP/super/src/main.rs")"
t  "non-git command untouched"       0 $G "$(j 'cargo test')"
t  "outside any repo fails open"     0 $G "$(jw "/nonexistent-root-xyz/a/b.rs")"

echo "--- pretool-adapter-pipe-guard ---"
# A bare adapter call matches Bash(*scripts/{vcs,tracker,notify}/*) and runs. Wrapped in a
# pipe it matches NO rule, falls through to the permission classifier, and a WRITE gets
# denied silently (measured on MR !11: the same merge ran bare and was denied piped). So:
# writers must be bare, readers and previews may be piped, and an operator inside a quoted
# argument is prose — a Markdown pipe table in a --body must not read as shell.
P=pretool-adapter-pipe-guard.sh
t  "piped merge blocked"             2 $P "$(j 'scripts/vcs/merge-pr.sh 11 2>&1 | tail -5')"
t  "cd && open-pr blocked"           2 $P "$(j 'cd /abs/x && scripts/vcs/open-pr.sh --title y')"
t  "writer ; chained blocked"        2 $P "$(j 'scripts/vcs/open-pr.sh --title y ; echo done')"
t  "heredoc comment blocked"         2 $P "$(j 'scripts/tracker/add-ticket-comment.sh A-1 <<EOF')"
t  "command substitution blocked"    2 $P "$(j 'id=$(scripts/tracker/add-ticket-attachment.sh A-1 f.png)')"
t  "notify writer piped blocked"     2 $P "$(j 'scripts/notify/send.sh --channel c "hi" | cat')"
t  "bare merge allowed"              0 $P "$(j 'scripts/vcs/merge-pr.sh 11 --subject "x"')"
t  "bare writer, stdin allowed"      0 $P "$(j 'scripts/tracker/add-ticket-comment.sh A-1 < report.md')"
t  "bare writer, redirect allowed"   0 $P "$(j 'scripts/vcs/open-pr.sh --title y > out.txt')"
t  "piped --dry-run allowed"         0 $P "$(j 'scripts/vcs/merge-pr.sh 11 --dry-run 2>&1 | tail -3')"
t  "piped READER allowed"            0 $P "$(j 'scripts/vcs/pr-view.sh 11 | head -3')"
# The comment UPSERT is a writer like any other: it is the one that rewrites a test-report
# comment in place, so a silently-denied compound call would look like "the report vanished".
# Its READER half (find-ticket-comment.sh) must stay pipeable — that is how a caller reads the
# previous run's body before composing the next one.
t  "bare upsert comment allowed"      0 $P "$(j 'scripts/tracker/upsert-ticket-comment.sh A-1 --marker "[test-report - x]" < report.md')"
t  "piped upsert comment blocked"     2 $P "$(j 'scripts/tracker/upsert-ticket-comment.sh A-1 --marker "[test-report - x]" | cat')"
t  "piped comment finder allowed"     0 $P "$(j 'scripts/tracker/find-ticket-comment.sh A-1 --marker "[test-report - x]" | head -1')"
t  "pipe table in a body allowed"    0 $P "$(j 'scripts/tracker/add-ticket-comment.sh A-1 "| a | b |"')"
t  "&& inside a body allowed"        0 $P "$(j 'scripts/tracker/add-ticket-comment.sh A-1 "run x && y"')"
t  "unrelated piped cmd allowed"     0 $P "$(j 'git log --oneline | head -5')"
# A HEREDOC BODY IS PROSE. A commit message or PR body that NAMES an adapter is not a
# call to it — an earlier version of this guard blocked its own commit for saying
# "scripts/vcs/merge-pr.sh" in the message. The heredoc's own command line still counts, so a real
# writer fed by a heredoc is still caught (see "heredoc comment blocked" above).
t  "commit msg naming a writer ok"   0 $P "$(printf '%s' "$(jq -cn --arg c 'git commit -F - <<EOF
fix: explain why scripts/vcs/merge-pr.sh must run bare
EOF' '{tool_name:"Bash",tool_input:{command:$c}}')")"
t  "PR body naming a writer ok"      0 $P "$(printf '%s' "$(jq -cn --arg c 'cat <<EOF > body.md
Run scripts/vcs/merge-pr.sh bare, never piped.
EOF' '{tool_name:"Bash",tool_input:{command:$c}}')")"
# NAMING A WRITER IS NOT CALLING IT. In operand position the path is data — reading the
# script with another tool is a maintenance read, not an invocation. Only the FIRST token of
# a shell segment counts, so these must pass while every real call above still blocks.
t  "grep ON a writer allowed"        0 $P "$(j 'grep -n body-file scripts/vcs/open-pr.sh | head')"
t  "wc ON a writer allowed"          0 $P "$(j 'wc -l scripts/notify/send.sh && echo ok')"
t  "reader piped, writer named ok"   0 $P "$(j 'scripts/vcs/pr-view.sh 11 | grep merge-pr.sh')"
t  "diff of two writers allowed"     0 $P "$(j 'diff scripts/tracker/delete-ticket.sh scripts/tracker/delete-ticket-comment.sh | head')"
# …and command position survives the things that legitimately precede a command.
t  "./ prefixed writer blocked"      2 $P "$(j './scripts/vcs/merge-pr.sh 11 | tail')"
t  "bash-wrapped writer blocked"     2 $P "$(j 'bash scripts/vcs/merge-pr.sh 11 | tail')"
t  "env-assigned writer blocked"     2 $P "$(j 'VCS_PROVIDER=gitlab scripts/vcs/merge-pr.sh 11 | tail')"
t  "writer inside a for-do blocked"  2 $P "$(j 'for f in a b; do scripts/notify/send.sh --channel c $f; done')"
t  "writer in a subshell blocked"    2 $P "$(j '(scripts/vcs/close-pr.sh 11) | tee log')"
# A MULTI-LINE BODY IS STILL PROSE. The quote strip used to run per line, so a --body whose
# opening and closing quotes sit on different lines was never stripped at all: every Markdown
# pipe and every English semicolon inside it read as shell syntax. Three real open-pr.sh calls
# were blocked that way (aiworks#85) before a quote-state scanner replaced the regex pair. The
# second case is the one that keeps the fix honest — a genuine pipe after such a body must
# still block, or the fix would be a bypass rather than a repair.
MB='scripts/vcs/open-pr.sh --title "t" --body "intro line

| half | shape |
| ---- | ----- |

It has been there since that file'"'"'s first commit; the override stays."'
t  "multi-line body allowed"         0 $P "$(j "$MB")"
t  "multi-line body then pipe blocked" 2 $P "$(j "$MB | tail -3")"
# Apostrophes in prose are not shell quoting. The old strip removed single-quoted spans FIRST,
# so two of them paired across the real double quote — it happened to still allow this one,
# which is exactly why it is pinned: the verdict must come from quote state, not from luck.
t  "apostrophes around a pipe ok"    0 $P "$(j 'scripts/notify/send.sh --channel c "it'"'"'s a | b table, and that file'"'"'s too"')"
# A command substitution is compound wherever it starts, not only at character 0 — the
# backtick arm of the case was the one written without its leading `*`.
t  "backtick writer mid-cmd blocked" 2 $P "$(j 'echo `scripts/vcs/merge-pr.sh 11`')"

echo "--- pretool-adapter-edit-guard ---"
# A hermetic copy of the layout `aiworks add` §3.3 creates: real adapters at the workspace
# root, a symlink into each repo. A fresh clone has no product repos, so testing against the
# live workspace would pass by ABSENCE — the fixture is what keeps this suite honest.
mkdir -p "$TMP/ws/scripts/vcs" "$TMP/ws/scripts/tracker" "$TMP/ws/repo/scripts" "$TMP/ws/repo/src"
: > "$TMP/ws/workspace.config.yaml"; : > "$TMP/ws/scripts/vcs/gitlab.sh"; : > "$TMP/ws/scripts/tracker/jira.sh"
ln -sf ../../scripts/vcs     "$TMP/ws/repo/scripts/vcs"
ln -sf ../../scripts/tracker "$TMP/ws/repo/scripts/tracker"
tae() { # tae <name> <expected-exit> <file_path>
  local name=$1 want=$2 p=$3 got
  got=$(jq -cn --arg p "$p" '{tool_name:"Write",tool_input:{file_path:$p}}' \
        | CLAUDE_PROJECT_DIR="$TMP/ws" "$H/pretool-adapter-edit-guard.sh" >/dev/null 2>&1; echo $?)
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s (want exit %s, got %s)\n' "$name" "$want" "$got"; fi
}
tae "vcs via repo symlink blocked"     2 "$TMP/ws/repo/scripts/vcs/gitlab.sh"
tae "tracker via repo symlink blocked" 2 "$TMP/ws/repo/scripts/tracker/jira.sh"
tae "root adapter allowed"             0 "$TMP/ws/scripts/vcs/gitlab.sh"
tae "root tracker allowed"             0 "$TMP/ws/scripts/tracker/jira.sh"
tae "repo's own scripts/dev.sh ok"     0 "$TMP/ws/repo/scripts/dev.sh"
tae "ordinary repo source ok"          0 "$TMP/ws/repo/src/main.rs"
tae "missing dir fails open"           0 "$TMP/ws/nope/scripts/vcs/x.sh"

echo "--- pretool-orchestrator-guard ---"
# A dedicated fixture: a product repo "svc" (git checkout), the run-state dir, a marker,
# plus .claude/ and a root-level run summary — so the allow/deny boundary is exercised
# against a realistic layout rather than the bare TMP dir the earlier sections share.
mkdir -p "$TMP/og/svc/src" "$TMP/og/agent_logs/FM-1-dev-cycle-state" "$TMP/og/.claude" "$TMP/og/scripts"
git -C "$TMP/og/svc" init -q
: > "$TMP/og/svc/src/main.rs"
: > "$TMP/og/agent_logs/FM-1-DEV-CYCLE-SUMMARY.md"
og_marker() { # og_marker <armed:true|false>
  printf '{"session_id":"sess-1","ticket":"FM-1","armed":%s,"run_state":"x","recorded_at":"2026-01-01T00:00:00Z"}' "$1" \
    > "$TMP/og/agent_logs/FM-1-dev-cycle-state/orchestrator-guard.json"
}
# tog <name> <want> <armed:true|false> <child:1|unset> <transcript> <json-from-j/jw/jr>
tog() {
  local name=$1 want=$2 armed=$3 child=$4 transcript=$5 json=$6 got
  og_marker "$armed"
  json=$(printf '%s' "$json" | jq -c --arg t "$transcript" --arg s sess-1 --arg d "$TMP/og" \
    '. + {transcript_path:$t, session_id:$s, cwd:$d}')
  if [ "$child" = "1" ]; then
    got=$(printf '%s' "$json" | CLAUDE_PROJECT_DIR="$TMP/og" CLAUDE_CODE_CHILD_SESSION=1 "$H/pretool-orchestrator-guard.sh" >/dev/null 2>&1; echo $?)
  else
    got=$(printf '%s' "$json" | env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_PROJECT_DIR="$TMP/og" "$H/pretool-orchestrator-guard.sh" >/dev/null 2>&1; echo $?)
  fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s (want exit %s, got %s)\n' "$name" "$want" "$got"; fi
}
MAIN_TS="$TMP/og/main.jsonl"
SUB_TS="$TMP/og/main/subagents/agent-3.jsonl"
WF_SUB_TS="$TMP/og/main/subagents/workflows/wf_x/agent-1.jsonl"

tog "armed + main, Edit inside product repo -> deny"      2 true  ""  "$MAIN_TS" "$(jw "$TMP/og/svc/src/main.rs")"
tog "armed + main, Write a run-state row -> deny"          2 true  ""  "$MAIN_TS" "$(jw "$TMP/og/agent_logs/FM-1-dev-cycle-state/svc-built.json")"
tog "armed + main, git commit inside product repo -> deny" 2 true  ""  "$MAIN_TS" "$(j "git -C $TMP/og/svc commit -m x")"
tog "armed + main, git merge inside product repo -> allow (sanctioned ship verb; user ! input fires hooks main-shaped)" 0 true "" "$MAIN_TS" "$(j "git -C $TMP/og/svc merge --ff-only feature/FM-1")"
tog "armed + main, git push inside product repo -> allow (sanctioned ship verb)" 0 true "" "$MAIN_TS" "$(j "git -C $TMP/og/svc push origin develop")"
tog "armed + main, git log inside product repo -> allow"   0 true  ""  "$MAIN_TS" "$(j "git -C $TMP/og/svc log --oneline")"
tog "armed + main, git status inside product repo -> allow" 0 true ""  "$MAIN_TS" "$(j "git -C $TMP/og/svc status")"
tog "armed + child=1 env + main-shaped payload -> deny (child=1 is ALWAYS set in hook env — probe-measured, no longer an allow)" 2 true "1" "$MAIN_TS" "$(jw "$TMP/og/svc/src/main.rs")"
tog "armed + child=1 env + agent_id present -> allow (subagents pass in the real always-child env)" 0 true "1" "$MAIN_TS" "$(jq -cn --arg p "$TMP/og/svc/src/main.rs" --arg a x '{tool_name:"Edit",tool_input:{file_path:$p},agent_id:$a}')"
tog "armed + subagent transcript, same Edit -> allow"      0 true  ""  "$SUB_TS"  "$(jw "$TMP/og/svc/src/main.rs")"
tog "armed + neither signal (empty transcript_path) -> allow (fails open)" 0 true "" "" "$(jw "$TMP/og/svc/src/main.rs")"
tog "marker armed:false, main, same Edit -> allow"         0 false ""  "$MAIN_TS" "$(jw "$TMP/og/svc/src/main.rs")"
tog "armed + main, Write .claude/settings.json -> allow"   0 true  ""  "$MAIN_TS" "$(jw "$TMP/og/.claude/settings.json")"
tog "armed + main, Write root run summary -> allow"        0 true  ""  "$MAIN_TS" "$(jw "$TMP/og/agent_logs/FM-1-DEV-CYCLE-SUMMARY.md")"
tog "armed + main, Write outside the workspace root -> allow" 0 true "" "$MAIN_TS" "$(jw "/tmp/scratch-notes.md")"

# session mismatch: marker says sess-1, payload says a different session.
og_marker true
got=$(printf '%s' "$(jw "$TMP/og/svc/src/main.rs")" \
      | jq -c --arg t "$MAIN_TS" --arg d "$TMP/og" '. + {transcript_path:$t, session_id:"other-session", cwd:$d}' \
      | env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_PROJECT_DIR="$TMP/og" "$H/pretool-orchestrator-guard.sh" >/dev/null 2>&1; echo $?)
if [ "$got" = "0" ]; then pass=$((pass+1)); printf 'ok   %s\n' "session mismatch -> allow"
else fail=$((fail+1)); printf 'FAIL %s (want exit 0, got %s)\n' "session mismatch -> allow" "$got"; fi

# no marker anywhere.
rm -f "$TMP/og/agent_logs/FM-1-dev-cycle-state/orchestrator-guard.json"
got=$(printf '%s' "$(jw "$TMP/og/svc/src/main.rs")" \
      | jq -c --arg t "$MAIN_TS" --arg d "$TMP/og" '. + {transcript_path:$t, session_id:"sess-1", cwd:$d}' \
      | env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_PROJECT_DIR="$TMP/og" "$H/pretool-orchestrator-guard.sh" >/dev/null 2>&1; echo $?)
if [ "$got" = "0" ]; then pass=$((pass+1)); printf 'ok   %s\n' "no marker anywhere -> allow"
else fail=$((fail+1)); printf 'FAIL %s (want exit 0, got %s)\n' "no marker anywhere -> allow" "$got"; fi

# marker present but unparseable JSON.
printf 'not json' > "$TMP/og/agent_logs/FM-1-dev-cycle-state/orchestrator-guard.json"
got=$(printf '%s' "$(jw "$TMP/og/svc/src/main.rs")" \
      | jq -c --arg t "$MAIN_TS" --arg d "$TMP/og" '. + {transcript_path:$t, session_id:"sess-1", cwd:$d}' \
      | env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_PROJECT_DIR="$TMP/og" "$H/pretool-orchestrator-guard.sh" >/dev/null 2>&1; echo $?)
if [ "$got" = "0" ]; then pass=$((pass+1)); printf 'ok   %s\n' "marker unparseable JSON -> allow"
else fail=$((fail+1)); printf 'FAIL %s (want exit 0, got %s)\n' "marker unparseable JSON -> allow" "$got"; fi

# The three C6-discriminator cases the orchestrator asked for explicitly.
tog "discriminator: payload with agent_id -> allow"                       0 true "" "$MAIN_TS" "$(jq -cn --arg p "$TMP/og/svc/src/main.rs" --arg a x '{tool_name:"Edit",tool_input:{file_path:$p},agent_id:$a}')"
tog "discriminator: transcript_path under subagents/workflows/.. -> allow" 0 true "" "$WF_SUB_TS" "$(jw "$TMP/og/svc/src/main.rs")"
tog "discriminator: armed marker + main-shaped payload -> deny"           2 true "" "$MAIN_TS" "$(jw "$TMP/og/svc/src/main.rs")"

echo "--- pretool-bash-context-guard ---"
# Fixtures sized either side of the 8 KiB default. The guard STATS the real path, so the
# assertions are about file size, not about the wording of the command.
mkdir -p "$TMP/ctx"
BIG="$TMP/ctx/big.md";   awk 'BEGIN{for(i=0;i<400;i++) printf "%040d line of filler text here\n", i}' > "$BIG"
SMALL="$TMP/ctx/small.md"; printf 'two lines\nonly\n' > "$SMALL"
# cwd matters: the guard resolves a relative operand against it, exactly as the real payload does.
jctx() { jq -cn --arg c "$1" --arg d "$TMP/ctx" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
# A read-modify-write heredoc padded past the 2000-byte floor, since the floor is the point:
# a small patch is cheaper than the round trip and is deliberately allowed.
PAD=$(awk 'BEGIN{for(i=0;i<70;i++) printf "# padding so the payload clears the guard floor %02d\n", i}')
RMW="python3 - <<'PY'
$PAD
p = 'target.md'
s = open(p).read()
open(p, 'w').write(s.replace('a', 'b'))
PY"
GENONLY="python3 - <<'PY'
$PAD
rows = [str(i) for i in range(50)]
open('/tmp/generated.txt', 'w').write('\n'.join(rows))
PY"

t "cat of an 8KB+ file blocked"          2 pretool-bash-context-guard.sh "$(jctx "cat $BIG")"
t "cat relative to cwd blocked"          2 pretool-bash-context-guard.sh "$(jctx 'cat big.md')"
t "nl of a big file blocked"             2 pretool-bash-context-guard.sh "$(jctx "nl $BIG")"
t "big file after && blocked"            2 pretool-bash-context-guard.sh "$(jctx "cd /tmp && cat $BIG")"
t "cat of a small file allowed"          0 pretool-bash-context-guard.sh "$(jctx "cat $SMALL")"
# The bounded forms are the ones the guard's own message recommends — blocking them would push
# the agent straight back to the unbounded read.
t "big | head allowed"                   0 pretool-bash-context-guard.sh "$(jctx "cat $BIG | head -20")"
t "big | grep allowed"                   0 pretool-bash-context-guard.sh "$(jctx "cat $BIG | grep -n line")"
t "big redirected to a file allowed"     0 pretool-bash-context-guard.sh "$(jctx "cat $BIG > /tmp/out.txt")"
t "sed region of a big file allowed"     0 pretool-bash-context-guard.sh "$(jctx "sed -n '10,40p' $BIG")"
t "grep on a big file allowed"           0 pretool-bash-context-guard.sh "$(jctx "grep -n line $BIG")"
t "hcat left to its own guard"           0 pretool-bash-context-guard.sh "$(jctx "hcat $BIG")"
t "missing file allowed"                 0 pretool-bash-context-guard.sh "$(jctx 'cat /nope/missing.md')"
# Prose-not-code, the lesson the pipe guard learned the hard way: naming a reader is not calling
# one. Both of these used to be the guard's own false positives.
t "reader in OPERAND position allowed"   0 pretool-bash-context-guard.sh "$(jctx "grep -n cat $BIG")"
t "reader named inside a heredoc allowed" 0 pretool-bash-context-guard.sh "$(jctx "git commit -F - <<EOF
stop running cat $BIG so often
EOF")"
# The override has to be parsed OUT OF THE COMMAND: a hook cannot see `VAR=x <cmd>` in its own
# env, so reading it from the environment made the documented escape hatch a no-op.
t "inline BASH_READ_MAX_BYTES honoured"  0 pretool-bash-context-guard.sh "$(jctx "BASH_READ_MAX_BYTES=9999999 cat $BIG")"

t "read-modify-write heredoc blocked"    2 pretool-bash-context-guard.sh "$(jctx "$RMW")"
t "write-only heredoc allowed"           0 pretool-bash-context-guard.sh "$(jctx "$GENONLY")"
t "small patch under the floor allowed"  0 pretool-bash-context-guard.sh "$(jctx "python3 - <<'PY'
s=open('f').read(); open('f','w').write(s+'x')
PY")"
t "inline BASH_PATCH_GUARD=0 honoured"   0 pretool-bash-context-guard.sh "$(jctx "BASH_PATCH_GUARD=0 $RMW")"
t "plain git commit heredoc allowed"     0 pretool-bash-context-guard.sh "$(jctx "git commit -F - <<'EOF'
$PAD
feat: a long commit message is not a patch
EOF")"

# ── Rule 3, the poll loop. STATEFUL, unlike rules 1 and 2: the verdict depends on what this
# same caller already ran. So the ledger gets its own TMPDIR (fresh, never the developer's),
# and each case gets its own transcript_path so cases cannot contaminate each other.
POLLTMP="$TMP/pollstate"; mkdir -p "$POLLTMP"
export TMPDIR="$POLLTMP"
LOG="$TMP/ctx/run.log"; printf 'test one ... ok\n' > "$LOG"
jpoll() { jq -cn --arg c "$1" --arg d "$TMP/ctx" --arg t "$2" \
  '{tool_name:"Bash",cwd:$d,transcript_path:$t,tool_input:{command:$c}}'; }

# The measured shape: one probe, unchanged, over and over. Six get through, the seventh does not.
for i in 1 2 3 4 5 6; do
  t "poll $i of 6 allowed"               0 pretool-bash-context-guard.sh "$(jpoll "grep -c ' ok$' $LOG" /t/spin)"
done
t "the 7th identical probe blocked"      2 pretool-bash-context-guard.sh "$(jpoll "grep -c ' ok$' $LOG" /t/spin)"
# ...and a DIFFERENT question about the same file is a different probe. This is the whole reason
# the key is the command and not the path: an investigation greps one log many ways.
t "different pattern, same file, allowed" 0 pretool-bash-context-guard.sh "$(jpoll "grep -c FAILED $LOG" /t/spin)"

# A second agent in the same workflow wave must start from zero. Keyed on session_id alone this
# failed: parallel subagents can share one, and agent B's first call would inherit agent A's count.
t "a parallel agent is not charged for it" 0 pretool-bash-context-guard.sh "$(jpoll "grep -c ' ok$' $LOG" /t/other)"

# Only READ-ONLY probes of an EXISTING file count. Repeating work is not waiting for work.
for i in 1 2 3 4 5 6 7; do
  t "non-probe verb x$i not counted"     0 pretool-bash-context-guard.sh "$(jpoll "git log --oneline -1 $LOG" /t/verb)"
done
for i in 1 2 3 4 5 6 7; do
  t "probe of a missing file x$i allowed" 0 pretool-bash-context-guard.sh "$(jpoll "grep -c x /nope/absent.log" /t/gone)"
done

# THE REMEDY MUST NEVER TRIP ITS OWN GUARD. The block message tells the agent to wait inside a
# single backgrounded `until` loop — whose body is a grep of exactly the file it was polling.
for i in 1 2 3 4 5 6 7; do
  t "the until-loop remedy x$i allowed"  0 pretool-bash-context-guard.sh \
    "$(jpoll "until grep -q 'test result:' $LOG; do sleep 5; done" /t/fix)"
done

# Same escape-hatch contract as rules 1 and 2: parsed out of the command, not the environment.
for i in 1 2 3 4 5 6 7; do
  t "inline BASH_POLL_GUARD=0 honoured $i" 0 pretool-bash-context-guard.sh \
    "$(jpoll "BASH_POLL_GUARD=0 grep -c ' ok$' $LOG" /t/off)"
done
for i in 1 2 3 4 5 6 7; do
  t "inline BASH_POLL_MAX raise honoured $i" 0 pretool-bash-context-guard.sh \
    "$(jpoll "BASH_POLL_MAX=99 grep -c ' ok$' $LOG" /t/raised)"
done
unset TMPDIR

echo "--- pretool-steer-build: a suite run goes through scripts/dev.sh ---"
# The rule this pins is not "less output" but "there is a RECEIPT". dev.sh writes
# agent_logs/executed_verbose/<cmd>-<ts>.log and that is what `status`/`why` — and the
# test-suite gate — read back; a raw run leaves nothing, and a gate that reads nothing
# records NOT RUN (docs/agents/loadtest-gate.md). So the block cases below are the gate's
# integrity, and the allow cases are what keeps the guard from being switched off.
#
# A subagent payload is asserted alongside the main-session one for every shape, because
# the subagent is the party that actually runs the suites. The guard reads no
# discriminator, so the pair must agree — a regression that exempted subagents would
# leave the loudest caller unguarded while this suite still read green.
jsub() { jq -cn --arg c "$1" \
  '{tool_name:"Bash",agent_id:"agent-selftest",tool_input:{command:$c}}'; }

# BLOCKED — the receipt-bearing suite runs, raw.
t "raw cargo test blocked"            2 pretool-steer-build.sh "$(j 'cargo test')"
t "raw cargo test --workspace blocked" 2 pretool-steer-build.sh "$(j 'cargo test --workspace --all-features')"
t "cargo test after cd blocked"       2 pretool-steer-build.sh "$(j 'cd svc && cargo test')"
t "raw npm test blocked"              2 pretool-steer-build.sh "$(j 'npm test')"
t "raw pnpm run test:e2e blocked"     2 pretool-steer-build.sh "$(j 'pnpm run test:e2e')"
t "raw yarn test blocked"             2 pretool-steer-build.sh "$(j 'yarn test --ci')"
t "raw npx cypress run blocked"       2 pretool-steer-build.sh "$(j 'npx cypress run --spec cypress/e2e/login.cy.ts')"
t "raw newman run blocked"            2 pretool-steer-build.sh "$(j 'newman run postman/collection.json')"
t "raw k6 run blocked"                2 pretool-steer-build.sh "$(j 'k6 run scenarios/bet.js')"
t "raw flutter test still blocked"    2 pretool-steer-build.sh "$(j 'flutter test')"

# The same verbs from a SUBAGENT. Same verdict, or the rule has a hole where it matters.
t "subagent cargo test blocked"       2 pretool-steer-build.sh "$(jsub 'cargo test')"
t "subagent npm test blocked"         2 pretool-steer-build.sh "$(jsub 'npm test')"
t "subagent cypress run blocked"      2 pretool-steer-build.sh "$(jsub 'npx cypress run')"
t "subagent k6 run blocked"           2 pretool-steer-build.sh "$(jsub 'k6 run scenarios/bet.js')"

# ALLOWED — the wrapper, and a deliberate capture to a file.
t "dev.sh test allowed"               0 pretool-steer-build.sh "$(j 'scripts/dev.sh test')"
t "dev.sh test allowed (subagent)"    0 pretool-steer-build.sh "$(jsub 'scripts/dev.sh test')"
t "cargo test redirected allowed"     0 pretool-steer-build.sh "$(j 'cargo test > /tmp/out.log 2>&1')"
t "2>&1 alone is not a redirect"      2 pretool-steer-build.sh "$(j 'cargo test 2>&1')"

# ALLOWED — fast verbs no gate reads a receipt for. These are 30 of the 70 raw calls in
# the measured corpus; blocking them would buy nothing and cost the guard its welcome.
t "cargo check allowed"               0 pretool-steer-build.sh "$(j 'cargo check')"
t "cargo fmt allowed"                 0 pretool-steer-build.sh "$(j 'cargo fmt --all -- --check')"
t "cargo clippy allowed"              0 pretool-steer-build.sh "$(j 'cargo clippy --all-targets')"
t "cargo build allowed"               0 pretool-steer-build.sh "$(j 'cargo build --release')"
t "npm ci allowed"                    0 pretool-steer-build.sh "$(j 'npm ci')"
t "pnpm install allowed"              0 pretool-steer-build.sh "$(j 'pnpm install --frozen-lockfile')"
t "pnpm run lint allowed"             0 pretool-steer-build.sh "$(j 'pnpm run lint')"
t "npm run storybook allowed"         0 pretool-steer-build.sh "$(j 'npm run storybook')"
t "k6 archive allowed"                0 pretool-steer-build.sh "$(j 'k6 archive scenarios/bet.js')"

# The verb must be a WORD. A substring match here would block half the workspace's tooling.
t "mycargo test is not cargo test"    0 pretool-steer-build.sh "$(j 'echo mycargo test')"
t "npmtest is not npm test"           0 pretool-steer-build.sh "$(j './npmtest')"

echo "--- pretool-cd-guard ---"
# Only the LEADING cd is judged. Everything below is the hook's own documented contract,
# turned into cases so the contract and the code cannot drift apart silently.
t "cd relative blocked"               2 pretool-cd-guard.sh "$(j 'cd your-app')"
t "cd ./x blocked"                    2 pretool-cd-guard.sh "$(j 'cd ./scripts')"
t "cd ../x blocked"                   2 pretool-cd-guard.sh "$(j 'cd ../sibling && ls')"
t "cd foo/bar blocked"                2 pretool-cd-guard.sh "$(j 'cd db/scripts')"
t "cd quoted relative blocked"        2 pretool-cd-guard.sh "$(j 'cd "db/scripts"')"
t "leading whitespace still blocked"  2 pretool-cd-guard.sh "$(j '   cd db')"
t "subagent cd relative blocked"      2 pretool-cd-guard.sh "$(jsub 'cd db')"
t "cd absolute allowed"               0 pretool-cd-guard.sh "$(j 'cd /Users/x/ws/db && ls')"
t "cd ~ allowed"                      0 pretool-cd-guard.sh "$(j 'cd ~/projects')"
t "cd \$VAR allowed"                   0 pretool-cd-guard.sh "$(j 'cd "$CLAUDE_PROJECT_DIR/db"')"
t "cd \$HOME allowed"                  0 pretool-cd-guard.sh "$(j 'cd $HOME')"
t "cd - allowed"                      0 pretool-cd-guard.sh "$(j 'cd -')"
t "bare cd allowed"                   0 pretool-cd-guard.sh "$(j 'cd')"
# The two that decide whether this guard is usable at all. A mid-chain cd runs from a cwd
# established earlier in the SAME command, so it is deterministic; and `cd` must be a WORD,
# or every cdk/cdn command in the workspace dies.
t "mid-chain cd allowed"              0 pretool-cd-guard.sh "$(j 'cd /abs/repo && cd scripts && ./dev.sh test')"
t "cdk is not cd"                     0 pretool-cd-guard.sh "$(j 'cdk deploy --all')"
t "non-cd command allowed"            0 pretool-cd-guard.sh "$(j 'git -C /abs/repo status')"

echo "--- posttool-bash-portability ---"
# ADVISORY: this hook runs after the write and always exits 0, so an exit-code assertion
# would pass on a hook that had stopped detecting anything. Assert on the WARNING instead.
# macOS /bin/bash is 3.2.57 — every construct below is silent on the author's bash 5 and
# fatal on a stock Mac, which is exactly the failure `aiworks sync` once shipped.
PORT="$H/posttool-bash-portability.sh"
mkport() { printf '%s\n' "$2" > "$TMP/$1"; printf '%s' "$TMP/$1"; }
tp() { # tp <name> <want: warn|clean> <file>
  local name=$1 want=$2 f=$3 err
  err="$(jq -cn --arg p "$f" '{tool_name:"Write",tool_input:{file_path:$p}}' \
         | "$PORT" 2>&1 >/dev/null)"
  case "$want:$(printf '%s' "$err" | grep -c 'bash 4+ syntax')" in
    warn:0)  fail=$((fail+1)); printf 'FAIL %s (expected a warning, got none)\n' "$name" ;;
    clean:0) pass=$((pass+1)); printf 'ok   %s\n' "$name" ;;
    warn:*)  pass=$((pass+1)); printf 'ok   %s\n' "$name" ;;
    clean:*) fail=$((fail+1)); printf 'FAIL %s (warned on a 3.2-clean file)\n' "$name" ;;
  esac
}
# These fixtures have to CONTAIN the banned constructs, and `--scan` — asserted green a few
# lines below — reads THIS file like any other tracked script. Exempting the suite would be
# the easy way out and would blind the scan to real bash-4 syntax written here later, so
# each construct is assembled from parts instead: the fixture on disk is byte-exact, the
# literal never appears in this source. Test NAMES avoid the literals for the same reason.
SH='#!/usr/bin/env bash'
AA='A'; LC=',,'; GS='globstar'; MF='map''file'
tp "assoc array flagged"  warn  "$(mkport a.sh "$SH
local -${AA} repo_owner=()")"
tp "${MF} flagged"        warn  "$(mkport b.sh "$SH
${MF} -t rows < in.txt")"
tp "lowercase expansion flagged" warn "$(mkport c.sh "$SH
echo \"\${name${LC}}\"")"
tp "${GS} flagged"        warn  "$(mkport d.sh "$SH
shopt -s ${GS}")"
tp "clean script quiet"   clean "$(mkport e.sh "$SH
while IFS= read -r r; do echo \"\$r\"; done < in.txt")"
# The de-noising rule: this repo NAMES the banned constructs in prose all over the place.
# A checker that cried wolf on its own documentation would be turned off within a day.
tp "comment naming it quiet" clean "$(mkport f.sh "$SH
# never use local -${AA} here; ${MF} is banned too")"
# Extension gate: a .md that quotes the construct is documentation, not a script.
tp "non-shell file ignored" clean "$(mkport g.md "use \`local -${AA} x\` on bash 4")"
# No extension: the shebang is the only signal, so both directions are pinned.
tp "shebang file flagged" warn "$(mkport h "$SH
${MF} -t x < y")"
tp "no-shebang file ignored" clean "$(mkport i "${MF} -t x < y")"
# --scan is the CI entry point. It must pass on this repo AND say what it scanned: a scan
# that found nothing to scan must never read as a scan that passed.
scan="$(cd "$ROOT" && "$PORT" --scan 2>&1)"; scan_rc=$?
if [ "$scan_rc" = 0 ] && printf '%s' "$scan" | grep -q '3.2-clean'; then
  pass=$((pass+1)); printf 'ok   --scan is green on this repo (%s)\n' "$(printf '%s' "$scan" | grep -oE '[0-9]+ tracked')"
else
  fail=$((fail+1)); printf 'FAIL --scan rc=%s: %s\n' "$scan_rc" "$scan"
fi

echo "--- coverage: every wired dev-wrapper hook has cases ---"
# THE META-CHECK, and the reason this section exists at all. pretool-steer-build.sh sat
# wired in settings.json for months matching a stack no repo here uses — it ran on every
# Bash call and enforced nothing. Nothing caught it, because nothing asserted that a wired
# guard is a tested guard. This case is that assertion: wire a new dev-wrapper hook without
# writing cases for it and this suite goes red on the next run.
#
# Scope is deliberately THIS directory. voice/, stagehand/ and the MCP and Slack hooks are
# wired too and own their own suites; policing them from here would make this file the
# gate for subsystems it does not own.
> "$TMP/selftests.txt"
find "$ROOT/.claude/hooks" "$ROOT/scripts" -name '*selftest*' -type f -print > "$TMP/selftests.txt" 2>/dev/null
uncovered=""
while IFS= read -r wired; do
  [ -n "$wired" ] || continue
  base="$(basename "$wired")"
  # A hook is covered if any selftest in the repo names it — its own suite counts, so
  # pretool-repo-context.sh and pretool-codegraph-guard.sh pass on their dedicated files.
  # -print0/xargs is avoided on purpose: the file LIST is read line by line here, so a
  # checkout path with a space cannot silently split it into two non-existent paths and
  # turn a real gap into a green tick.
  hit=0
  while IFS= read -r stf; do
    [ -n "$stf" ] || continue
    grep -qF -- "$base" "$stf" 2>/dev/null && { hit=1; break; }
  done < "$TMP/selftests.txt"
  [ "$hit" = 1 ] || uncovered="${uncovered:+$uncovered }$base"
done <<COV
$(jq -r '.hooks // {} | to_entries[] | .value[] | .hooks[]? | .command // ""' "$ROOT/.claude/settings.json" 2>/dev/null \
   | grep -oE '[^"]*dev-wrapper/[A-Za-z0-9_-]+\.sh' | sort -u)
COV
if [ ! -s "$TMP/selftests.txt" ]; then
  # Never fail open. Finding no selftests at all means the search itself broke, not that
  # coverage is perfect — a check that could not run must not report as a check that passed.
  fail=$((fail+1)); printf 'FAIL coverage check found no selftest files to search\n'
elif [ -z "$uncovered" ]; then
  pass=$((pass+1)); printf 'ok   every wired dev-wrapper hook is named by a selftest\n'
else
  fail=$((fail+1)); printf 'FAIL wired dev-wrapper hook(s) with no selftest: %s\n' "$uncovered"
fi

echo "--- repo-health-check: say it once, then stop repeating it ---"
# Asserted as a PROPERTY, not against a fixed message, so the case is meaningful whether this
# worktree happens to be fully cloned or not: a second identical prompt must never cost MORE
# context than the first, and SessionStart must always carry the full guidance.
RH="$(cd "$H/.." && pwd)/repo-health-check.sh"
if [ -x "$RH" ]; then
  rhp() { jq -cn --arg e "$1" --arg s "$2" '{hook_event_name:$e,session_id:$s}'; }
  # Measure the MESSAGE, not the JSON envelope: "SessionStart" and "UserPromptSubmit" differ in
  # length, so comparing whole-payload bytes made SessionStart look abbreviated by 4 characters.
  rhlen() { printf '%s' "$(rhp "$1" "$2")" | "$RH" 2>/dev/null \
              | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null | wc -c | tr -d ' '; }
  SID="selftest-$$"
  first=$(rhlen UserPromptSubmit "$SID")
  second=$(rhlen UserPromptSubmit "$SID")
  ss=$(rhlen SessionStart "$SID")
  other=$(rhlen UserPromptSubmit "${SID}-b")
  if [ "${second:-0}" -le "${first:-0}" ]; then pass=$((pass+1)); printf 'ok   repeat prompt costs no more than the first\n'
  else fail=$((fail+1)); printf 'FAIL repeat prompt grew (%s -> %s bytes)\n' "$first" "$second"; fi
  if [ "${ss:-0}" -ge "${first:-0}" ]; then pass=$((pass+1)); printf 'ok   SessionStart always carries the full message\n'
  else fail=$((fail+1)); printf 'FAIL SessionStart was abbreviated (%s < %s)\n' "$ss" "$first"; fi
  if [ "${other:-0}" -ge "${second:-0}" ]; then pass=$((pass+1)); printf 'ok   a different session is not de-duplicated\n'
  else fail=$((fail+1)); printf 'FAIL cross-session leak (%s < %s)\n' "$other" "$second"; fi
  rm -f "${TMPDIR:-/tmp}"/aiworks-repo-health."$SID"* "${TMPDIR:-/tmp}"/aiworks-repo-health."$SID"-b* 2>/dev/null
else
  printf 'skip repo-health-check.sh not executable\n'
fi

# ── posttool-context-budget.sh ─────────────────────────────────────────────────────────
# The hook reads the window off the transcript, so the fixtures below ARE transcripts: one
# JSON line per usage row, exactly the shape Claude Code writes. Advisory like the
# portability checker — it always exits 0 — so every assertion is on the TEXT, never the
# exit code, or the suite would pass on a hook that had stopped measuring anything.
CTX="$H/posttool-context-budget.sh"
CTXCFG="$TMP/ctxcfg"; mkdir -p "$CTXCFG"

mkjsonl() { # mkjsonl <name> <read> <write> <input>  -> path
  local f="$TMP/tx-$1.jsonl"
  jq -cn --argjson r "$2" --argjson w "$3" --argjson i "$4" \
    '{type:"assistant",message:{usage:{cache_read_input_tokens:$r,cache_creation_input_tokens:$w,input_tokens:$i,output_tokens:10}}}' \
    > "$f"
  printf '%s' "$f"
}

tc() { # tc <name> <want: warn|alarm|quiet> <session-id> <transcript>
  local name=$1 want=$2 sid=$3 tx=$4 err
  err="$(jq -cn --arg t "$tx" --arg s "$sid" '{session_id:$s,transcript_path:$t,tool_name:"Bash"}' \
         | CLAUDE_CONFIG_DIR="$CTXCFG" "$CTX" 2>&1 >/dev/null)"
  local got=quiet
  printf '%s' "$err" | grep -q 'context window' && got=warn
  printf '%s' "$err" | grep -q 'every further turn bills' && got=alarm
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s (wanted %s, got %s)\n' "$name" "$want" "$got"
  fi
}

# --check renders the verdict without a transcript; the bands are the contract.
[ -z "$("$CTX" --check 149999)" ] \
  && { pass=$((pass+1)); printf 'ok   under the warn threshold says nothing\n'; } \
  || { fail=$((fail+1)); printf 'FAIL under the warn threshold should be silent\n'; }
"$CTX" --check 150000 | grep -q 'context window 150k' \
  && { pass=$((pass+1)); printf 'ok   warn band names the window\n'; } \
  || { fail=$((fail+1)); printf 'FAIL warn band did not name the window\n'; }
"$CTX" --check 299999 | grep -q 'every further turn bills' \
  && { fail=$((fail+1)); printf 'FAIL just under alarm escalated early\n'; } \
  || { pass=$((pass+1)); printf 'ok   just under alarm stays a warning\n'; }
"$CTX" --check 300000 | grep -q 'every further turn bills' \
  && { pass=$((pass+1)); printf 'ok   alarm band escalates\n'; } \
  || { fail=$((fail+1)); printf 'FAIL alarm band did not escalate\n'; }
"$CTX" --check 709000 | grep -q '709k' \
  && { pass=$((pass+1)); printf 'ok   alarm reports the measured size, not the threshold\n'; } \
  || { fail=$((fail+1)); printf 'FAIL alarm did not report the measured size\n'; }

# The window is the SUM of the three billed input fields, not cache_read alone: a turn that
# just wrote 90k of cache is as expensive as one that read it.
tc "small window is quiet"      quiet ctx-a "$(mkjsonl a  40000    0     0)"
tc "warn band fires"            warn  ctx-b "$(mkjsonl b 180000    0     0)"
tc "alarm band fires"           alarm ctx-c "$(mkjsonl c 620000    0     0)"
tc "cache write counts too"     warn  ctx-d "$(mkjsonl d  70000 90000     0)"
tc "uncached input counts too"  warn  ctx-e "$(mkjsonl e  70000     0 90000)"

# Regression: a cancelled or synthetic turn appends an all-zero usage row. Taking the
# literally-last row read 0 there and the hook went silent on a 620k session — which is
# exactly the session it exists to catch.
Z="$TMP/tx-zero.jsonl"
cat "$(mkjsonl z 620000 0 0)" > "$Z"
jq -cn '{type:"assistant",message:{usage:{cache_read_input_tokens:0,cache_creation_input_tokens:0,input_tokens:0,output_tokens:0}}}' >> "$Z"
tc "trailing zero row does not mask the window" alarm ctx-f "$Z"

# Throttle: one line per 50k bucket per session, or a long session buries the warning under
# its own repetitions. Same session + same window must go quiet the second time.
tc "first crossing warns"          warn  ctx-g "$(mkjsonl g 180000 0 0)"
tc "same bucket is throttled"      quiet ctx-g "$(mkjsonl g 180000 0 0)"
tc "a new bucket warns again"      warn  ctx-g "$(mkjsonl g 260000 0 0)"
tc "a different session is not throttled" warn ctx-h "$(mkjsonl h 180000 0 0)"

# Never break the tool call it rides on, whatever it is handed.
printf 'not json\n' | CLAUDE_CONFIG_DIR="$CTXCFG" "$CTX" >/dev/null 2>&1 \
  && { pass=$((pass+1)); printf 'ok   garbage payload exits 0\n'; } \
  || { fail=$((fail+1)); printf 'FAIL garbage payload did not exit 0\n'; }
printf '{"session_id":"x","transcript_path":"/nonexistent"}\n' | CLAUDE_CONFIG_DIR="$CTXCFG" "$CTX" >/dev/null 2>&1 \
  && { pass=$((pass+1)); printf 'ok   missing transcript exits 0\n'; } \
  || { fail=$((fail+1)); printf 'FAIL missing transcript did not exit 0\n'; }
E="$TMP/tx-empty.jsonl"; : > "$E"
tc "empty transcript is quiet" quiet ctx-i "$E"

# Thresholds are overridable, and the override has to actually move the band.
if [ -n "$(AIWORKS_CONTEXT_WARN=30000 "$CTX" --check 40000)" ]; then
  pass=$((pass+1)); printf 'ok   AIWORKS_CONTEXT_WARN lowers the band\n'
else
  fail=$((fail+1)); printf 'FAIL AIWORKS_CONTEXT_WARN was ignored\n'
fi

# ── pretool-codegraph-nudge.sh ─────────────────────────────────────────────────────────
# Advisory like the two above — it always exits 0 — so every assertion is on the printed
# text. The fixture repos get a .codegraph/ directory because that, not the repo name, is
# what the hook keys on; `e2e` is deliberately left without one.
NUDGE="$H/pretool-codegraph-nudge.sh"
NUDGECFG="$TMP/nudgecfg"; mkdir -p "$NUDGECFG"
mkdir -p "$TMP/svc/.codegraph" "$TMP/db/.codegraph"

# n <name> <want: nudge|quiet> <session> <repeats> <command>
# Runs the command <repeats> times in one session and asserts on the LAST result: the hook
# fires on the third probe, so "did it nudge" is only answerable after a sequence.
n() {
  local name=$1 want=$2 sid=$3 reps=$4 cmd=$5 err i
  for i in $(seq 1 "$reps"); do
    err="$(jq -cn --arg c "$cmd" --arg s "$sid" \
             '{session_id:$s,tool_name:"Bash",tool_input:{command:$c}}' \
           | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_CONFIG_DIR="$NUDGECFG" "$NUDGE" 2>&1 >/dev/null)"
  done
  local got=quiet
  printf '%s' "$err" | grep -q 'has a codegraph index' && got=nudge
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s (wanted %s, got %s)\n' "$name" "$want" "$got"
  fi
}

n "first probe is quiet"            quiet ng-a 1 'grep -rn foo svc/src'
n "second probe is quiet"           quiet ng-b 2 'grep -rn foo svc/src'
n "third probe nudges"              nudge ng-c 3 'grep -rn foo svc/src'
n "fourth is quiet again"           quiet ng-c 1 'grep -rn foo svc/src'
n "a second repo counts separately" nudge ng-c 3 'cat db/src/main.rs'
n "a new session starts over"       nudge ng-d 3 'grep -rn foo svc/src'

# An unindexed directory has nothing to suggest, and a command already using the index is
# the behaviour being asked for — nudging either one would be pure noise.
n "unindexed path stays quiet"      quiet ng-e 4 'grep -rn foo e2e/src'
n "a codegraph call stays quiet"    quiet ng-f 4 'codegraph query Foo -p svc'

# Only search verbs. A repo name appearing in a build or a VCS command is not a probe.
n "git is not a probe"              quiet ng-g 4 'git status svc'
n "a test run is not a probe"       quiet ng-h 4 'scripts/dev.sh test svc'
n "a word containing grep is not"   quiet ng-i 4 './mygrep svc'

# The repo has to be recognised however the path is written, or the hook goes quiet on
# exactly the sessions doing the most searching.
n "bare path form"                  nudge ng-j 3 'grep -rn x svc/lib.rs'
n "dot-slash form"                  nudge ng-k 3 'grep -rn x ./svc/lib.rs'
n "quoted form"                     nudge ng-l 3 'grep -rn x "svc/lib.rs"'
n "absolute form"                   nudge ng-m 3 "grep -rn x $TMP/svc/lib.rs"

# The threshold is tunable, and the override has to actually move it.
err="$(jq -cn '{session_id:"ng-n",tool_name:"Bash",tool_input:{command:"grep -rn x svc"}}' \
       | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_CONFIG_DIR="$NUDGECFG" \
         AIWORKS_CODEGRAPH_NUDGE_AT=1 "$NUDGE" 2>&1 >/dev/null)"
if printf '%s' "$err" | grep -q 'has a codegraph index'; then
  pass=$((pass+1)); printf 'ok   AIWORKS_CODEGRAPH_NUDGE_AT lowers the threshold\n'
else
  fail=$((fail+1)); printf 'FAIL AIWORKS_CODEGRAPH_NUDGE_AT was ignored\n'
fi

# Never break the Bash call it rides in front of.
for bad in 'not json' '{}' '{"tool_input":{"command":"grep -rn x svc"}}'; do
  if printf '%s\n' "$bad" | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_CONFIG_DIR="$NUDGECFG" "$NUDGE" >/dev/null 2>&1; then
    pass=$((pass+1)); printf 'ok   exits 0 on payload: %s\n' "$bad"
  else
    fail=$((fail+1)); printf 'FAIL non-zero exit on payload: %s\n' "$bad"
  fi
done

# ── context-handoff.sh ─────────────────────────────────────────────────────────────────
# The self-handoff loop: at the handoff threshold the hook DEMANDS a handoff document at a
# path it names; once the document exists it goes quiet; when the window collapses (a
# compaction) it hands the document back; then the cycle re-arms. The fixtures are the
# on-disk transcript layout Claude Code writes — main transcript `<proj>/<sid>.jsonl`, a
# subagent's own at `<proj>/<sid>/subagents/agent-<id>.jsonl`, a workflow agent's under
# `subagents/workflows/<run>/` — because the payload's transcript_path names the MAIN
# transcript even inside a subagent (scripts/hook-signal-probe.sh), so measuring the wrong
# file is the bug this section pins.
HO="$H/context-handoff.sh"
HDIR="$TMP/handoff"
PROJ="$TMP/proj"; mkdir -p "$PROJ"

usage_row() { jq -cn --argjson r "$1" '{type:"assistant",message:{usage:{cache_read_input_tokens:$r,cache_creation_input_tokens:0,input_tokens:0,output_tokens:10}}}'; }
# mkctx <sid> <main-window> [<agent-id> <agent-window> [wf]] — builds the layout, prints nothing.
mkctx() {
  local sid=$1 mainw=$2 aid=${3:-} aw=${4:-} wf=${5:-}
  usage_row "$mainw" > "$PROJ/$sid.jsonl"
  [ -n "$aid" ] || return 0
  local d="$PROJ/$sid/subagents"; [ -n "$wf" ] && d="$d/workflows/wf_$wf"
  mkdir -p "$d"; usage_row "$aw" > "$d/agent-$aid.jsonl"
}
# Re-point a transcript's window without rebuilding the layout.
setwin() { usage_row "$2" > "$1"; }
# ho <sid> [<agent-id>] — runs the PostToolUse leg, prints stdout.
ho() {
  jq -cn --arg s "$1" --arg t "$PROJ/$1.jsonl" --arg a "${2:-}" \
    '{hook_event_name:"PostToolUse",session_id:$s,transcript_path:$t,tool_name:"Bash"} + (if $a != "" then {agent_id:$a,agent_type:"developer"} else {} end)' \
    | AIWORKS_HANDOFF_DIR="$HDIR" "$HO" 2>/dev/null
}
hoc() { # hoc <name> <want: quiet|block|context> <stdout>  (+ optional <substring the text must carry>)
  local name=$1 want=$2 out=$3 must=${4:-} got=quiet text=""
  if [ -n "$out" ]; then
    text="$(printf '%s' "$out" | jq -r '(.reason // "") + (.hookSpecificOutput.additionalContext // "")' 2>/dev/null)"
    [ "$(printf '%s' "$out" | jq -r '.decision // ""' 2>/dev/null)" = "block" ] && got=block || got=context
  fi
  if [ "$got" = "$want" ] && { [ -z "$must" ] || printf '%s' "$text" | grep -qF -- "$must"; }; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s (wanted %s%s, got %s)\n' "$name" "$want" "${must:+ carrying $must}" "$got"
  fi
}

mkctx h1 139999
hoc "under the handoff threshold is silent"        quiet "$(ho h1)"
mkctx h2 145000
hoc "main crossing demands the handoff by path"    block "$(ho h2)" "$HDIR/h2/main.md"
hoc "the demand names the skill"                   block "$(ho h2)" "handoff"
# A subagent's window is ITS transcript, never the parent's.
mkctx h3 200000 a3 50000
hoc "subagent under threshold stays quiet despite a fat parent" quiet "$(ho h3 a3)"
mkctx h4 50000 a4 145000
hoc "subagent crossing demands its own document"   block "$(ho h4 a4)" "$HDIR/h4/a4.md"
mkctx h5 50000 w5 145000 wf
hoc "workflow agent layout is resolved"            block "$(ho h5 w5)" "$HDIR/h5/w5.md"
mkctx h6 200000
hoc "an agent with no transcript on disk measures nothing" quiet "$(ho h6 ghost)"

# The nag has a budget: an agent without a Write tool cannot comply, and a demand that never
# ends is the one that gets ignored. Default 3 — the two above were 1 and 2.
hoc "third demand still fires"                     block "$(ho h2)" "(3/3)"
hoc "the fourth is silent — budget spent"          quiet "$(ho h2)"

# The document must be NEWER than the demand: a stale file from a previous cycle proves nothing.
mkctx h7 145000; ho h7 >/dev/null
mkdir -p "$HDIR/h7"; printf '# old\n' > "$HDIR/h7/main.md"; touch -t 200001010000 "$HDIR/h7/main.md"
hoc "a stale document does not satisfy the demand" block "$(ho h7)" "(2/3)"
printf '# Handoff h7\n\nNext: finish the thing.\n' > "$HDIR/h7/main.md"
hoc "a fresh document is recorded, not blocked"    context "$(ho h7)" "Handoff recorded at $HDIR/h7/main.md"
hoc "recorded tells a subagent to return a partial" quiet "$(ho h7)"   # said once, then quiet
setwin "$PROJ/h7.jsonl" 160000
hoc "written and still growing stays quiet"        quiet "$(ho h7)"
# A window never shrinks between two calls except across a compaction — so a drop IS one.
setwin "$PROJ/h7.jsonl" 90000
hoc "the collapse hands the document back"         context "$(ho h7)" "Next: finish the thing."
hoc "the document is handed back once"             quiet "$(ho h7)"
setwin "$PROJ/h7.jsonl" 141000
hoc "resumed re-arms: the next crossing demands again" block "$(ho h7)" "(1/3)"

# Compaction without a document: nothing to hand back, the cycle just re-arms.
mkctx h8 145000; ho h8 >/dev/null
setwin "$PROJ/h8.jsonl" 90000
hoc "collapse while requested is silent"           quiet "$(ho h8)"
setwin "$PROJ/h8.jsonl" 150000
hoc "and re-arms"                                  block "$(ho h8)" "(1/3)"

# SessionStart(compact) is the documented re-injection point — it fires BEFORE the first tool
# call after a compaction, so it wins over the collapse detection above, which then stays quiet.
ss() { jq -cn --arg s "$1" '{hook_event_name:"SessionStart",source:"compact",session_id:$s}' | AIWORKS_HANDOFF_DIR="$HDIR" "$HO" 2>/dev/null; }
mkctx h9 145000; ho h9 >/dev/null
mkdir -p "$HDIR/h9"; printf '# Handoff h9\n\nResume at step 4.\n' > "$HDIR/h9/main.md"; ho h9 >/dev/null
out="$(ss h9)"
if printf '%s' "$out" | grep -qF 'Resume at step 4.' && printf '%s' "$out" | grep -qF 'YOUR OWN handoff'; then
  pass=$((pass+1)); printf 'ok   SessionStart(compact) re-injects the document\n'
else fail=$((fail+1)); printf 'FAIL SessionStart(compact) did not re-inject the document\n'; fi
setwin "$PROJ/h9.jsonl" 90000
hoc "after SessionStart the collapse says nothing twice" quiet "$(ho h9)"
[ -z "$(ss h1)" ] \
  && { pass=$((pass+1)); printf 'ok   SessionStart with nothing written is silent\n'; } \
  || { fail=$((fail+1)); printf 'FAIL SessionStart with nothing written spoke\n'; }
# A workflow agent's brief carries `HANDOFF_KEY: <ticket>/<step>` (the dev-cycle/brd/prd agent
# wrappers append it), so the document is keyed by the STEP, not the agent: a replacement spawned
# for the same step — after a partial, or after the runtime killed its predecessor with no result
# at all — finds the document at a path the workflow could name in its brief without knowing any
# agent id. The key is read off the first user message of the agent's own transcript.
keyed() { # keyed <sid> <aid> <window> <key> — a subagent transcript whose brief carries the key
  local d="$PROJ/$1/subagents/workflows/wf_k"; mkdir -p "$d"
  { jq -cn --arg k "$4" '{type:"user",message:{role:"user",content:("Do the work.\n… HANDOFF_KEY: " + $k + ". CONTINUITY …")}}'
    usage_row "$3"; } > "$d/agent-$2.jsonl"
  usage_row 30000 > "$PROJ/$1.jsonl"
}
keyed h12 k1 145000 'FM-9/build|svc'
hoc "a keyed brief puts the document under by-key, sanitised" block "$(ho h12 k1)" "$HDIR/by-key/FM-9_build_svc.md"
mkdir -p "$HDIR/by-key"; printf '# Handoff k1\n' > "$HDIR/by-key/FM-9_build_svc.md"
hoc "and records it there"                          context "$(ho h12 k1)" "recorded at $HDIR/by-key/FM-9_build_svc.md"
# The replacement is a NEW agent on the SAME key: its own state starts armed, and the predecessor's
# document — older than its demand — is not mistaken for its own.
keyed h12 k2 145000 'FM-9/build|svc'
touch -t 200001010000 "$HDIR/by-key/FM-9_build_svc.md"
hoc "a replacement on the same key is asked for its own document" block "$(ho h12 k2)" "$HDIR/by-key/FM-9_build_svc.md"
hoc "the predecessor's document does not satisfy it" block "$(ho h12 k2)" "(2/3)"
# Array-shaped content (text blocks) carries the key too.
d="$PROJ/h13/subagents"; mkdir -p "$d"
{ jq -cn '{type:"user",message:{role:"user",content:[{type:"text",text:"HANDOFF_KEY: phase-1/research:phase-1 …"}]}}'; usage_row 145000; } > "$d/agent-k3.jsonl"
usage_row 30000 > "$PROJ/h13.jsonl"
hoc "a key in a text block is read too"             block "$(ho h13 k3)" "$HDIR/by-key/phase-1_research_phase-1.md"

# The advisory budget hook shares the resolver: inside a subagent it must read the subagent's
# window, not the parent's — before this it warned about the wrong agent, or not at all.
mkctx h11 40000 a11 180000
err="$(jq -cn --arg t "$PROJ/h11.jsonl" '{session_id:"h11",agent_id:"a11",transcript_path:$t,tool_name:"Bash"}' \
       | CLAUDE_CONFIG_DIR="$CTXCFG" "$CTX" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q 'context window 180k' \
  && { pass=$((pass+1)); printf 'ok   budget hook measures the subagent, not its parent\n'; } \
  || { fail=$((fail+1)); printf 'FAIL budget hook did not measure the subagent window\n'; }

mkctx h10 145000; ho h10 >/dev/null
[ -z "$(ss h10)" ] \
  && { pass=$((pass+1)); printf 'ok   SessionStart while merely requested is silent\n'; } \
  || { fail=$((fail+1)); printf 'FAIL SessionStart handed back a document that was never written\n'; }
for bad in 'not json' '{}' '{"hook_event_name":"PostToolUse","session_id":"x"}'; do
  if printf '%s\n' "$bad" | AIWORKS_HANDOFF_DIR="$HDIR" "$HO" >/dev/null 2>&1; then
    pass=$((pass+1)); printf 'ok   handoff hook exits 0 on payload: %s\n' "$bad"
  else
    fail=$((fail+1)); printf 'FAIL handoff hook non-zero exit on payload: %s\n' "$bad"
  fi
done

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
