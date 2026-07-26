#!/usr/bin/env bash
#
# PreToolUse(Bash) hook — make `codegraph` address the right repo, from anywhere.
#
# codegraph is a PER-REPO index. In this multi-repo workspace the workspace root
# has no index of its own, so a bare `codegraph explore X` run from the root
# fails — and its error politely tells the agent to fall back to its usual tools,
# which means grep. The whole point of the index is lost, silently.
#
# Every query subcommand takes `-p/--path`, so no `cd` is needed. But a RELATIVE
# `-p` is only correct when the cwd happens to be the workspace root, and the
# Bash tool's cwd PERSISTS across calls — an agent thirty calls into a run can be
# anywhere. That combination produces the worst failure this hook exists to stop:
#
#   cwd = <ws>/game
#   $ codegraph explore 'GameServicePort' -p backoffice
#   Found 15 symbols across 1 file.        <- game's index. exit 0.
#
# `game/backoffice` does not exist, so codegraph walks UP to the nearest index —
# `game/` — and answers confidently from the wrong repo, with a zero exit code.
# Nothing downstream can detect that. (A path with no index at or above it does
# exit 1; it is specifically the wrong-but-relative path that fails silently.)
#
# So: rewrite every `-p <repo-name>` to an ABSOLUTE path. That is a lookup, not a
# guess — the candidates are the directories under the workspace root that carry
# a .codegraph/ index, and their names are unique. cwd stops mattering.
#
# Also rewritten: `codegraph search` -> `codegraph query`. The CLI has no `search`
# subcommand (that is the MCP tool's name) and exits 1 on it; `query` is the same
# operation. `explore` and `node` DO exist as of CLI 1.5.0 and are left alone.
#
# Blocked, because it cannot be resolved without guessing: a query subcommand with
# no `-p` at all, run from outside any indexed repo. The block lists the repos.
#
# Exit 0 = allow (optionally with a rewritten command). Exit 2 = block, stderr is
# shown to the model.

set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# Cheap reject first — this hook runs on every Bash call.
case "$cmd" in *codegraph*) ;; *) exit 0 ;; esac

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$cwd" ] || cwd="$(pwd)"

# `codegraph` must appear as a command word, not inside a path or a string that
# merely mentions it (a grep for the word, a comment, a doc edit).
printf '%s' "$cmd" | grep -qE '(^|[;&|(]|&&|\|\|)[[:space:]]*codegraph[[:space:]]' || exit 0

# Subcommands that read the index and therefore need a project. `sync` is left out
# on purpose: the PostToolUse sync hook passes an absolute path already, and a
# hand-run `codegraph sync` from inside a repo is a legitimate no-arg use.
QUERY_SUBS='query|explore|node|callers|callees|impact|affected|files|status'

