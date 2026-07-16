#!/usr/bin/env bash
#
# SessionStart hook — mechanically resolve the workspace output-language policy.
#
# CLAUDE.md used to just tell Claude in prose to check workspace.config.local.yaml
# "before your first output each session" — that's a memory-dependent instruction,
# and it was missed twice in practice. workspace.config.local.yaml is also personal
# and git-ignored (see docs/adr/0003), so a teammate's own session never benefits
# from anything learned in someone else's conversation. This hook makes resolution
# mechanical: the harness runs it at the start of every session, for every user,
# and injects the resolved language straight into context.
#
# Precedence: workspace.config.local.yaml (personal override) > workspace.config.yaml
# (committed default) > "en" if neither file has a `language` line.

set -uo pipefail

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
local_file="$root/workspace.config.local.yaml"
default_file="$root/workspace.config.yaml"

extract_language() {
  grep -m1 -E '^language:' "$1" 2>/dev/null \
    | sed -E 's/^language:[[:space:]]*"?'"'"'?([a-zA-Z_-]+)"?'"'"'?.*/\1/'
}

lang=""
source_file=""

if [ -f "$local_file" ]; then
  lang=$(extract_language "$local_file")
  [ -n "$lang" ] && source_file="workspace.config.local.yaml"
fi

if [ -z "$lang" ] && [ -f "$default_file" ]; then
  lang=$(extract_language "$default_file")
  [ -n "$lang" ] && source_file="workspace.config.yaml"
fi

if [ -z "$lang" ]; then
  lang="en"
  source_file="default (no language: line found in either config)"
fi

if [ "$lang" = "th" ]; then
  policy="English spine, Thai prose: write prose in Thai; keep titles, headings, labels/enum values, all code + code comments + git commit messages + branch names, and technical/domain/proper-noun terms in English. Code and checked-in repo docs (docs/, README, ADRs, PRD/BRD) stay English."
else
  policy="Unchanged — respond in English, no localization applied."
fi

context="Resolved workspace output language: '$lang' (source: $source_file). $policy This is authoritative regardless of what language the user's own messages are written in — do not mirror the user's input language. Full convention: docs/agents/language.md."

jq -n --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
