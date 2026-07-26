#!/usr/bin/env bash
#
# PreToolUse(Write|Edit) hook — a planning artifact must land at the ONE canonical
# path the workflow reads it back from.
#
# This is a MULTI-REPO workspace. dev-cycle runs plan→build→review per repo, and
# hands each build agent the plan path *inside that agent's own repo*
# (dev-cycle.js: `${ticket}-${repo}-plan.md`). So a single plan file covering
# three repos, written into one of them, is unreadable by the other two — the
# build agents get a path that does not exist in their cwd. That happened for
# real on a three-repo ticket: one <primary-repo>/agent_logs/<KEY>-plan.md held
# the other two repos' sections too, so two of the three had no plan at all.
#
# Canonical paths — the single source of truth is docs/agents/plan-artifacts.md:
#   code repo        <repo>/agent_logs/development-planner/<KEY>-<repo>-plan.md
#   test-suite repo  <repo>/agent_logs/<KEY>-automation-plan.md
#   HTML render      <repo>/agent_logs/<KEY>-<repo>-plan.html
#
# Only files that ALREADY look like a plan artifact are inspected: a basename
# starting with a ticket key and ending in -plan.md / -plan.html. Everything else
# in agent_logs/ (testcases, bugs, report, prd) is none of this hook's business.
#
# Exit 0 = allow. Exit 2 = block, stderr goes back to the model as feedback.

set -uo pipefail

input=$(cat)
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$path" ] && exit 0

base=$(basename "$path")
dir=$(dirname "$path")

# Only plan artifacts, and only ones named for a ticket key.
case "$base" in
  *-plan.md|*-plan.html) ;;
  *) exit 0 ;;
esac
key=$(printf '%s' "$base" | sed -nE 's/^([A-Z][A-Z0-9]+-[0-9]+)-.*/\1/p')
[ -z "$key" ] && exit 0

# A test-suite repo's automation plan has its own name and sits directly in
# agent_logs/ — allowed as-is.
case "$base" in
  "${key}-automation-plan.md") exit 0 ;;
esac

# Resolve the owning repo. The target directory usually does NOT exist yet — the
# planner creates it on the way in — so walk up to the nearest existing ancestor
# before asking git, or every first write would slip through unchecked.
probe="$dir"
while [ ! -d "$probe" ]; do
  parent=$(dirname "$probe")
  [ "$parent" = "$probe" ] && break
  probe="$parent"
done

# Fail OPEN when the repo cannot be determined — a guard that cannot see the repo
# must not block the write.
repo_root=$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$repo_root" ] || exit 0
repo=$(basename "$repo_root")

# git reports a SYMLINK-RESOLVED toplevel, while the incoming path is whatever the
# caller wrote. On macOS a workspace under /tmp or /var is symlinked to /private/…,
# so comparing the two spellings directly would reject a perfectly canonical path.
# Rebuild the target directory in resolved form: resolve the existing ancestor,
# then re-attach the not-yet-created tail.
probe_real=$(cd "$probe" 2>/dev/null && pwd -P) || probe_real="$probe"
dir="${probe_real}${dir#"$probe"}"

# The meta-repo is not a place for plans: its own workspace.config.yaml marks it.
if [ -f "$repo_root/workspace.config.yaml" ]; then
  {
    echo "⛔ Blocked: plan artifact written into the META-repo, not a product repo."
    echo "   $path"
    echo
    echo "A plan belongs INSIDE the repo whose code it plans, so the build agent"
    echo "for that repo can read it from its own cwd. One plan file PER REPO."
    echo "See docs/agents/plan-artifacts.md."
  } >&2
  exit 2
fi

case "$base" in
  *.md)   want_dir="$repo_root/agent_logs/development-planner"; want_base="${key}-${repo}-plan.md" ;;
  *.html) want_dir="$repo_root/agent_logs";                     want_base="${key}-${repo}-plan.html" ;;
esac

# Normalise both sides before comparing so ./ and // spellings still match.
norm() { printf '%s' "$1" | sed -e 's#/\./#/#g' -e 's#//*#/#g' -e 's#/$##'; }
[ "$(norm "$dir")" = "$(norm "$want_dir")" ] && [ "$base" = "$want_base" ] && exit 0

{
  echo "⛔ Blocked: plan artifact is not at its canonical path."
  echo "   got:  $path"
  echo "   want: $want_dir/$want_base"
  echo
  echo "Why it matters: dev-cycle hands each repo's build agent the plan path"
  echo "inside THAT repo. A misfiled or repo-less name is unreadable to the"
  echo "agent that needs it, and a single file covering several repos leaves the"
  echo "other repos with no plan at all."
  echo
  echo "One plan file PER REPO. Canonical layout:"
  echo "  code repo        <repo>/agent_logs/development-planner/<KEY>-<repo>-plan.md"
  echo "  test-suite repo  <repo>/agent_logs/<KEY>-automation-plan.md"
  echo "  HTML render      <repo>/agent_logs/<KEY>-<repo>-plan.html"
  echo "Full rule: docs/agents/plan-artifacts.md"
} >&2
exit 2