sub=$(printf '%s' "$cmd" | awk '
  { for (i = 1; i <= NF; i++) if ($i == "codegraph") { print $(i+1); exit } }')
[ -n "$sub" ] || exit 0

# `search` is the MCP tool name; the CLI calls it `query` and exits 1 otherwise.
newsub="$sub"
[ "$sub" = "search" ] && newsub="query"

printf '%s' "$newsub" | grep -qE "^($QUERY_SUBS)$" || exit 0

# An indexed repo is a directory under the workspace root holding a real index.
# The marker is the DATABASE, not the directory: `~/.codegraph/` is codegraph's own
# installation directory (versions/, telemetry-queue.jsonl), and testing for the
# directory alone made every path look indexed once the walk below reached $HOME.
indexed() { [ -f "$1/.codegraph/codegraph.db" ]; }

repos=""
for d in "$ROOT"/*/; do
  indexed "${d%/}" || continue
  repos="${repos:+$repos }$(basename "$d")"
done

# Is the cwd already inside an indexed project? Then a bare call resolves correctly
# on its own and we leave it alone. The walk stops at the workspace root — an index
# above it belongs to some other project and must never satisfy this check.
cwd_ok=0
p="$cwd"
case "$p" in
  "$ROOT"|"$ROOT"/*)
    while [ -n "$p" ] && [ "$p" != "/" ]; do
      indexed "$p" && { cwd_ok=1; break; }
      [ "$p" = "$ROOT" ] && break
      p="$(dirname "$p")"
    done
    ;;
esac

# Pull out the -p/--path operand, in either the separated or the `=` form.
pval=$(printf '%s' "$cmd" | awk '
  {
    for (i = 1; i <= NF; i++) {
      if ($i == "-p" || $i == "--path") { print $(i+1); exit }
      if ($i ~ /^--path=/) { v = $i; sub(/^--path=/, "", v); print v; exit }
      if ($i ~ /^-p=/)     { v = $i; sub(/^-p=/, "", v);     print v; exit }
    }
  }')

# Strip one layer of quoting so a quoted repo name still resolves.
bare="$pval"
case "$bare" in \"*\"|\'*\') bare="${bare#?}"; bare="${bare%?}" ;; esac

block() {
  {
    echo "⛔ codegraph $newsub needs an explicit project: $cmd"
    echo
    echo "codegraph indexes ONE repo at a time and the workspace root has no index."
    echo "Pass the repo as an ABSOLUTE path — the Bash cwd persists between calls, so"
    echo "a relative -p silently resolves against whatever directory you are in and"
    echo "codegraph then answers from the WRONG repo with exit 0."
    echo
    echo "  codegraph $newsub <args> -p \$CLAUDE_PROJECT_DIR/<repo>"
    echo
    echo "Indexed repos: $repos"
  } >&2
  exit 2
}

emit() { # emit <new-command>
  jq -nc --arg c "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", updatedInput:{command:$c}}}'
  exit 0
}

# Nothing to fix.
if [ "$newsub" = "$sub" ]; then
  case "$bare" in
    /*|'~'*|'$'*) exit 0 ;;                    # already absolute (or a variable)
    '') [ "$cwd_ok" -eq 1 ] && exit 0; block ;;  # no -p at all
  esac
fi

# A rewrite is needed. Multi-line commands (heredocs, embedded newlines) are not
# safe to reassemble token-wise, so tell the agent instead of mangling the command.
case "$cmd" in *$'\n'*) block ;; esac

target=""
if [ -n "$bare" ]; then
  case "$bare" in
    /*|'~'*|'$'*) target="" ;;                 # leave an absolute path alone
    *)
      # Resolve by NAME against the indexed repos — a lookup, not an inference.
      name="${bare%%/*}"
      for r in $repos; do [ "$r" = "$name" ] && target="$ROOT/$bare"; done
      # A relative path that names no repo is unresolvable; blocking beats guessing.
      [ -n "$target" ] || block
      ;;
  esac
elif [ "$cwd_ok" -eq 0 ]; then
  block
fi

# Reassemble: swap the subcommand token and/or the -p operand, leave the rest as
# written. Runs of whitespace collapse to single spaces, which is inert for a shell
# command and keeps quoted arguments intact (their quotes travel with the tokens).
out=$(printf '%s' "$cmd" | awk -v want="$sub" -v newsub="$newsub" -v tgt="$target" '
  {
    seen = 0
    for (i = 1; i <= NF; i++) {
      t = $i
      if (!seen && t == "codegraph") { seen = 1 }
      else if (seen == 1 && t == want) { t = newsub; seen = 2 }
      else if (tgt != "" && ($i == "-p" || $i == "--path")) { out = out sep t; sep = " "; i++; t = tgt }
      else if (tgt != "" && $i ~ /^--path=/) { t = "--path=" tgt }
      else if (tgt != "" && $i ~ /^-p=/)     { t = "-p=" tgt }
      out = out sep t; sep = " "
    }
    print out
  }')

[ -n "$out" ] && [ "$out" != "$cmd" ] && emit "$out"
exit 0
