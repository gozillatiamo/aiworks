#!/usr/bin/env bash
#
# PreToolUse(Agent) hook — refuse a delegation brief that orders a subagent to do
# something outside its own tool grant, or that contradicts a workspace convention.
#
# This guards the ORCHESTRATOR, not the subagent. Every other guard in this
# directory fires while the subagent is already running and improvising a way to
# obey a bad instruction; this one fires before it starts.
#
# The APP-1944 case, end to end: the brief told development-planner to "commit the
# plan doc and open a PR/MR via the VCS adapter". That agent's grant deliberately
# has no Bash(*scripts/vcs/*) — PR/MR creation belongs to a later workflow phase —
# so instead of refusing, it reached the only door left open to it
# (`git push -o merge_request.create`) and force-added a git-ignored plan to get
# something into the MR. Both symptoms trace back to one over-reaching brief.
#
# Checks:
#   1. brief orders PR/MR creation or a merge, but the target agent has no
#      Bash(*scripts/vcs/*) grant                       → block
#   2. brief orders a force-add (`git add -f`)           → block, always
#   3. brief dictates a non-canonical plan path          → block, always
#      (docs/agents/plan-artifacts.md is the source of truth)
#
# Fails OPEN whenever the agent definition cannot be read: an unknown or built-in
# subagent type is not a reason to block a delegation.
#
# Exit 0 = allow. Exit 2 = block, stderr goes back to the model as feedback.

set -uo pipefail

input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.tool_input.prompt // ""' 2>/dev/null)
agent=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)
[ -z "$prompt" ] && exit 0

root="${CLAUDE_PROJECT_DIR:-.}"

# --------------------------------------------- 1. PR/MR work without the grant
if [ -n "$agent" ] && [ -f "$root/.claude/agents/$agent.md" ]; then
  if ! grep -qE 'Bash\(\*?scripts/vcs' "$root/.claude/agents/$agent.md"; then
    if printf '%s' "$prompt" | grep -qiE '(open|create|raise|submit)[^.]{0,30}(PR|MR|pull[- ]request|merge[- ]request)|(squash[- ])?merge (it|the (PR|MR|branch))'; then
      {
        echo "⛔ Blocked: this brief orders PR/MR work that '$agent' is not granted."
        echo
        echo ".claude/agents/$agent.md has no Bash(*scripts/vcs/*) — opening or"
        echo "merging a PR/MR is deliberately NOT its job. Told to anyway, a"
        echo "subagent does not refuse; it improvises (e.g."
        echo "\`git push -o merge_request.create\`, which bypasses the adapter)."
        echo
        echo "Do one of these instead:"
        echo "  • drop the PR/MR step from the brief; let the subagent hand back"
        echo "    the branch, and open the PR/MR YOURSELF via scripts/vcs/open-pr.sh"
        echo "  • delegate that step to an agent that IS granted the adapter"
        echo "    (developer, code-reviewer), or run the dev-cycle workflow, whose"
        echo "    PR/MR phase already owns it"
      } >&2
      exit 2
    fi
  fi
fi

# ------------------------------------------------------ 2. force-add, always no
if printf '%s' "$prompt" | grep -qE 'git add[^&|;]*(-f|--force)|force[- ]add'; then
  {
    echo "⛔ Blocked: this brief orders a force-add of a git-ignored path."
    echo
    echo "Ignored paths are ignored on purpose. agent_logs/ in particular holds"
    echo "LOCAL planning artifacts that are never committed —"
    echo "see docs/agents/plan-artifacts.md."
    echo
    echo "Publish by reference instead: a ticket comment"
    echo "(scripts/tracker/add-ticket-comment.sh) or a shareable Artifact URL."
  } >&2
  exit 2
fi

# ------------------------------------------- 3. non-canonical plan path in brief
bad_path=$(printf '%s' "$prompt" | grep -oE 'agent_logs/[A-Z][A-Z0-9]+-[0-9]+-plan\.(md|html)' | head -1)
if [ -n "$bad_path" ]; then
  {
    echo "⛔ Blocked: this brief dictates a non-canonical plan path."
    echo "   got: $bad_path"
    echo
    echo "This is a MULTI-REPO workspace and dev-cycle hands each repo's build"
    echo "agent the plan path inside THAT repo. A name with no repo segment"
    echo "collapses a multi-repo ticket into one file the other repos cannot read."
    echo
    echo "One plan file PER touched repo:"
    echo "  code repo        <repo>/agent_logs/development-planner/<KEY>-<repo>-plan.md"
    echo "  test-suite repo  <repo>/agent_logs/<KEY>-automation-plan.md"
    echo "  HTML render      <repo>/agent_logs/<KEY>-<repo>-plan.html"
    echo
    echo "Do not restate the path in the brief at all — point the subagent at"
    echo "docs/agents/plan-artifacts.md, the single source of truth."
  } >&2
  exit 2
fi

exit 0
