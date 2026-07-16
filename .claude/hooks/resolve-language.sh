#!/usr/bin/env bash
#
# SessionStart + UserPromptSubmit hook — mechanically resolve the workspace
# output-language policy and inject it into context.
#
# CLAUDE.md used to just tell Claude in prose to check workspace.config.local.yaml
# "before your first output each session" — that's a memory-dependent instruction,
# and it was missed twice in practice. workspace.config.local.yaml is also personal
# and git-ignored (see docs/adr/0003), so a teammate's own session never benefits
# from anything learned in someone else's conversation. This hook makes resolution
# mechanical: the harness runs it at the start of every session, for every user,
# and injects the resolved language straight into context.
#
# A SessionStart-only injection was found (2026-07-16) to not be enough: over a long,
# tool-heavy session the one-time injection gets crowded out and the model quietly
# drifts back to English even with `th` resolved. dev-cycle.js/prd.js avoid this for
# headless workflows by appending a LANGUAGE_DIRECTIVE to every agent prompt (see
# docs/agents/language.md #4) — this hook now gives the interactive CLI session the
# same per-turn reinforcement by also running on UserPromptSubmit (compact reminder,
# every turn) alongside the full SessionStart injection (once per session). Wired
# under both events in .claude/settings.json — since this file is committed, every
# teammate's session gets the same reinforcement, not just this one.
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
  full_policy="English spine, Thai prose: write prose in Thai; keep titles, headings, labels/enum values, all code + code comments + git commit messages + branch names, and technical/domain/proper-noun terms in English. Code and checked-in repo docs (docs/, README, ADRs, PRD/BRD) stay English."
  brief_policy="write THIS reply's prose in Thai (English spine: headings/labels, code, commit messages/branch names, and technical/domain terms stay English)."
else
  full_policy="Unchanged — respond in English, no localization applied."
  brief_policy="respond in English — no localization applied."
fi

# SessionStart fires once per session (full explanation). UserPromptSubmit fires on
# every turn (compact reminder only, to avoid ballooning context on every message).
event=$(cat 2>/dev/null | jq -r '.hook_event_name // empty' 2>/dev/null)
[ -z "$event" ] && event="SessionStart"

if [ "$event" = "UserPromptSubmit" ]; then
  context="[language policy: '$lang'] Reminder — $brief_policy Authoritative regardless of what language the user's message just used."
else
  context="Resolved workspace output language: '$lang' (source: $source_file). $full_policy This is authoritative regardless of what language the user's own messages are written in — do not mirror the user's input language. Full convention: docs/agents/language.md."
fi

jq -n --arg ctx "$context" --arg ev "$event" \
  '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
