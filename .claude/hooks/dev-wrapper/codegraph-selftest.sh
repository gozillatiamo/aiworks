#!/usr/bin/env bash
#
# Regression suite for the two codegraph hooks:
#   pretool-codegraph-guard.sh   makes every query address the right repo
#   posttool-codegraph-sync.sh   keeps the touched repo's index current
#
# Run:  .claude/hooks/dev-wrapper/codegraph-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# Fixtures are a THROWAWAY workspace in a temp dir — its own repo directories, its
# own .codegraph/ markers — so the result never depends on which repos this
# workspace has cloned or indexed. Same doctrine as guards-selftest.sh.
#
# The case that matters most is the silent one: a relative `-p` naming another repo
# while the cwd sits inside a different one. codegraph walks up to the nearest
# index and answers from the WRONG repo with exit 0, so nothing downstream can tell.
# If the rewrite to an absolute path ever regresses, no test but this one will say so.

set -uo pipefail

H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$H/pretool-codegraph-guard.sh"
SYNC="$H/posttool-codegraph-sync.sh"
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

TMP="$(mktemp -d)"
STATE="${TMPDIR:-/tmp}/aiworks-codegraph-sync"
trap 'rm -rf "$TMP" "$STATE/svc" "$STATE/web" 2>/dev/null' EXIT
export CLAUDE_PROJECT_DIR="$TMP"

mkdir -p "$TMP/svc/.codegraph" "$TMP/svc/src" "$TMP/web/.codegraph" "$TMP/web/src" "$TMP/tools"
# The DB is what marks a real index. codegraph's own install dir (~/.codegraph/)
# has the directory but no db, and testing for the directory alone made every
# path under $HOME look indexed — the bug this fixture shape exists to catch.
: > "$TMP/svc/.codegraph/codegraph.db"; : > "$TMP/web/.codegraph/codegraph.db"
: > "$TMP/svc/src/app.rs"; : > "$TMP/web/src/app.tsx"; : > "$TMP/tools/helper.sh"
mkdir -p "$TMP/noindex/src"; : > "$TMP/noindex/src/x.go"      # never indexed
mkdir -p "$TMP/halfindex/.codegraph"; mkdir -p "$TMP/halfindex/src"  # dir, but no db

pass=0; fail=0
run() { # run <command> [cwd]
  jq -cn --arg c "$1" --arg d "${2:-$TMP}" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | "$GUARD"
}
rc() { # rc <command> [cwd]  -> exit status of the guard
  jq -cn --arg c "$1" --arg d "${2:-$TMP}" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
    | "$GUARD" >/dev/null 2>&1; echo $?
}
cmdof() { printf '%s' "$1" | jq -r '.hookSpecificOutput.updatedInput.command // ""' 2>/dev/null; }

is()      { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
            else echo "  FAIL  $1"; echo "        want: $2"; echo "        got:  $3"; fail=$((fail+1)); fi }
untouched(){ if [ -z "$2" ]; then echo "  PASS  $1"; pass=$((pass+1));
            else echo "  FAIL  $1 (rewrote to: $2)"; fail=$((fail+1)); fi }

echo "== a relative -p becomes absolute, wherever the agent happens to be =="
is "from the workspace root" \
   "codegraph explore Foo -p $TMP/svc" \
   "$(cmdof "$(run 'codegraph explore Foo -p svc')")"
# The silent-wrong-answer case: cwd is one repo, the query names another.
is "from INSIDE another repo" \
   "codegraph explore Foo -p $TMP/svc" \
   "$(cmdof "$(run 'codegraph explore Foo -p svc' "$TMP/web")")"
is "a path deeper than the repo root" \
   "codegraph node Foo -p $TMP/svc/src/app.rs" \
   "$(cmdof "$(run 'codegraph node Foo -p svc/src/app.rs')")"
is "the --path spelling" \
   "codegraph callers foo --path $TMP/web" \
   "$(cmdof "$(run 'codegraph callers foo --path web')")"
is "the --path=value spelling" \
   "codegraph impact foo --path=$TMP/web" \
   "$(cmdof "$(run 'codegraph impact foo --path=web')")"

