#!/usr/bin/env bash
#
# PreToolUse(Bash) hook — stop `hcat` on a file too large to be worth ingesting.
#
# MEASURED, on a load-test log (262,006,925 bytes): headroom's safety gate
# decided compression would save 0.0% and did the documented thing — passed the content through
# unchanged. hcat then printed all 262 MB to stdout, in 80 seconds. The headroom plugin's own
# gate has a floor (HCAT_GATE_BYTES) but no CEILING, so a `cat <huge>.log` is rewritten straight
# into that, and the tool meant to protect the context window produces the flood instead.
#
# Compression ratio is not the whole story either: graphify-out/graph.json is 767 KB and
# compresses 56.1%, which is still ~92,000 tokens of output. Above a couple of megabytes the
# right move is never "compress it and read it" — it is dangi's own advice for the huge case:
# spawn a disposable subagent that reads the file and returns conclusions, so the bytes never
# reach this context at any ratio.
#
# Scope is `hcat` only — the verb this workspace introduced. A bare `cat` of a huge file is
# pre-existing behaviour that posttool-output-warden.sh already reports on.
#
# Exit 0 = allow. Exit 2 = block, stderr is shown to the model as feedback.

set -uo pipefail

# Above this many bytes, hcat is the wrong tool no matter how well the file compresses.
MAX_BYTES="${HCAT_MAX_BYTES:-2097152}"   # 2 MiB

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool" = "Bash" ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -n "$cmd" ] || exit 0
case "$cmd" in *hcat*) ;; *) exit 0 ;; esac

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)

# Per shell segment, so `something && hcat big.json` is still caught. hcat takes exactly one
# file argument and no flags, so the operand is whatever follows the verb; quotes are stripped
# for the stat, never re-used to build a command.
while IFS= read -r seg; do
  [ -z "$seg" ] && continue
  path=$(printf '%s' "$seg" | sed -nE 's/^[[:space:]]*(.*[[:space:]])?hcat[[:space:]]+(.*)$/\2/p')
  [ -n "$path" ] || continue
  # strip surrounding quotes and any trailing operand noise
  path=$(printf '%s' "$path" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                                    -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")
  [ -n "$path" ] || continue
  case "$path" in
    /*) ;;
    *)  [ -n "$cwd" ] && path="$cwd/$path" ;;
  esac
  [ -f "$path" ] || continue

  size=$(wc -c < "$path" 2>/dev/null | tr -d ' ')
  case "$size" in ''|*[!0-9]*) continue ;; esac
  [ "$size" -ge "$MAX_BYTES" ] || continue

  mb=$(( size / 1048576 ))
  {
    echo "⛔ Blocked: hcat on a ${mb} MB file ($path)"
    echo
    echo "hcat has no upper bound: when headroom's safety gate decides compression would not help,"
    echo "it passes the content through UNCHANGED — so hcat would print the whole file. Measured:"
    echo "a 250 MB .log took 80s and emitted 262 MB. Even a good ratio does not save a file this"
    echo "big (767 KB of JSON at 56% is still ~92k tokens)."
    echo
    echo "Read the file inside a disposable subagent (Agent tool) and have it return only the"
    echo "conclusions — the bytes never enter this context at any ratio. For a targeted look,"
    echo "Read the path with offset/limit, or grep/head/tail/jq for the specific lines you want."
    echo "(Deliberate one-off on a file you know compresses: HCAT_MAX_BYTES=<bytes> hcat <file>.)"
  } >&2
  exit 2
done <<< "$(printf '%s' "$cmd" | tr ';|&' $'\n\n\n')"

exit 0
