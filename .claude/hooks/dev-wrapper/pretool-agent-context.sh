#!/usr/bin/env bash
#
# PreToolUse(Agent) hook — bake the resolved OUTPUT LANGUAGE, and the output-compression
# rule, into the spawn brief itself instead of hoping the subagent resolves them.
#
# This is the last hole in a fix that has now been attempted four times. `language` lives
# in workspace.config.yaml, overridden by a personal, git-ignored workspace.config.local.yaml
# (docs/adr/0003). For the MAIN session .claude/hooks/resolve-language.sh injects the answer
# mechanically. For a WORKFLOW, prd/dev-cycle/brd.js run one dedicated resolver agent and
# bake LANGUAGE_DIRECTIVE into every downstream prompt. What was left was a subagent spawned
# DIRECTLY through the Agent tool: it had only an imperative "read the file first" line in its
# own definition, measured at roughly half compliance — and in a 5-agent probe on a workspace
# resolved to `th`, two agents announced "Language resolved: en (workspace.config.yaml)",
# having read the shared file and never the override. Wrong, confidently, with no symptom
# beyond prose in the wrong language.
#
# A hook removes the model from that decision, exactly as the other two layers do.
#
# It also carries the compression rule for a DEFINITION-LESS agent type. A named agent
# preloads caveman through `skills: - caveman:caveman` in its own file (verified: the skill's
# text was present in 5/5 probe transcripts), so it needs nothing here. `general-purpose`,
# `Explore` and `Plan` have no definition to preload from, which is the same gap the three
# workflows close by appending CAVEMAN_DIRECTIVE to their general-purpose briefs.
#
# Deliberately NOT a second copy of policy: both directives are the same text the workflows
# inject, so a run driven by hand and a run driven by dev-cycle brief an agent identically.
#
# The rewrite emits the WHOLE tool_input with only `prompt` replaced. Emitting just the one
# field would bet on updatedInput being merged rather than substituted — and if it were
# substituted, `subagent_type` would vanish and the spawn would silently become the default
# agent. Not a bet worth taking for one saved line.
#
# Exit 0 = allow unchanged, or allow with a rewritten prompt. This hook never blocks: the
# brief guard on the same matcher owns refusal.

set -uo pipefail

input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.tool_input.prompt // ""' 2>/dev/null)
[ -z "$prompt" ] && exit 0
agent=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)

root="${CLAUDE_PROJECT_DIR:-.}"

# ── resolve the language, local file first ────────────────────────────────────
# The same six lines as .claude/hooks/resolve-language.sh, which stays the canonical
# statement of the precedence. Duplicated rather than sourced for the same reason every
# guard in this directory is standalone: it has to keep working when copied into a repo
# clone that has no resolve-language.sh of its own.
extract_language() { # extract_language <file>
  [ -f "$1" ] || return 0
  sed -n 's/^[[:space:]]*language:[[:space:]]*"\{0,1\}\([a-zA-Z-]\{1,\}\)"\{0,1\}[[:space:]]*$/\1/p' "$1" | head -1
}
lang=""
lang=$(extract_language "$root/workspace.config.local.yaml")
[ -n "$lang" ] || lang=$(extract_language "$root/workspace.config.yaml")
[ -n "$lang" ] || lang="en"

# ── decide what this brief is missing ─────────────────────────────────────────
add=""

# `en` is the default behaviour, so there is nothing to say. Injecting a directive for it
# would only add tokens and invite an agent to treat English as a special instruction.
if [ "$lang" = "th" ]; then
  case "$prompt" in
    *LANGUAGE_DIRECTIVE*|*"OUTPUT LANGUAGE = "*) ;;   # a workflow already baked it in
    *) add=" LANGUAGE_DIRECTIVE — OUTPUT LANGUAGE = th, already resolved for this run (docs/agents/language.md). This is AUTHORITATIVE: do NOT re-check any config file or override it with your own resolution — obey it verbatim. Write ALL prose — chat, ticket description & comments, PR/MR description & review discussion, and the .html render of a plan — in THAI, but keep the English SPINE English: titles + every section heading + labels/enum values, ALL code + code comments + git commit messages + branch names, and technical/transliterated/domain terms + proper nouns (Arabic numerals always). Code, checked-in repo docs (docs/, README, ADRs, committed PRD/BRD files), AND ANY file you author with a .md extension (plans, testcases, PRD/summary Markdown in agent_logs/) are NEVER Thai — the th prose rule applies to chat, tickets, PR/MR discussion, Slack, and .html docs only." ;;
  esac
fi

# Compression: only for an agent type with no definition to preload it from. A definition
# that mentions caveman at all already carries it (frontmatter preload plus a Step 1 line).
agent_file="$root/.claude/agents/$agent.md"
needs_caveman=1
if [ -n "$agent" ] && [ -f "$agent_file" ] && grep -q 'caveman' "$agent_file" 2>/dev/null; then
  needs_caveman=0
fi
if [ "$needs_caveman" -eq 1 ]; then
  case "$prompt" in
    *CAVEMAN_DIRECTIVE*) ;;                            # a workflow already baked it in
    *) add="$add CAVEMAN_DIRECTIVE — invoke \`/caveman:caveman\` and write every report, comment, and reply ultra-compressed: drop articles/filler/pleasantries/hedging, fragments are fine, technical accuracy stays FULL, and code + identifiers + error strings stay verbatim. It governs how you WRITE, never what you DO: never skip a tool call, never skip a tool-availability check, and never claim a tool or shell is unavailable without first actually running it. It never applies to your INPUT either: the brief that spawned you stands in FULL — do not compress or summarize it away. If you spawn or message another agent, its FIRST brief goes out in FULL for the same reason, while every follow-up after that spawn IS compressed (the context already landed; a follow-up is a pointer, not a context transfer) — style only, so any NEW fact in a follow-up still goes in complete." ;;
  esac
fi

[ -n "$add" ] || exit 0

printf '%s' "$input" | jq -c --arg add "$add" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse",
     updatedInput: (.tool_input | .prompt = (.prompt + $add))}}'
exit 0
