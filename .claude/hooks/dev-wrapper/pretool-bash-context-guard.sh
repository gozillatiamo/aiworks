#!/usr/bin/env bash
#
# PreToolUse(Bash) hook — the three Bash shapes that cost the most CONTEXT, blocked BEFORE
# they spend it.
#
# WHY A *PRE* HOOK. `posttool-output-warden.sh` already reports an oversized result, and it
# says so itself: "PostToolUse can't shrink output already received." Measured over one real
# session (~290k tokens of messages): that warden fired 13 times and changed nothing,
# because by the time it speaks the bytes are already in the window. Over the same session the
# BLOCKING guards (pretool-adapter-pipe-guard) fired 3 times and were obeyed 3 times. Same
# information, opposite timing, opposite outcome — so the fix is a block, not a louder nudge.
#
# That session's message body measured ~52% tool RESULTS and ~38% tool CALL payloads. Rule 1
# addresses the first, rule 2 the second. Nothing else in this workspace governs either: the
# existing pre-guard covers `hcat`, the one reader that was already safe.
#
# RULE 1 — an UNBOUNDED read of a big file.
#   `cat <8KB+ file>` puts the whole thing in the window. The single biggest block in that
#   session was one `cat` of a 25.6 KB SKILL.md: ~7,000 tokens in one call. This blocks only
#   what is statically knowable — the file exists, its size is measurable, and the command
#   asked for all of it. It deliberately does NOT try to predict `grep` output, which depends
#   on the matches.
#
# RULE 2 — a read-modify-write PATCH of an existing file through a heredoc.
#   `python3 - <<'PY' … open(p).read() … open(p,'w').write(s) … PY` ships the old text AND the
#   new text as part of the command, re-transmitting content already in the window, and then
#   earns a second cost: the harness echoes an `edited_text_file` diff back because the write
#   happened outside the tracked Edit path (16.2k tokens over 7 such echoes that session).
#   `Edit` sends old_string/new_string only and triggers no echo.
#
#   ⚠️ This rule knowingly contradicts the auto-mode preference for making file changes with
#   "sed, heredocs, or short scripts, rather than using the dedicated Read, Edit, or Write
#   tools". That preference is about permission friction; this is about context cost, and for
#   this ONE shape the cost is measured and large. Every other Bash edit — a fresh file, a
#   computed file, sed in place, a small patch — is still allowed. Set
#   BASH_PATCH_GUARD=0 to disable this rule alone if the trade is not worth it for you.
#
# RULE 3 — a POLL LOOP: the same file probe, over and over, while something else runs.
#   Rules 1 and 2 both price a SINGLE call — how many bytes its result lands, how many its
#   payload carries. Rule 3 prices the call that costs nothing by either measure and is still
#   the most expensive thing in the transcript, because the unit is the TURN: every request
#   re-sends the whole window, so a probe returning `112` against a 490k-token context bills
#   490k tokens to learn one number you already knew.
#
#   Measured, one developer subagent on a Rust backend repo (2026-08-27): 907 tool calls, 806
#   of them foreground Bash, and ONE command —
#   `grep -c " ok$" agent_logs/executed_verbose/test-<ts>.log` — repeated 95 times verbatim,
#   in unbroken runs of ~20 back to back with no other tool call between them. Thirteen of
#   those consecutive probes returned the identical count. Add its siblings on the same log
#   (`grep -c "\.\.\. FAILED"`, `tail -5`, `wc -l`) and ~400 of the 806 calls are one spin
#   loop waiting on a `dev.sh test` run. Session total: 1409 turns, 690M cache-read tokens,
#   ~$30 — against 216k output tokens. Every other agent in the same workflow run finished
#   in 74–136 tool calls.
#
#   The remedy was already in hand and simply unknown: `run_in_background` is a parameter of
#   the Bash tool the agent already had, and the harness re-invokes you when the command
#   exits. One call that ENDS when the condition is true costs one turn instead of four
#   hundred. Monitor is the other half of the same answer, for a stream of events rather than
#   a single "it finished" — but for "tell me when the suite is done", background Bash is it.
#
#   Scope is deliberately narrow: only a read-only FILE PROBE, only the identical command
#   text, only within a rolling window. A legitimate investigation greps one file with
#   DIFFERENT patterns; re-running one byte-identical probe six times in five minutes is a
#   spin loop or it is nothing. BASH_POLL_GUARD=0 disables just this rule.
#
# Exit 0 = allow. Exit 2 = block, stderr is shown to the model as feedback.

