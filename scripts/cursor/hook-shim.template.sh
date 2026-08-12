#!/usr/bin/env bash
#
# hook-shim.sh — run a Claude Code hook under Cursor.
#
# GENERATED FILE — do not edit in place. The single source is
# scripts/cursor/hook-shim.template.sh at the workspace root; `aiworks cursor`
# writes a copy into each repo's .cursor/hooks/ and `aiworks cursor --check`
# compares it back against the template. Edit the template, re-run the
# generator.
#
# WHY A COPY AND NOT A SYMLINK: the .cursor/ layer is committed into each repo
# (so a standalone clone of one repo still works). A symlink from inside a repo
# up to the workspace root escapes the repo boundary and dangles on any clone
# taken without the workspace. Everything else in the Cursor layer IS a symlink;
# this file is the one deliberate exception.
#
# WHAT IT DOES: Cursor and Claude Code speak *almost* the same hook protocol.
# The payloads are near-identical (`tool_name`, `tool_input.file_path`,
# `tool_input.command`, `session_id` all match); only a few things differ. This
# shim translates those few things in both directions so the hooks under
# .claude/hooks/ stay single-source and unmodified, and so a third-party hook
# that only speaks Claude (`sonar hook claude-pre-tool-use`) keeps working too.
#
#   in   Cursor -> Claude   hook_event_name camelCase -> PascalCase
#                           tool_name Shell -> Bash
#                           empty/absent cwd -> workspace_roots[0]
#                           SessionStart gets the `source` field Claude sends
#   out  Claude -> Cursor   {hookSpecificOutput:{additionalContext}}
#                             -> {additional_context}
#                           {decision:"block",reason} / permissionDecision
#                             -> {permission:"deny",agent_message}
#                           {hookSpecificOutput:{updatedInput}} -> {updated_input}
#                             (preToolUse only — beforeShellExecution has no such field)
#                           exit 2 + stderr -> {permission:"deny",agent_message}
#                           plain stdout on UserPromptSubmit -> additional_context
#
# KNOWN GAP: Cursor's postToolUse payload carries no `tool_response`, so a hook
# that inspects the tool's output (posttool-output-warden.sh) sees null and
# degrades to a no-op. Nothing to translate — Cursor simply does not send it.
#
# Usage (from .cursor/hooks.json):
#   {"command": ".cursor/hooks/hook-shim.sh '.claude/hooks/resolve-language.sh'"}
# The argument is a shell command string, so inline pipelines work as well as
# plain script paths.
#
# Exit codes: always 0 on the happy path — a block is expressed as
# {"permission":"deny"} in the JSON, which is the documented way to carry a
# message back to the agent. A shim-level failure is fail-open (exit 0, `{}`),
# matching Cursor's own default for a hook that errors.
set -uo pipefail

cmd="${1:-}"
[[ -z "$cmd" ]] && { echo '{}'; exit 0; }

command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

payload="$(cat)"
[[ -z "$payload" ]] && payload='{}'

# Cursor exports CLAUDE_PROJECT_DIR as an alias for CURSOR_PROJECT_DIR, but be
# defensive: hooks reference "$CLAUDE_PROJECT_DIR" in ~80 places and an unset
# one would silently resolve paths to /.
: "${CLAUDE_PROJECT_DIR:=${CURSOR_PROJECT_DIR:-$PWD}}"
export CLAUDE_PROJECT_DIR

