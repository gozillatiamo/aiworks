#!/usr/bin/env bash
#
# PreToolUse(Write|Edit) hook — the LIVE workspace config carries NO comments.
#
# `workspace.config.yaml` and `workspace.config.local.yaml` are DATA. Every explanation
# belongs in their `*.example.yaml` templates, which is what a new org copies from and where
# `aiworks config`'s drift guard already demands each key be documented. Full rationale:
# docs/adr/0006-config-carries-no-comments.md.
#
# WHY A HOOK AND NOT JUST THE RULE IN CLAUDE.md: the shared config is @-injected into every
# session's context, so a comment written there is re-read on every single turn for the rest of
# the file's life — and commentary is exactly what a model reaches for while editing a config it
# is explaining. This is the same class of rule as the .env guard: cheap to state, easy to
# forget, so it is enforced mechanically.
#
# It fires ONLY on those two basenames. The `*.example.yaml` templates and every other YAML in
# the workspace (mani.d/, .code-workspace, repo configs) are none of this hook's business.
#
# The `#` detection is a real YAML scan, not a grep — `channel: "#dev-oneforbet"` is a value,
# and a guard that called it a comment would block the one edit most likely to be legitimate.
# scripts/lib/yaml_comments.py owns that scanner (and its own --selftest).
#
# Exit 0 = allow. Exit 2 = block, stderr goes back to the model as feedback.
# Fails OPEN whenever it cannot see enough to judge (no jq, no python3, no scanner).

set -uo pipefail

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
scanner="$root/scripts/lib/yaml_comments.py"

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
[ -f "$scanner" ] || exit 0

input=$(cat)
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -n "$path" ] || exit 0

base=$(basename "$path")
case "$base" in
  workspace.config.yaml|workspace.config.local.yaml) ;;
  *) exit 0 ;;
esac

# Write sends the whole file, Edit sends only the replacement text. Either way, what the model
# is about to put IN the file is what gets scanned — an Edit that REMOVES a comment is fine.
text=$(printf '%s' "$input" | jq -r '.tool_input.content // .tool_input.new_string // ""' 2>/dev/null)
[ -n "$text" ] || exit 0

hits=$(printf '%s' "$text" | python3 "$scanner" --check-stdin --label "$base" 2>&1) && exit 0

{
  echo "⛔ Blocked: a YAML comment in $base — the live config carries none."
  echo
  printf '%s\n' "$hits" | head -12
  echo
  echo "The live config is DATA; the explanation goes in the template beside it:"
  case "$base" in
    workspace.config.local.yaml) echo "  workspace.config.local.example.yaml" ;;
    *)                           echo "  workspace.config.example.yaml" ;;
  esac
  echo "and, when it is a measurement or a design decision, in docs/ (docs/agents/*.md,"
  echo "docs/adr/*.md) or the owning script's README — never in the file itself."
  echo
  echo "Why: the shared config is injected into EVERY session's context, so a comment there"
  echo "is paid for on every turn forever, while the template is read once by whoever sets"
  echo "the workspace up. See docs/adr/0006-config-carries-no-comments.md."
  echo
  echo "Re-send this edit with the comment lines dropped. To clean a file that already has"
  echo "them: python3 scripts/lib/yaml_comments.py --write $base"
} >&2
exit 2