set -uo pipefail

# Rule 1: a file this big is not worth reading whole into the window. 8 KiB ~ 2.3k tokens, and
# twice the threshold the headroom warden already considers worth complaining about.
MAX_BYTES="${BASH_READ_MAX_BYTES:-8192}"
# Rule 2: below this the duplicated text is cheaper than the round trip, so let it through.
PATCH_MIN_BYTES="${BASH_PATCH_MIN_BYTES:-2000}"
PATCH_GUARD="${BASH_PATCH_GUARD:-1}"
# Rule 3: identical probes allowed inside the window before it reads as a spin loop. Six is
# well above any honest re-check and ~15x below the 95 the measured session actually ran.
POLL_MAX="${BASH_POLL_MAX:-6}"
POLL_WINDOW="${BASH_POLL_WINDOW:-300}"
POLL_GUARD="${BASH_POLL_GUARD:-1}"

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool" = "Bash" ] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -n "$cmd" ] || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)

# THE ESCAPE HATCH HAS TO BE READ OUT OF THE COMMAND STRING, not the environment. A hook runs
# in its own process, so `VAR=x <command>` — the form every guard message here suggests — never
# reaches it: the assignment applies to the command the hook is deciding about, which has not
# run yet. Reading the hook's own env made the documented override silently do nothing, which is
# worse than having no override at all (you follow the instructions and get blocked anyway).
ovr() {
  printf '%s' "$cmd" \
    | sed -nE "s/.*(^|[[:space:]])$1=([0-9]+)([[:space:]].*)?$/\\2/p" \
    | head -1
}
v=$(ovr BASH_READ_MAX_BYTES);   [ -n "$v" ] && MAX_BYTES="$v"
v=$(ovr BASH_PATCH_MIN_BYTES);  [ -n "$v" ] && PATCH_MIN_BYTES="$v"
v=$(ovr BASH_PATCH_GUARD);      [ -n "$v" ] && PATCH_GUARD="$v"
v=$(ovr BASH_POLL_MAX);         [ -n "$v" ] && POLL_MAX="$v"
v=$(ovr BASH_POLL_WINDOW);      [ -n "$v" ] && POLL_WINDOW="$v"
v=$(ovr BASH_POLL_GUARD);       [ -n "$v" ] && POLL_GUARD="$v"

