#!/usr/bin/env bash
#
# PreToolUse(Bash) hook — steer noisy Flutter/Dart builds to scripts/dev.sh.
#
# Blocks a RAW build command (flutter test|analyze|clean, or `dart run build_runner
# build`) when it is NEITHER routed through scripts/dev.sh NOR redirected to a file —
# those dump full verbose output straight into the agent's context window. The hook
# points the agent at the wrapper instead, which logs the output and prints a one-liner.
#
# Intentionally NOT blocked:
#   - scripts/dev.sh ...            (the wrapper itself; its internal `flutter` call is a
#                                     subprocess and never reaches this hook)
#   - flutter run / dart run build_runner watch / flutter build / pub ...  (not wrapped)
#   - a build whose output is redirected to a file (agent is capturing it deliberately)
#
# Exit 0 = allow. Exit 2 = block, stderr is shown to the model as actionable feedback.

set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# Already using the wrapper — always fine.
case "$cmd" in
  *scripts/dev.sh*) exit 0 ;;
esac

# Is this one of the noisy, wrapped build commands, run raw?
noisy=0
printf '%s' "$cmd" | grep -qE '(^|[[:space:];&|])flutter[[:space:]]+(test|analyze|clean)([[:space:];&|]|$)' && noisy=1
printf '%s' "$cmd" | grep -qE '(^|[[:space:];&|])dart[[:space:]]+run[[:space:]]+build_runner[[:space:]]+build' && noisy=1
[ "$noisy" -eq 0 ] && exit 0

# Allow if output is redirected to a FILE (`> f` / `>> f`), not merely `2>&1`.
if printf '%s' "$cmd" | grep -qE '>>?[[:space:]]*[^[:space:]&]'; then
  exit 0
fi

# Block with guidance — stderr is fed back to the model.
{
  echo "⛔ Blocked raw build: $cmd"
  echo
  echo "Run builds through the wrapper so the verbose output is logged to"
  echo "agent_logs/executed_verbose/ instead of flooding your context:"
  echo "  scripts/dev.sh test | gen | analyze | clean"
  echo "Then inspect with:"
  echo "  scripts/dev.sh why <name>     # only the failure lines"
  echo "  scripts/dev.sh status [name]  # the recorded one-line summary"
  echo
  echo "(The developer owns builds; the code-reviewer runs the suite too — its approval is"
  echo " gated on a green run — and both go through the wrapper. Other roles read results"
  echo " via status/why."
  echo " If you truly need raw output, redirect it to a file: $cmd > /tmp/out.log 2>&1)"
} >&2
exit 2
