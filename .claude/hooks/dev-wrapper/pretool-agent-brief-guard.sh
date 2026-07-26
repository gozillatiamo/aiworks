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
#   1b. brief names a concrete adapter path or a writing git command that the
#      target agent's tools: list does not grant        → block
#   2. brief orders a force-add (`git add -f`)           → block, always
#   3. brief dictates a non-canonical plan path          → block, always
#      (docs/agents/plan-artifacts.md is the source of truth)
#
# Fails OPEN whenever the agent definition cannot be read: an unknown or built-in
# subagent type is not a reason to block a delegation.
#
# Under CURSOR this is the ONLY layer that enforces a tool grant at all: Cursor
# ignores an agent file's tools: list entirely, and its `readonly: true` is no
# substitute (it blocks shell and MCP writes too, which every one of our so-called
# read-only agents needs). Cursor's subagent tool is `Task`, and its tool_input
# carries the same subagent_type/prompt, so this hook fires there unchanged.
# Per-CALL enforcement is not reachable in Cursor: a subagent's tool calls arrive
# under a fresh conversation_id with nothing naming the agent, so spawn time is
# the last point where the agent's identity is still known.
#
# Exit 0 = allow. Exit 2 = block, stderr goes back to the model as feedback.

set -uo pipefail

input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.tool_input.prompt // ""' 2>/dev/null)
agent=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)
[ -z "$prompt" ] && exit 0

root="${CLAUDE_PROJECT_DIR:-.}"
agent_file="$root/.claude/agents/$agent.md"

# The agent's ACTUAL grant list: the `tools:` block of the frontmatter, nothing
# else. Reading the whole file would be wrong — development-planner and qa-planner
# both discuss `Bash(git *)` in a frontmatter comment explaining why it was taken
# away from them, and a naive grep would credit them with the grant it warns about.
TOOLS=""
if [ -n "$agent" ] && [ -f "$agent_file" ]; then
  TOOLS=$(awk '
    /^---[ \t]*$/ { fm++; if (fm >= 2) exit; next }
    fm != 1 { next }
    /^tools:/ { intools = 1
                rest = $0; sub(/^tools:[ \t]*/, "", rest)
                if (rest != "") print rest          # inline form: tools: [A, B]
                next }
    intools && /^[ \t]*#/ { next }                  # comments explaining the grant
    intools && /^[ \t]+-[ \t]/ { sub(/^[ \t]+-[ \t]*/, ""); print; next }
    intools && /^[A-Za-z_]/ { intools = 0 }         # next frontmatter key
  ' "$agent_file")
fi

# granted <extended-regex> — is anything in the tools: list matching it?
# A `*` entry (the catch-all agent) grants everything.
granted() {
  [ -z "$TOOLS" ] && return 0                       # no parsable list → fail open
  printf '%s' "$TOOLS" | grep -qE '^\*$|^\*,|, *\*' && return 0
  printf '%s' "$TOOLS" | grep -qE "$1"
}

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

# ------------------------- 1b. brief names a tool the agent is not granted
# Check 1 reads intent from prose, which only works for phrasings we anticipated.
# This one triggers on the LITERAL command the brief puts in the agent's hands —
# an adapter path or a writing git verb — so it generalises to every capability
# without guessing, and the block can name the exact token that is out of bounds.
if [ -n "$TOOLS" ]; then
  # Fields are separated by ~, not | — a token regex needs its own alternation.
  # brief-token regex ~ required grant regex ~ what it is ~ who to hand it to
  while IFS='~' read -r token grant what who; do
    [ -z "$token" ] && continue
    printf '%s' "$prompt" | grep -qE "$token" || continue
    granted "$grant" && continue
    hit=$(printf '%s' "$prompt" | grep -oE "$token" | head -1)
    {
      echo "⛔ Blocked: this brief hands '$agent' $what, which it is not granted."
      echo "   the brief says: $hit"
      echo
      echo ".claude/agents/$agent.md does not list a matching tool. An agent told"
      echo "to do something outside its grant does not refuse — it improvises a way"
      echo "round the missing door (APP-1944: a planner asked to publish reached for"
      echo "\`git push -o merge_request.create\`)."
      echo
      echo "Either drop that step from the brief and do it yourself afterwards, or"
      echo "delegate it to $who."
    } >&2
    exit 2
  done <<'RULES'
scripts/vcs/[a-z-]+\.sh~Bash\(\*?scripts/vcs~the VCS adapter~developer or code-reviewer
scripts/notify/[a-z-]+\.sh~Bash\(\*?scripts/notify~the notify adapter~code-reviewer, or run the /notify skill yourself
scripts/tracker/[a-z-]+\.sh~Bash\(\*?scripts/tracker~the tracker adapter~product-owner, or run /update-ticket yourself
scripts/observability/[a-z-]+\.sh~Bash\(\*?scripts/observability~the observability adapter~performance-engineer or performance-triage
git (commit|push|merge|rebase|cherry-pick|reset --hard)~Bash\(git \*\)~write access to git~an agent that owns the branch (developer, qa-runner)
RULES
fi

# gh / glab are never anyone's grant — every repo is reached through scripts/vcs/.
if printf '%s' "$prompt" | grep -qE '\b(gh|glab) (pr|mr|issue|api|repo|release|merge-request) '; then
  {
    echo "⛔ Blocked: this brief tells '$agent' to call gh/glab directly."
    echo
    echo "No agent is granted those. Both providers are reached through the VCS"
    echo "adapter (scripts/vcs/), which is what makes the workflow provider-agnostic"
    echo "— see CLAUDE.md. Name the adapter script instead."
  } >&2
  exit 2
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