claude_payload="$(printf '%s' "$payload" | jq -c '
  # camelCase Cursor event -> PascalCase Claude event
  ({
    "preToolUse":          "PreToolUse",
    "postToolUse":         "PostToolUse",
    "postToolUseFailure":  "PostToolUse",
    "beforeSubmitPrompt":  "UserPromptSubmit",
    "sessionStart":        "SessionStart",
    "sessionEnd":          "SessionEnd",
    "stop":                "Stop",
    "subagentStop":        "SubagentStop",
    "subagentStart":       "SubagentStart",
    "preCompact":          "PreCompact",
    "beforeShellExecution":"PreToolUse",
    "afterShellExecution": "PostToolUse",
    "beforeReadFile":      "PreToolUse",
    "afterFileEdit":       "PostToolUse"
  }[.hook_event_name // ""] // .hook_event_name) as $event
  | (.workspace_roots // [] | first) as $root
  | .
  | .hook_event_name = $event
  # Cursor names the shell tool "Shell" and the subagent tool "Task"; the guards
  # here match on the Claude names, "Bash" and "Agent". The tool_input payloads are
  # otherwise identical (Task carries description/prompt/subagent_type).
  | (if .tool_name == "Shell" then .tool_name = "Bash"
     elif .tool_name == "Task" then .tool_name = "Agent" else . end)
  # beforeShellExecution carries the command at the top level, not in tool_input.
  | (if (.command? // null) != null and (.tool_input? // null) == null
     then .tool_name = "Bash" | .tool_input = {command: .command, cwd: (.cwd // "")}
     else . end)
  # cwd is sometimes present-but-empty; Claude hooks treat it as authoritative.
  | (if (.cwd // "") == "" then .cwd = ($root // env.CLAUDE_PROJECT_DIR // "") else . end)
  | (if (.session_id // "") == "" then .session_id = (.conversation_id // "") else . end)
  # Claude sends `source` on SessionStart; resolve-language.sh tolerates its
  # absence but repo-health-check.sh reads it.
  | (if $event == "SessionStart" and (.source? // null) == null
     then .source = (if (.is_background_agent // false) then "background" else "startup" end)
     else . end)
')" || claude_payload="$payload"

stderr_file="$(mktemp -t cursor-hook-shim)"
stdout_raw="$(printf '%s' "$claude_payload" | bash -c "$cmd" 2>"$stderr_file")"
rc=$?
stderr_raw="$(cat "$stderr_file")"
rm -f "$stderr_file"

# exit 2 is "block" in BOTH protocols, but the reason travels differently:
# Claude reads stderr, Cursor reads agent_message. Carry it across, and return 0
# so Cursor honours the JSON rather than falling back to a bare block.
if [[ $rc -eq 2 ]]; then
  # Both spellings: the docs use snake_case, parts of Cursor's own config are
  # camelCase, and a key it does not recognise is simply ignored. A block whose
  # reason never reaches the agent just makes it retry the same thing blindly, so
  # it is worth sending twice.
  jq -nc --arg msg "${stderr_raw:-Blocked by a workspace guard hook.}" \
    '{permission:"deny", agent_message:$msg, user_message:$msg,
      agentMessage:$msg, userMessage:$msg}'
  exit 0
fi

# Any other non-zero exit is a hook failure. Claude and Cursor both fail open.
if [[ $rc -ne 0 ]]; then
  echo '{}'
  exit 0
fi

event_name="$(printf '%s' "$payload" | jq -r '.hook_event_name // ""')"

if printf '%s' "$stdout_raw" | jq -e . >/dev/null 2>&1; then
  printf '%s' "$stdout_raw" | jq -c '
    (.hookSpecificOutput.additionalContext // .additionalContext // null) as $ctx
    | (.hookSpecificOutput.permissionDecision // .permissionDecision // null) as $perm
    | (.hookSpecificOutput.permissionDecisionReason // .permissionDecisionReason
       // .reason // null) as $why
    | (.hookSpecificOutput.updatedInput // .updatedInput // null) as $upd
    | (if .decision == "block" then "deny" else null end) as $blocked
    | {}
    | (if $ctx  != null then .additional_context = $ctx else . end)
    # A rewritten tool input. Cursor spells it `updated_input` and honours it on
    # preToolUse only — beforeShellExecution has no such field, so a hook that
    # rewrites a command must be wired through preToolUse (which is what
    # `aiworks cursor` generates) or the rewrite is silently dropped.
    | (if $upd != null then .updated_input = $upd else . end)
    | (if $blocked != null then .permission = "deny"
       elif $perm == "allow" then .permission = "allow"
       elif $perm == "deny"  then .permission = "deny"
       elif $perm == "ask"   then .permission = "ask"
       else . end)
    | (if $why != null and (.permission? // "") != "" then .agent_message = $why else . end)
  '
  exit 0
fi

# Non-JSON stdout. Claude injects a UserPromptSubmit hook's plain stdout as
# context; every other event ignores it.
if [[ -n "$stdout_raw" && ( "$event_name" == "beforeSubmitPrompt" || "$event_name" == "sessionStart" ) ]]; then
  jq -nc --arg ctx "$stdout_raw" '{additional_context:$ctx}'
else
  echo '{}'
fi
exit 0
