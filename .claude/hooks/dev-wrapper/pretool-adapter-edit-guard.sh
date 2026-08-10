#!/usr/bin/env bash
#
# PreToolUse(Write|Edit|NotebookEdit) hook — stop an agent from rewriting the SHARED
# provider adapters while it believes it is editing a file inside one product repo.
#
# `aiworks add` links the workspace adapters into every repo (aiworks-add.sh §3.3):
#
#     <root>/<repo>/scripts/vcs      ->  ../../scripts/vcs
#     <root>/<repo>/scripts/tracker  ->  ../../scripts/tracker
#
# so an agent with cwd in a repo can call them by the relative path every skill uses.
# The cost is that <repo>/scripts/vcs/gitlab.sh and <root>/scripts/vcs/gitlab.sh are the
# SAME FILE: an edit "in this repo" silently changes how PRs, tickets and notifications
# work for all of them. Nothing warns you — the links are hidden in .git/info/exclude, so
# the repo's own `git status` stays clean, and `git -C <repo>/scripts/vcs rev-parse
# --show-toplevel` answers with the META-REPO, not the repo you thought you were in.
#
# A dev-cycle agent hit exactly this: its adapter call was denied for being compound, it
# concluded the adapter was broken, edited scripts/vcs/gitlab.sh from inside a test-suite
# repo to "fix" it, and then called the provider CLI directly anyway.
#
# So: an edit that reaches the adapters THROUGH a repo symlink is refused. Editing them at
# the workspace root is untouched — that is where framework work belongs, and where the
# change is visible to review as what it actually is.
#
# Exit 0 = allow. Exit 2 = block, stderr goes back to the model as feedback.
# Fails OPEN on anything it cannot determine.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
[ -z "$path" ] && exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$path" in /*) ;; *) path="$ROOT/$path" ;; esac

# Only adapter paths are in scope — everything else exits immediately.
case "$path" in
  */scripts/vcs/*|*/scripts/tracker/*|*/scripts/notify/*|*/scripts/observability/*) ;;
  *) exit 0 ;;
esac

dir=${path%/*}
[ -d "$dir" ] || exit 0                      # not a real directory yet — nothing to resolve

# The deciding comparison: where the path SAYS it is, versus where it physically lands.
real_dir=$(cd "$dir" 2>/dev/null && pwd -P) || exit 0
root_real=$(cd "$ROOT" 2>/dev/null && pwd -P) || exit 0

# Compare against the literal spelling RE-ANCHORED on the resolved root, not against the
# literal itself: a workspace that already sits under a symlinked prefix (/tmp -> /private/tmp
# on macOS) resolves every path it contains, so a plain !=  would read an ordinary root-level
# framework edit as a redirect and block it. Only a difference the re-anchoring cannot explain
# is a real symlink hop.
case "$dir" in
  "$ROOT"/*) expected="$root_real${dir#"$ROOT"}" ;;
  *)         expected="$dir" ;;
esac
[ "$real_dir" = "$expected" ] && exit 0       # no symlink hop in play

case "$real_dir" in "$root_real"/scripts/*) ;; *) exit 0 ;; esac

adapter=${real_dir#"$root_real"/scripts/}
adapter=${adapter%%/*}
file=${path##*/}
{
  echo "⛔ Blocked: editing the shared $adapter adapter through a repo symlink."
  echo
  echo "   you wrote:  $path"
  echo "   it lands:   $real_dir/$file"
  echo
  echo "$dir is a SYMLINK to $root_real/scripts/$adapter."
  echo "This file is shared by every repo in the workspace, so the edit you are"
  echo "about to make is not local to this repo — it changes the adapter for all"
  echo "of them, and the repo's own git will not show it (the link is hidden in"
  echo ".git/info/exclude, and git reports the META-REPO as its toplevel)."
  echo
  echo "If the adapter is genuinely failing, that is a RESULT to report — the exact"
  echo "command, its exit code and its stderr — not something to patch around. A"
  echo "compound call (\`cd X && scripts/vcs/<writer>.sh …\`) is denied by design and"
  echo "gives you no prompt, which reads exactly like a broken adapter; run the"
  echo "writer BARE after a separate \`cd\`."
  echo
  echo "If this really is framework work on the adapter itself, do it at the"
  echo "workspace root, where it is reviewable as what it is:"
  echo "  $root_real/scripts/$adapter/$file"
} >&2
exit 2
