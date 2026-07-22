#!/usr/bin/env bash
#
# PreToolUse(Read|Bash) hook — block reads/dumps of secret .env files.
#
# CLAUDE.md rule: never Read/cat/grep/trace-dump .env or .env.* — only
# .env.example templates are safe. Real incident: `bash -x get-trace.sh`
# (sources scripts/observability/.env) printed the real SIGNOZ_API_KEY into
# the transcript and an on-disk tool-result file — deleting the file after
# the fact did not undo the transcript leak. This hook is the enforcement
# backstop so it can't happen again regardless of what the model remembers.
#
# Exit 0 = allow. Exit 2 = block, stderr is shown to the model as feedback.

set -uo pipefail

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)

is_env_path() {
  # $1 = path/string to test. True (0) if it looks like a real secret .env
  # file (.env or .env.<suffix>) and NOT .env.example.
  case "$1" in
    *.env.example) return 1 ;;
    *.env|*.env.*) return 0 ;;
  esac
  return 1
}

deny() {
  {
    echo "⛔ Blocked: $1"
    echo
    echo "CLAUDE.md rule: never read/cat/grep/trace-dump .env or .env.* — only .env.example is safe."
    echo "(Real incident: bash -x on a script sourcing .env leaked SIGNOZ_API_KEY into the transcript.)"
    echo "To check a var is merely set without exposing it: grep -q '^VAR=.\\+' .env"
    echo "To debug a script that sources .env: add temporary non-secret echo markers, not bash -x/set -x."
  } >&2
  exit 2
}

case "$tool" in
  Read)
    path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
    [ -z "$path" ] && exit 0
    is_env_path "$path" && deny "Read of secret env file: $path"
    exit 0
    ;;
  Bash)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
    [ -z "$cmd" ] && exit 0

    # 1) direct dump/print of a .env file via cat/head/tail/less/more/grep/sed -n
    if printf '%s' "$cmd" | grep -Eq '\b(cat|head|tail|less|more|grep|sed[[:space:]]+-n)\b[^|;&]*\.env(\.[A-Za-z0-9_.-]*)?\b' \
       && ! printf '%s' "$cmd" | grep -Eq '\.env\.example\b'; then
      deny "command dumps a .env file: $cmd"
    fi

    # 2) trace mode (bash -x / sh -x / set -x) near a scripts/ path — every
    # adapter (vcs/tracker/notify/observability) sources a .env from there,
    # and xtrace prints every sourced variable value straight to the transcript.
    if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])(bash|sh)[[:space:]]+(-[A-Za-z]*x[A-Za-z]*|--?xtrace)\b|set[[:space:]]+-x\b' \
       && printf '%s' "$cmd" | grep -Eq 'scripts/'; then
      deny "trace mode (-x) near a scripts/ path may echo a sourced .env value: $cmd"
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