echo "== the MCP tool name is mapped to the CLI's =="
is "search becomes query"        "codegraph query Foo -p $TMP/svc" "$(cmdof "$(run 'codegraph search Foo -p svc')")"
is "search with an absolute -p"  "codegraph query Foo -p $TMP/svc" "$(cmdof "$(run "codegraph search Foo -p $TMP/svc")")"
# explore and node are real CLI subcommands as of 1.5.0 — they must not be touched.
untouched "explore is left alone" "$(cmdof "$(run "codegraph explore Foo -p $TMP/svc")")"
untouched "node is left alone"    "$(cmdof "$(run "codegraph node Foo -p $TMP/svc")")"

echo "== already correct, or none of the hook's business =="
untouched "an absolute -p"            "$(cmdof "$(run "codegraph impact Foo -p $TMP/web")")"
untouched "a \$VAR path"              "$(cmdof "$(run 'codegraph explore Foo -p $CLAUDE_PROJECT_DIR/svc')")"
untouched "no -p, but cwd IS a repo"  "$(cmdof "$(run 'codegraph explore Foo' "$TMP/svc")")"
untouched "cwd deep inside a repo"    "$(cmdof "$(run 'codegraph explore Foo' "$TMP/svc/src")")"
untouched "a non-query subcommand"    "$(cmdof "$(run 'codegraph sync -q')")"
untouched "a command without codegraph" "$(cmdof "$(run 'grep -rn codegraph docs/')")"
untouched "codegraph named inside a string, not run" \
          "$(cmdof "$(run "echo 'run codegraph explore later'")")"

echo "== blocked, because resolving it would mean guessing =="
is "no -p, cwd outside any repo"      2 "$(rc 'codegraph explore Foo')"
is "no -p, cwd in an unindexed repo"  2 "$(rc 'codegraph explore Foo' "$TMP/noindex")"
is "a relative -p naming no repo"     2 "$(rc 'codegraph explore Foo -p nope')"
is "an unindexed repo by name"        2 "$(rc 'codegraph explore Foo -p noindex')"
# A .codegraph/ directory with no codegraph.db is not an index — that is exactly
# the shape of codegraph's own install dir, and treating it as one silently
# disabled this whole guard for any cwd under $HOME.
is "a .codegraph dir with no db"      2 "$(rc 'codegraph explore Foo -p halfindex')"
is "cwd in a db-less .codegraph repo" 2 "$(rc 'codegraph explore Foo' "$TMP/halfindex")"
# Captured first, then matched: the guard exits 2 here by design, and under
# `pipefail` that status would propagate out of a `… | grep` pipeline and make the
# following `&&` fail regardless of what the message said.
msg=$(run 'codegraph explore Foo' 2>&1 >/dev/null)
is "the block names the repos"   "yes" "$(printf '%s' "$msg" | grep -q 'svc' && echo yes || echo no)"
is "and tells the agent to use an absolute path" \
   "yes" "$(printf '%s' "$msg" | grep -q 'ABSOLUTE' && echo yes || echo no)"

echo "== the sync hook picks the right repo, and only an indexed one =="
sync_run() { rm -f "$STATE/svc" "$STATE/web" 2>/dev/null
  jq -cn --arg p "$1" '{hook_event_name:"PostToolUse",tool_name:"Write",tool_input:{file_path:$p}}' \
    | CODEGRAPH_SELFTEST=1 "$SYNC" >/dev/null 2>&1; echo $?; }
is "an edit inside an indexed repo"   0 "$(sync_run "$TMP/svc/src/app.rs")"
is "an edit in an unindexed repo"     0 "$(sync_run "$TMP/noindex/src/x.go")"
is "an edit outside any repo"         0 "$(sync_run "$TMP/tools/helper.sh")"
is "an edit outside the workspace"    0 "$(sync_run "/etc/hosts")"
# The debounce must actually mark the repo, or a ten-file slice spawns ten syncs.
rm -f "$STATE/svc"
jq -cn --arg p "$TMP/svc/src/app.rs" '{hook_event_name:"PostToolUse",tool_name:"Write",tool_input:{file_path:$p}}' | "$SYNC" >/dev/null 2>&1
if [ -f "$STATE/svc" ]; then echo "  PASS  the first edit stamps the debounce"; pass=$((pass+1));
else echo "  FAIL  the first edit stamps the debounce"; fail=$((fail+1)); fi
if [ ! -f "$STATE/noindex" ]; then echo "  PASS  an unindexed repo is never stamped"; pass=$((pass+1));
else echo "  FAIL  an unindexed repo is never stamped"; fail=$((fail+1)); fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
