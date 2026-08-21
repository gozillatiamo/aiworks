#!/usr/bin/env bash
#
# PreToolUse(Bash) hook — block a relative `cd` at the START of a command.
#
# A leading `cd your-app` is unsafe REGARDLESS of whether the Bash tool's cwd
# carries forward to the next call: where it does, a second identical `cd your-app`
# resolves against the already-moved cwd (`your-app/your-app`) and dies with "no
# such file or directory"; where it does not (measured true for at least one
# spawned-agent context in this workspace — cwd resets, it does not carry), a
# relative cd is unpredictable from the start, for the same underlying reason a
# relative `-p`/`-C` is (see pretool-codegraph-guard.sh). In this multi-repo
# workspace that has bitten real review/agent runs more than once — so we forbid
# the pattern and steer to absolute paths, which are correct in both cases.
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
  echo "A leading relative cd is unsafe whether or not the Bash tool's cwd"
  echo "carries forward to the next call — it either breaks the next identical"
  echo "cd (already-moved cwd) or resolves against an unpredictable one (some"
  echo "contexts reset cwd between calls entirely)."
  echo "Use one of these instead:"
  echo "  • an ABSOLUTE path:   cd /Users/.../<workspace>/<repo> && …"
  echo "  • git, scoped:        git -C /abs/path <git-subcommand>"
  echo "  • a subshell:         ( cd /abs/path && … )   # leaves the persisted cwd clean"
} >&2
exit 2