# ── RULE 2 first: it reads the heredoc BODY, which rule 1's stripping throws away.
if [ "$PATCH_GUARD" = "1" ]; then
  bytes=$(printf '%s' "$cmd" | wc -c | tr -d ' ')
  if [ "${bytes:-0}" -ge "$PATCH_MIN_BYTES" ]; then
    # A heredoc-fed interpreter that both READS and WRITES. Both halves are required: a script
    # that only writes is generating a file (legitimate), and one that only reads is rule 1's
    # business. Requiring the pair is what makes this "you are patching a file you already
    # have in context" rather than "you are using bash".
    if printf '%s' "$cmd" | grep -qE '(python3?|perl|ruby|node)[[:space:]]+(-[[:alnum:]]+[[:space:]]+)*-?[[:space:]]*<<'; then
      # A READ means an actual read CALL. A bare `open(` does not qualify: a write-only
      # generation script opens its output file too, so counting `open(` made every generated
      # file look like a patch — the guard's one measured false positive, caught by
      # guards-selftest's "write-only heredoc allowed" case.
      reads=$(printf '%s' "$cmd" | grep -cE "\.read\(|\.readlines\(|\.read_text\(|readFileSync|file_get_contents|<FH>" || true)
      writes=$(printf '%s' "$cmd" | grep -cE "\.write\(|writelines\(|write_text\(|,[[:space:]]*['\"]w['\"]" || true)
      if [ "${reads:-0}" -gt 0 ] && [ "${writes:-0}" -gt 0 ]; then
        {
          echo "⛔ Blocked: a read-modify-write patch through a heredoc (${bytes} bytes of command payload)."
          echo
          echo "This shape pays for the same text twice. The command carries the OLD block (which is"
          echo "already in your context, you just read the file) plus the NEW block — and because the"
          echo "write happens outside the tracked Edit path, the harness then echoes an"
          echo "'edited_text_file' diff of the result back at you. Measured over one session:"
          echo "~50k tokens of command payloads and 16.2k of those echoes."
          echo
          echo "Use the Edit tool instead: it sends old_string/new_string only, and triggers no echo."
          echo "  Edit(file_path=…, old_string=<the few lines you are replacing>, new_string=…)"
          echo "For many edits in one file, several Edit calls still cost less than one such heredoc."
          echo "Writing a NEW file, or one built by computation? Use Write — this guard allows both."
          echo
          echo "(Auto mode prefers bash for file changes to reduce permission prompts. This ONE shape"
          echo "is the documented exception — docs/agents/headroom.md. Deliberate override for a case"
          echo "Edit genuinely cannot express: BASH_PATCH_GUARD=0 <your command>.)"
        } >&2
        exit 2
      fi
    fi
  fi
fi

