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

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
