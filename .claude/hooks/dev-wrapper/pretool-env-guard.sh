#!/usr/bin/env bash
#
# PreToolUse(Read|Bash) hook — block reads/dumps of secret .env files.
#
# CLAUDE.md rule: never Read/cat/grep/trace-dump .env or .env.* — only
# .env.example templates are safe. Real incident: `bash -x` on a script that
# sources an adapter .env printed a real secret value into the transcript
# and an on-disk tool-result file — deleting the file after the fact did not
# undo the transcript leak. This hook is the enforcement backstop so it
# can't happen again regardless of what the model remembers.
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
    echo "(Real incident: bash -x on a script sourcing .env leaked a real secret value into the transcript.)"
    echo "To check a var is merely set without exposing it: grep -q '^VAR=.\\+' .env"
    echo "To debug a script that sources .env: add temporary non-secret echo markers, not bash -x/set -x."
  } >&2
  exit 2
}

# Regex fragment: a .env or .env.<suffix> filename token (word-bounded).
ENV_TOKEN='\.env(\.[A-Za-z0-9_.-]*)?\b'

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

    # ---------------------------------------------------------------------
    # Rule 1 — a command that prints a .env file's *contents*.
    #
    # Checked PER shell segment (split on ; | & and newlines) so a safe
    # `grep -q` existence-check in one segment is not tarred by an unsafe
    # command in another. .env is matched RAW (not de-quoted): a quoted
    # `.env` is still a real filename argument, so de-quoting here would
    # open an evasion hole — over-blocking a quoted mention is fail-safe.
    # ---------------------------------------------------------------------
    while IFS= read -r seg; do
      [ -z "$seg" ] && continue
      # segment must name a .env; a .env.example segment is a safe template.
      printf '%s' "$seg" | grep -Eq "$ENV_TOKEN" || continue
      printf '%s' "$seg" | grep -Eq '\.env\.example\b' && continue

      # cat/head/tail/less/more/sed -n always print file contents.
      if printf '%s' "$seg" | grep -Eq "\\b(cat|head|tail|less|more|sed[[:space:]]+-n)\\b[^|;&]*$ENV_TOKEN"; then
        deny "command dumps a .env file: $cmd"
      fi
      # rtk renames the reading verbs, and a renamed verb dumps just the same.
      # This is not hypothetical: the rtk PreToolUse hook rewrites `cat X` into
      # `rtk read X`, so `rtk read` is a shape the model sees in its own
      # transcript all day and will type directly — at which point none of the
      # verbs above match and the file goes to the transcript in full.
      # Measured against a throwaway key=value file: `rtk read` and `rtk pipe`
      # print it verbatim, `rtk diff` prints every changed line with its value.
      # (`rtk smart`/`rtk log`/`rtk wc` emit only a summary and `rtk ls|tree|find`
      # list names, so they stay allowed.) The verb is anchored to `rtk` on
      # purpose: bare `read` and `diff` are far too ordinary to block on sight.
      if printf '%s' "$seg" | grep -Eq "\\brtk\\b([[:space:]]+-[^[:space:]]+)*[[:space:]]+(read|pipe|diff)\\b[^|;&]*$ENV_TOKEN"; then
        deny "rtk would print .env contents: $cmd"
      fi
      # grep prints matching lines (leaks values) UNLESS it is quiet:
      # -q/--quiet/--silent only sets the exit code, printing nothing —
      # that is the sanctioned "is this var set?" idiom, so allow it.
      if printf '%s' "$seg" | grep -Eq "\\bgrep\\b[^|;&]*$ENV_TOKEN"; then
        if ! printf '%s' "$seg" | grep -Eq '(^|[[:space:]])-[A-Za-z]*q[A-Za-z]*\b|--quiet\b|--silent\b'; then
          deny "grep would print .env contents: $cmd"
        fi
      fi
    done <<< "$(printf '%s' "$cmd" | tr ';|&' $'\n\n\n')"

    # ---------------------------------------------------------------------
    # Rule 2 — shell trace mode (bash -x / sh -x / set -x) near a scripts/
    # path. Every adapter (vcs/tracker/notify) sources a .env from
    # scripts/*/, and xtrace echoes every sourced variable VALUE straight
    # to the transcript.
    #
    # Quoted substrings are stripped BEFORE looking for the trace token: a
    # `bash -x` inside a string literal is inert data (echo/printf/comment)
    # and cannot activate tracing, so removing quotes kills that false
    # positive with no false negative. The scripts/ path is matched on the
    # ORIGINAL command, so a quoted script path (bash -x "scripts/x.sh")
    # still trips the guard.
    # ---------------------------------------------------------------------
    stripped=$(printf '%s' "$cmd" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')
    TRACE_RE='(^|[[:space:];&|(/])(bash|sh)[[:space:]]+(-[A-Za-z]*x[A-Za-z]*|--?xtrace)\b|(^|[[:space:];&|(])set[[:space:]]+(-[A-Za-z]*x[A-Za-z]*\b|-o[[:space:]]+xtrace\b)'
    if printf '%s' "$stripped" | grep -Eq "$TRACE_RE" \
       && printf '%s' "$cmd" | grep -Eq 'scripts/'; then
      deny "trace mode (-x) near a scripts/ path may echo a sourced .env value: $cmd"
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
