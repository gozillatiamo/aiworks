#!/usr/bin/env bash
# PreToolUse(Bash) hook — stop `hrun` from being piped, redirected or substituted.
#
# WHY THIS EXISTS. `hrun` prints a RENDERING, not a data stream: above its threshold the output
# carries hcat's receipt header and may be a compressed body. Measured: `hrun cat t.json > y.json`
# produces a y.json that no JSON parser accepts. The corruption is silent — the command succeeds,
# the file exists, and the damage surfaces later somewhere else.
#
# `hrun` cannot refuse this itself. The obvious test — "am I writing to a terminal?" — is useless
# under the Bash tool, where stdout is never a TTY whether the output is about to be read or about
# to be swallowed by a redirect. The shape is only visible in the command string, which is here.
#
# This is the same failure the adapter pipe guard exists for, and it is deliberately the same
# shape of answer: the WHOLE command string is what decides, and the fix is always to run it bare.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool" = "Bash" ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# hrun must be CALLED, not merely mentioned. `\bhrun\b` is not enough: it matches inside
# `pretool-hrun-pipe-guard.sh`, so a `grep hrun-pipe-guard … | head` — or an `ls` of this very
# file — got blocked for "piping hrun". That false positive fired on the first real command after
# the guard was written. Command position is the whole test: start of a shell segment, after any
# VAR=value prefixes, followed by whitespace (so the hyphen in a filename never qualifies).
# ⚠️ BACKTICKS ARE DELIBERATELY NOT A SEPARATOR, and backtick substitution is deliberately not
# detected. Both were, briefly — and the guard then blocked its own commit, because the message
# quoted `hrun cat x.json > y.json` in backticks to explain the hazard. Prose about this verb is
# far more common than legacy backtick substitution of it (every doc, commit and MR body that
# mentions it), and a guard that blocks writing ABOUT a tool gets switched off. The modern $( )
# form is still caught below; `X=`hrun f`` is the accepted miss.
#
# The optional PATH PREFIX is load-bearing, not defensive: hrun ships at scripts/hrun and is
# documented to be called that way, so a bare-name-only rule left the guard inert on every real
# invocation — caught by piping `scripts/hrun` in this hook's own end-to-end test. The prefix must
# end in `/`, which is what keeps `pretool-hrun-pipe-guard.sh` out: there the token after the last
# slash is `pretool-hrun…`, not `hrun`.
INVOKE='(^|[;&|(]|&&|\|\|)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([A-Za-z0-9_.-]*/)*hrun[[:space:]]'
printf '%s' "$cmd" | grep -Eq "$INVOKE" || exit 0

# Deliberate one-off (piping a KNOWN-small hrun output) stays possible, the same way the size
# guard leaves HCAT_MAX_BYTES. It must be read off the COMMAND STRING, not the environment: a
# `VAR=1 cmd` prefix sets the variable for the command, never for this hook, so an env-only check
# would document an escape hatch that does not exist.
printf '%s' "$cmd" | grep -Eq '\bHRUN_ALLOW_PIPE=' && exit 0
[ -n "${HRUN_ALLOW_PIPE:-}" ] && exit 0

reason=""
# 1. command substitution — the output becomes a value, which is the worst case: a receipt header
#    silently becomes part of a variable, a filename, or an argument.
if printf '%s' "$cmd" | grep -Eq '\$\([[:space:]]*([A-Za-z0-9_.-]*/)*hrun[[:space:]]'; then
  reason="captured in a command substitution"
# 2. a pipe FED BY hrun. `something | hrun cmd` is fine — that is stdin going INTO the command,
#    which passes through untouched; it is hrun's own stdout that must not be consumed. So the
#    pipe has to come AFTER the invocation, not before it.
elif printf '%s' "$cmd" | grep -Eq "$INVOKE[^|]*\|"; then
  reason="piped into another command"
# 3. stdout redirect. `2>` and friends are left alone: hrun already merges stderr into stdout, so
#    a numbered redirect changes nothing and denying it would be a false positive.
elif printf '%s' "$cmd" | grep -Eq "$INVOKE[^|;&]*[^0-9&>]>"; then
  reason="redirected to a file"
fi

[ -n "$reason" ] || exit 0

{
  echo "⛔ Blocked: hrun's output is $reason"
  echo
  echo "hrun prints a RENDERING for a reader, not data. Above its size threshold the output"
  echo "carries hcat's receipt header and may be a compressed body, so anything that consumes it"
  echo "gets silent garbage — measured: 'hrun cat x.json > y.json' yields a y.json no parser"
  echo "accepts, with no error at the time."
  echo
  echo "Run it bare and read the result:  hrun <command> [args…]"
  echo
  echo "If you want the DATA, do not involve hrun — run the command itself and redirect that"
  echo "(<command> > out.json), then hcat/Read the file when you need to look at it."
  echo "(Deliberate one-off on output you know is small: HRUN_ALLOW_PIPE=1 hrun …)"
} >&2
exit 2