# ── Shared by rules 3 and 1.
#
# A HEREDOC BODY IS DATA, NOT COMMANDS (same lesson as pretool-adapter-pipe-guard.sh): prose
# and scripts routinely contain the word `cat`, and this hook's own documentation does.
nobody=$(printf '%s' "$cmd" | awk '
  { if (intag != "") { if ($0 == intag || $0 == intag";") intag=""; next } }
  { line=$0
    if (match(line, /<<-?[[:space:]]*'"'"'?[A-Za-z_][A-Za-z0-9_]*'"'"'?/)) {
      tag=substr(line, RSTART, RLENGTH); gsub(/^<<-?[[:space:]]*|'"'"'/, "", tag); intag=tag }
    print line }')

# Readers that emit a WHOLE file by default. `hcat` is deliberately absent: it is the remedy
# here, and pretool-hcat-size-guard.sh owns its own ceiling.
readers='cat|nl|less|more|bat'
# Stages that make a pipeline's output small. grep/awk/sed/jq can in principle pass everything
# through, so this is an accepted allowance rather than a proof — the shape being blocked is
# the BARE dump, which is what actually spends the window.
bounders='head|tail|wc|grep|egrep|rg|jq|awk|sed|uniq|md5|md5sum|shasum|sha1sum|diff|cmp|column|hcat'

# Split into pipelines on ; && || newline, keeping | intact so a bounding stage is still visible.
# Driven by here-strings, NOT `… | while`: a piped while body runs in a SUBSHELL, so its `exit 2`
# only ends the subshell and this hook went on to exit 0. That is not a style preference — the
# first version of this guard silently allowed every case it was written to block.
pipelines=$(printf '%s' "$nobody" | tr ';\n' '\n\n' | sed -e 's/&&/\n/g' -e 's/||/\n/g')

# ── RULE 3 — the same file probe, again, while something else is still running.
#
# Runs BEFORE rule 1's redirect allowance: a redirect spares the window the bytes, but it does
# not spare it the turn, and the turn is what this rule prices.
if [ "$POLL_GUARD" = "1" ]; then
  # A probe is a READ-ONLY inspection of a named file. Anything that builds, writes, moves or
  # runs is excluded by construction — repeating THOSE is work, not waiting.
  probers="$readers|$bounders|stat|file|du|cksum"
  probe=""
  while IFS= read -r pipeline; do
    [ -z "$pipeline" ] && continue
    first=${pipeline%%|*}
    head_tok=$(printf '%s' "$first" | sed -e 's/^[[:space:]]*//' \
      -e 's/^\([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]\{1,\}\)*//' \
      -e 's/^\(sudo\|env\|command\|time\|nohup\)[[:space:]]\{1,\}//')
    verb=$(printf '%s' "$head_tok" | awk '{print $1}')
    printf '%s' "$verb" | grep -qE "^($probers)$" || continue
    # It only counts as a probe if it names a file that EXISTS. `grep -r pattern .`, a pipe fed
    # from stdin, and a probe of a path not yet created are all just commands.
    while IFS= read -r arg; do
      [ -z "$arg" ] && continue
      case "$arg" in -*) continue ;; esac
      path=$(printf '%s' "$arg" | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")
      case "$path" in /*) ;; *) [ -n "$cwd" ] && path="$cwd/$path" ;; esac
      [ -f "$path" ] && { probe="$path"; break; }
    done <<< "$(printf '%s' "$head_tok" | awk '{for (i=2;i<=NF;i++) print $i}')"
    [ -n "$probe" ] && break
  done <<< "$pipelines"

  if [ -n "$probe" ]; then
    # Keyed on the WHOLE command, normalised for whitespace only. Two greps of one file with
    # different patterns are two questions; the identical grep twice is the same question.
    key=$(printf '%s' "$cmd" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//' | cksum | tr -d ' ')
    # transcript_path FIRST: parallel subagents in one workflow wave can share a session_id, and
    # a shared counter would let one agent's probes block another's first call.
    who=$(printf '%s' "$input" | jq -r '.transcript_path // .session_id // ""' 2>/dev/null | cksum | tr -d ' ')
    dir="${TMPDIR:-/tmp}/aiworks-poll-guard"
    ledger="$dir/$who"
    mkdir -p "$dir" 2>/dev/null
    now=$(date +%s)
    cutoff=$(( now - POLL_WINDOW ))
    # Prune to the window, then count what is left for THIS command. Pruning on every call is
    # what keeps the ledger from growing without bound over a long session.
    if [ -f "$ledger" ]; then
      awk -v c="$cutoff" -F' ' '$1 >= c' "$ledger" > "$ledger.tmp" 2>/dev/null && mv "$ledger.tmp" "$ledger"
    fi
    seen=$(awk -v k="$key" -F' ' '$2 == k' "$ledger" 2>/dev/null | wc -l | tr -d ' ')
    printf '%s %s\n' "$now" "$key" >> "$ledger" 2>/dev/null
    if [ "${seen:-0}" -ge "$POLL_MAX" ]; then
      mins=$(( POLL_WINDOW / 60 ))
      {
        echo "⛔ Blocked: this exact probe has already run ${seen} times in the last ${mins} min."
        echo "   $cmd"
        echo
        echo "Polling a file costs almost nothing to READ and a full turn to ASK. Every request"
        echo "re-sends your whole context, so a probe that returns one number against a 490k-token"
        echo "window bills 490k tokens to learn something you already knew. The session that"
        echo "motivated this rule ran one such grep 95 times: 1409 turns, 690M cache-read tokens,"
        echo "~\$30 — while every sibling agent finished the same kind of work in ~100 tool calls."
        echo
        echo "Wait in ONE call instead of N. Bash takes a run_in_background parameter, and the"
        echo "harness re-invokes you when the command exits — so give it a loop that ENDS when the"
        echo "thing you are waiting for is true:"
        echo "  Bash(run_in_background=true, command=\"until <the condition>; do sleep 5; done\")"
        echo "e.g.  until grep -q 'test result:' <log>; do sleep 5; done"
        echo "Make the condition match FAILURE too, or a crash looks identical to still-running:"
        echo "  until grep -qE 'test result:|error: could not compile|panicked' <log>; do sleep 5; done"
        echo
        echo "Need a notification per event rather than one at the end (each failure as it lands)?"
        echo "That is the Monitor tool, with a --line-buffered filter."
        echo
        echo "Already finished waiting and this really is a fresh question? Change the question —"
        echo "a different pattern or region is not the same probe and is not counted."
        echo "(Deliberate override: BASH_POLL_GUARD=0 <your command>.)"
      } >&2
      exit 2
    fi
  fi
fi

# ── RULE 1 — an unbounded whole-file read.
#
# A redirect to a file means the bytes never reach the window — exactly what the warden asks
# for. `cat big.json > /tmp/x` is the RIGHT move and must not be blocked.
printf '%s' "$nobody" | grep -qE '>[[:space:]]*[^&[:space:]]' && exit 0

while IFS= read -r pipeline; do
  [ -z "$pipeline" ] && continue
  case "$pipeline" in *'|'*)
    # Any later stage that bounds the output? Then the dump never lands.
    rest=${pipeline#*|}
    if printf '%s' "$rest" | tr '|' '\n' | sed -e 's/^[[:space:]]*//' \
         | grep -qE "^($bounders)([[:space:]]|$)"; then
      continue
    fi ;;
  esac

  # The reader must be in COMMAND POSITION — first token of the pipeline's first stage, after
  # peeling leading VAR=value assignments and command wrappers. Naming a file with `cat` in it,
  # or grepping for the string "cat", puts it in OPERAND position, where it is data.
  first=${pipeline%%|*}
  head_tok=$(printf '%s' "$first" | sed -e 's/^[[:space:]]*//' \
    -e 's/^\([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]\{1,\}\)*//' \
    -e 's/^\(sudo\|env\|command\|time\|nohup\)[[:space:]]\{1,\}//')
  verb=$(printf '%s' "$head_tok" | awk '{print $1}')
  printf '%s' "$verb" | grep -qE "^($readers)$" || continue

  # Every operand that is an existing file, sized. Flags are skipped; quotes are stripped for
  # the stat only and never re-used to build a command.
  operands=$(printf '%s' "$head_tok" | awk '{for (i=2;i<=NF;i++) print $i}')
  while IFS= read -r arg; do
    [ -z "$arg" ] && continue
    case "$arg" in -*) continue ;; esac
    path=$(printf '%s' "$arg" | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")
    case "$path" in
      /*) ;;
      *)  [ -n "$cwd" ] && path="$cwd/$path" ;;
    esac
    [ -f "$path" ] || continue
    size=$(wc -c < "$path" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) continue ;; esac
    [ "$size" -ge "$MAX_BYTES" ] || continue

    kb=$(( size / 1024 ))
    est=$(( size / 4 ))
    {
      echo "⛔ Blocked: unbounded \`$verb\` of a ${kb} KB file — ~${est} tokens straight into your context."
      echo "   $path"
      echo
      echo "Nothing consumes this output, so all of it lands in the window and stays there. The"
      echo "single biggest block in the session that motivated this guard was one such read of a"
      echo "25 KB file: ~7,000 tokens, to answer a question that needed about 30 lines."
      echo
      echo "Pick the smallest thing that answers your question:"
      echo "  • a REGION           sed -n '120,180p' <file>   ·   Read(file_path=…, offset=…, limit=…)"
      echo "  • a SEARCH           grep -n '<pattern>' <file>   (add -m 20 to cap the matches)"
      echo "  • the SHAPE          grep -nE '^#|^def |^function ' <file>   ·   wc -l <file>"
      echo "  • the WHOLE file, compressed        hcat '$path'"
      echo "  • the whole file, and you need it ALL — read it in a disposable subagent (Agent"
      echo "    tool) and have it return only the conclusion; the bytes never enter this context."
      echo
      echo "A redirect is always allowed — \`$verb <file> > /tmp/out.txt\` then grep the file."
      echo "(Deliberate one-off: BASH_READ_MAX_BYTES=<bytes> <your command>.)"
    } >&2
    exit 2
  done <<< "$operands"
done <<< "$pipelines"

exit 0
