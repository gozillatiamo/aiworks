#!/usr/bin/env bash
#
# PreToolUse(Bash) hook — block a relative `cd` at the START of a command.
#
# The Bash tool's working directory PERSISTS between calls. A leading
# `cd your-app` works the first time, but the next tool call starts
# *inside* that repo, so the same relative cd resolves against the moved cwd
# (`your-app/your-app`) and dies with "no such file or
# directory". In this multi-repo workspace that has bitten real review/agent
# runs more than once — so we forbid the pattern and steer to absolute paths.
#
# Only the LEADING cd is guarded. A mid-chain `… && cd sub && …` runs from a
# cwd established earlier in the SAME command, so it is deterministic and fine.
#
# Allowed (exit 0): cd /abs · cd ~/x · cd "$VAR/x" · cd $HOME · cd -
#                   bare `cd` (→ home) · any command not starting with cd
# Blocked (exit 2): cd your-app · cd ./x · cd ../x · cd foo/bar
#
# Exit 0 = allow. Exit 2 = block, stderr is shown to the model as feedback.

set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# Strip leading whitespace.
trimmed="${cmd#"${cmd%%[![:space:]]*}"}"

# Only inspect commands that START with `cd <arg>`. A bare `cd` (→ home) or
# anything else is allowed.
case "$trimmed" in
  cd[[:space:]]*) ;;
  *) exit 0 ;;
esac

# Isolate cd's first argument, then strip one leading quote.
rest=${trimmed#cd}
rest="${rest#"${rest%%[![:space:]]*}"}"
case "$rest" in
  \"*|\'*) rest=${rest#?} ;;
esac
first=${rest%"${rest#?}"}

# Absolute / home / variable-based / `cd -` (or other -flag) / empty → fine.
case "$first" in
  /|'~'|'$'|-|'') exit 0 ;;
esac

# Relative path → block with guidance.
{
  echo "⛔ Blocked relative cd: $cmd"
  echo
  echo "The Bash tool's cwd PERSISTS across calls, so a leading relative cd"
  echo "breaks on the next call (it resolves against the already-moved cwd)."
  echo "Use one of these instead:"
  echo "  • an ABSOLUTE path:   cd /Users/.../<workspace>/<repo> && …"
  echo "  • git, scoped:        git -C /abs/path <git-subcommand>"
  echo "  • a subshell:         ( cd /abs/path && … )   # leaves the persisted cwd clean"
} >&2
exit 2
