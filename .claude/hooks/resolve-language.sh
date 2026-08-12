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

# extract_key FILE KEY -> the scalar value of a top-level `KEY:` line, or empty.
# One parser for both keys on purpose: a second copy is how the two resolutions drift apart.
extract_key() {
  local line val
  line=$(grep -m1 -E "^$2:" "$1" 2>/dev/null) || return 0
  [ -z "$line" ] && return 0
  val="${line#*:}"          # drop the key
  val="${val%%#*}"          # drop any trailing comment
  printf '%s' "$val" | tr -d "[:space:]\"'"
}

extract_language() { extract_key "$1" language; }

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

# `case_report_language` — the language of a DEPLOYED-ENVIRONMENT CASE REPORT, independently of
# the session language. A case report is read and acted on by whoever reported the case (support,
# an operator), who is frequently not the person running the session and frequently does not read
# the session's language. Same precedence as `language`; unset = follow `language`.
#
# Keyed on the ARTIFACT, not on which agent produced it: an identical report must not arrive in a
# different language depending on whether a spawned agent produced it or it was answered inline,
# an implementation detail the reader cannot see.
case_lang=""
if [ -f "$local_file" ]; then
  case_lang=$(extract_key "$local_file" case_report_language)
fi
if [ -z "$case_lang" ] && [ -f "$default_file" ]; then
  case_lang=$(extract_key "$default_file" case_report_language)
fi
[ -z "$case_lang" ] && case_lang="$lang"

# lang_name CODE -> a name to write in the injected prose. Unknown codes pass through as the code,
# so a new language needs no change here to work.
lang_name() {
  case "$1" in
    th) printf 'Thai' ;;
    en) printf 'English' ;;
    *)  printf '%s' "$1" ;;
  esac
}

if [ "$lang" = "th" ]; then
  full_policy="English spine, Thai prose: write prose in Thai; keep titles, headings, labels/enum values, all code + code comments + git commit messages + branch names, and technical/domain/proper-noun terms in English. Code and checked-in repo docs (docs/, README, ADRs, PRD/BRD) stay English."
  brief_policy="write THIS reply's prose in Thai (English spine: headings/labels, code, commit messages/branch names, and technical/domain terms stay English)."
else
  full_policy="Unchanged — respond in English, no localization applied."
  brief_policy="respond in English — no localization applied."
fi

# The case-report exception, appended only when it actually differs from the session language.
# Without this the session directive ("authoritative regardless of the user's input language") and
# a localized case report contradict each other every turn, and the directive wins — the same drift
# the per-turn injection was added to stop. Making the exception part of the injected policy is what
# keeps it mechanical instead of a matter of remembering.
if [ "$case_lang" != "$lang" ]; then
  case_name="$(lang_name "$case_lang")"
  full_policy="$full_policy EXCEPTION — deployed-environment CASE REPORTS: the verdict, evidence and runbook of a live-environment investigation, as relayed in chat, plus the chat message handing it over, are written in $case_name prose with the same English spine (identifiers, amounts, table/column names, code, headings stay English and Arabic numerals). This holds however the report was produced — a spawned investigator agent or answered inline — because it is keyed on the artifact, not the agent. The \`.md\` case file itself stays English, like every other \`.md\`. Tracker tickets stay in the session language."
  brief_policy="$brief_policy EXCEPTION: a deployed-environment case report relayed in chat, and its chat notification, are written in $case_name prose (English spine)."
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
