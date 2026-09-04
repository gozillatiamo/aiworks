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
  # file (.env or .env.<suffix>) and NOT a template.
  #
  # A trailing `.example` is the template marker, wherever it sits: the workspace
  # carries .env.example, .env.amb.example and .env.local.example, and only the
  # first was recognised while the other two were blocked as secrets. They hold
  # no values by definition. Matching the SUFFIX rather than the exact string
  # covers every `.env.<variant>.example`, and something like `.env.example.bak`
  # still reads as a secret because it does not end in `.example`.
  case "$1" in
    *.example) return 1 ;;
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
      # An EXCLUSION argument names a .env in order to skip it — the opposite of
      # reading one, and exactly the shape Rule 3 injects below. Strip those
      # tokens before the scan, or the guard denies the very command it just
      # rewrote (measured: exit 2), and a person who adds --exclude by hand is
      # punished for being careful. Only the option's own argument is dropped,
      # so `grep --exclude=x .env` still reads as a .env and is still denied.
      seg=$(printf '%s' "$seg" | sed -E "s/--exclude(-dir)?=[^[:space:]]+//g; s/--glob=[^[:space:]]+//g; s/-g[[:space:]]+'[^']*'//g")
      [ -z "$seg" ] && continue
      # segment must name a .env; a .env.example segment is a safe template.
      printf '%s' "$seg" | grep -Eq "$ENV_TOKEN" || continue
      # `.env.<variant>.example` is a template too — .env.amb.example and
      # .env.local.example both exist here and were blocked by an exemption that
      # only matched the exact `.env.example`. Same suffix rule as is_env_path.
      printf '%s' "$seg" | grep -Eq '\.env[A-Za-z0-9_.-]*\.example\b' && continue

      # cat/head/tail/less/more/sed -n always print file contents. `hcat` is
      # the headroom plugin's compress-at-the-source reader: a RENAMED `cat`,
      # so it needs its own alternative — `\bcat\b` cannot match "hcat" (the
      # leading h is a word char, so there is no boundary before "cat").
      # `hrun` is the same hazard one level out: it runs ANY command and prints
      # what that command printed, so `hrun cat .env` leaks exactly as `cat
      # .env` does — and its own name contains no "cat" to match on.
      if printf '%s' "$seg" | grep -Eq "\\b(hrun|hcat|cat|head|tail|less|more|sed[[:space:]]+-n)\\b[^|;&]*$ENV_TOKEN"; then
        deny "command dumps a .env file: $cmd"
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

    # ---------------------------------------------------------------------
    # Rule 3 — an UNDIRECTED recursive search. `grep -rn SECRET .` names no
    # .env, so Rules 1 and 2 pass it (measured: exit 0), and then it prints
    # every matching line of every .env it walks into. Same leak as `cat
    # .env`, with the filename supplied by the walk instead of by the model —
    # which is exactly why the permission classifier flags an ordinary
    # recursive grep as a possible secret read, and why the prompt kept
    # coming back.
    #
    # Blocking would tax every ordinary search, so the search is SCOPED
    # instead: the exclusions are injected and the command runs. `updatedInput`
    # rewrites it and `systemMessage` says so, so the narrowing is never
    # silent — `.env.example` is excluded with the rest (fnmatch cannot say
    # ".env.* except *.example"), and a template that is genuinely needed is
    # read by naming it, which this guard has always allowed.
    # Idempotent: a command that already carries the exclusions is left alone,
    # so a re-fired hook cannot stack them.
    # ---------------------------------------------------------------------
    new_cmd=$(printf '%s' "$cmd" | perl -0777 -pe '
      sub scoped {
        my ($pre, $bin, $rest) = @_;
        return "$pre$bin$rest" if $rest =~ /--exclude=\.env/;
        # Recursive only: -r/-R (alone or bundled, e.g. -rn) and the long forms.
        # Matched on short-option tokens rather than anywhere, or a long flag
        # that merely contains an "r" (--color) would read as recursive.
        return "$pre$bin$rest"
          unless $rest =~ /(?:^|\s)-[A-Za-z]*[rR][A-Za-z]*(?=\s|$)/
              || $rest =~ /(?:^|\s)--(?:recursive|dereference-recursive)\b/;
        return "$pre$bin --exclude=.env --exclude=.env.*$rest";
      }
      # Command position only (start, or after ; | & ( or $( ) — a "grep" inside
      # a quoted string is inert text and must not be rewritten. Each match stops
      # at the next segment separator so a pipeline keeps its shape.
      s{(^|[;|&(]\s*|\$\(\s*)(grep|egrep|fgrep)\b([^;|&\n]*)}{ scoped($1, $2, $3) }ge;
      # ripgrep walks recursively by default, so it needs no -r test. Its later
      # glob wins, which is how the template stays readable here and cannot in grep.
      s{(^|[;|&(]\s*|\$\(\s*)(rg)\b([^;|&\n]*)}{
        $3 =~ /!\.env/ ? "$1$2$3" : "$1$2 -g \x27!.env*\x27 -g \x27.env*.example\x27$3"
      }ge;
    ' 2>/dev/null)
    if [ -n "$new_cmd" ] && [ "$new_cmd" != "$cmd" ]; then
      printf '%s' "$input" | jq -c --arg c "$new_cmd" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          updatedInput: (.tool_input + {command: $c})
        },
        systemMessage: ("env-guard: scoped the recursive search away from .env files (.env.example too) — running: " + $c)
      }' 2>/dev/null
      exit 0
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
