#!/usr/bin/env bash
#
# PreToolUse(Bash) hook — block a MUTATING adapter call that has been wrapped in a
# compound command (a pipe, `&&`, `;`, a subshell, a heredoc).
#
# WHY THIS EXISTS
#   Permission is decided in two layers. First, static allow rules in
#   .claude/settings.json — this workspace grants `Bash(*scripts/vcs/*)`,
#   `Bash(*scripts/tracker/*)`, `Bash(*scripts/notify/*)`. Those patterns match the WHOLE
#   command string, so a bare `scripts/vcs/merge-pr.sh 11` matches and runs. Second, for
#   anything no rule matched, the auto-mode classifier judges it.
#
#   Appending `2>&1 | tail -5` makes the string a compound that no pattern can match. The
#   call falls through to the classifier, which sees "merge a merge request, squash,
#   delete the source branch" and denies it — silently, with no prompt to the user.
#   Measured on MR !11 (2026-08-07): the SAME merge was denied with the pipe and ran
#   without it. A piped `--dry-run` was allowed, so the pipe alone is not the denial —
#   the pipe costs the allowlist match, and the classifier then judges the action.
#
#   The habit that causes it is trimming output. It buys nothing here: these adapters
#   print one to four lines. So the pipe is pure cost — an unpredictable permission
#   outcome on the exact operations that are hardest to retry (an MR is merged once).
#
# WHAT IS GUARDED
#   Only the WRITERS, and only when compound. A read-only adapter call may be piped
#   freely — being denied a `pr-view.sh | head` costs a retry, not a half-finished merge.
#
# Exit 0 = allow. Exit 2 = block, stderr is shown to the model as feedback.

set -uo pipefail

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool" = "Bash" ] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# A HEREDOC BODY IS DATA, NOT COMMANDS. Strip it before looking for anything.
# `git commit -F - <<'EOF' … EOF` carries prose that routinely NAMES these scripts — this
# guard's own commit message did, and an earlier version blocked it. A doc, a PR body, a
# commit message quoting `merge-pr.sh` is not an invocation of it. The heredoc's own
# command line survives the strip, so a real `add-ticket-comment.sh A-1 <<EOF` still hits.
nobody=$(printf '%s' "$cmd" | awk '
  { if (intag != "" ) { if ($0 == intag || $0 == intag";") intag=""; next } }
  { line=$0
    if (match(line, /<<-?[[:space:]]*'"'"'?[A-Za-z_][A-Za-z0-9_]*'"'"'?/)) {
      tag=substr(line, RSTART, RLENGTH); gsub(/^<<-?[[:space:]]*|'"'"'/, "", tag); intag=tag }
    print line }')

# The mutating adapter entrypoints. Readers (pr-view, pr-comments, list-prs, find-prs,
# get-ticket-*, default-branch) are deliberately absent: they are safe to pipe.
writers='merge-pr\.sh|open-pr\.sh|close-pr\.sh|retarget-pr\.sh|pr-approve\.sh|pr-comment\.sh|pr-resolve-thread\.sh|upload-media\.sh|upsert-ticket-details\.sh|add-ticket-comment\.sh|edit-ticket-comment\.sh|upsert-ticket-comment\.sh|add-ticket-attachment\.sh|remove-ticket-attachment\.sh|delete-ticket\.sh|delete-ticket-comment\.sh|send\.sh'

printf '%s' "$nobody" | grep -qE "scripts/(vcs|tracker|notify)/($writers)" || exit 0

# A --dry-run writes nothing, so a piped preview is fine — and forbidding it would push
# people away from previewing, which is the opposite of what this guard is for.
printf '%s' "$cmd" | grep -qE '(^|[[:space:]])--dry-run([[:space:]]|$)' && exit 0

# Is it compound? Blank out quoted spans first: an operator inside a quoted argument (a
# commit message containing "A && B", a --body with a pipe table) is text, not shell
# syntax, and blocking on it would be a false positive on exactly the rich PR/MR bodies
# this workspace writes.
#
# This is a quote-state SCANNER rather than a pair of regex substitutions, because the
# substitutions had two failure modes and both fired on real PR bodies — the exact case
# this strip exists to protect:
#
#   LINE-ORIENTED. `perl -pe` runs per line, so a multi-line `--body "…"` opens its quote
#   on one line and closes it many lines later and NEITHER pattern ever matched. The whole
#   body survived into $bare, where every `|` of a Markdown table and every `;` of an
#   English sentence read as shell syntax. Measured on aiworks#85: three identical
#   `open-pr.sh` calls blocked, on a table, then on one semicolon in prose.
#
#   ORDER-DEPENDENT. Stripping single-quoted spans FIRST lets two apostrophes in prose
#   ("somebody's … that file's") pair up and swallow the double quote between them, so the
#   second substitution runs against a string that no longer parses as it was written. No
#   single-line payload has been found where that alone flips the verdict — every operator
#   tried happened to fall inside the span it deleted — so this one is luck rather than a
#   measured bug. A scanner that tracks quote state does not need the luck.
#
# Walking the string once with a quote state has neither failure mode: a quote character
# only opens or closes a span when the state says it can, a backslash escapes the next
# character everywhere except inside single quotes, and quoted content is replaced with a
# space so tokens can never glue together.
bare=$(printf '%s' "$nobody" | perl -e '
  my $s = do { local $/; <STDIN> };
  my ($SQ, $DQ, $BS) = (chr(39), chr(34), chr(92));
  my ($out, $q, $i, $n) = ("", "", 0, length $s);
  while ($i < $n) {
    my $c = substr($s, $i, 1);
    if    ($q eq ""  and ($c eq $SQ or $c eq $DQ))    { $q = $c; $out .= " " }
    elsif ($q ne ""  and $c eq $q)                    { $q = "";  $out .= " " }
    elsif ($q ne $SQ and $c eq $BS and $i + 1 < $n)   { $i++;     $out .= " " }
    elsif ($q eq "")                                  { $out .= $c }
    else                                              { $out .= " " }
    $i++;
  }
  print $out;
' 2>/dev/null) || bare="$cmd"

# Every arm needs its leading `*`: the backtick one lacked it, so a command substitution
# anywhere but the first character (`echo `…merge-pr.sh``) was not seen as compound at all.
# `&` and `>` are deliberately absent — `writer 2>&1` and `writer > out.txt` keep the
# allowlist match, and the block message recommends the redirect itself.
case "$bare" in
  *'|'*|*'&&'*|*'||'*|*';'*|*'$('*|*'`'*|*'<<'*) ;;
  *) exit 0 ;;
esac

# THE WRITER MUST BE IN COMMAND POSITION. Naming the script is not calling it: reading one
# with another tool — `grep -n pattern scripts/vcs/open-pr.sh | head`, `wc -l …/send.sh` —
# puts the path in OPERAND position, where it is data. The first version matched the token
# anywhere in the command and blocked those; it blocked two of this guard's own maintenance
# reads. Third prose-not-code class, after a quoted argument and a heredoc body.
#
# So split the (quote-stripped) command on shell control operators and check only the FIRST
# token of each segment, after peeling what legitimately precedes a command: shell keywords,
# leading VAR=value assignments, and wrappers that take a command as their argument (`bash
# x.sh` IS an invocation of x.sh, so peeling `bash` is correct — it must still block).
#
# Known gap, accepted: a writer reached indirectly — `xargs …/send.sh`, `find -exec …` —
# never sits in command position, so it is allowed. Both are exotic next to the `| tail`
# habit this guard exists for, and the alternative is re-implementing shell parsing.
printf '%s' "$bare" | perl -e '
  my $s = do { local $/; <STDIN> };
  my $w = $ARGV[0];
  for my $g (split /(?:\|\||&&|\||;|&|\n|\$\(|\x60|\()/, $s) {
    $g =~ s/^\s+//;
    1 while $g =~ s/^(?:do|then|else|elif|if|while|until|for|\{|!)\s+//
         or $g =~ s/^[A-Za-z_][A-Za-z0-9_]*=\S*\s+//
         or $g =~ s/^(?:sudo|env|command|exec|time|nohup|bash|sh)\s+//;
    next unless $g =~ /^(\S+)/;
    exit 0 if $1 =~ m{scripts/(?:vcs|tracker|notify)/(?:$w)$};
  }
  exit 1;
' "$writers"
# 1 = the writer only ever appears as an operand, so nothing is being invoked. Any other
# non-zero (no perl, a bad pattern) falls through and blocks — the pre-existing behaviour.
[ "$?" -eq 1 ] && exit 0

prog=$(printf '%s' "$nobody" | grep -oE "scripts/(vcs|tracker|notify)/($writers)" | head -n1)

{
  echo "⛔ Blocked: a mutating adapter call inside a compound command."
  echo
  echo "    $cmd"
  echo
  echo "\`$prog\` writes to a shared system (an MR, a ticket, a channel)."
  echo "A bare call matches the allowlist and runs. Wrapping it in a pipe / && / ;"
  echo "matches NO rule, so it falls through to the permission classifier — which"
  echo "denies exactly these operations, silently and without asking the user."
  echo
  echo "Run it bare:"
  echo "  $prog <args>"
  echo
  echo "These adapters print 1-4 lines, so there is nothing to trim. If you do need"
  echo "the output for a later step, redirect and read the file separately:"
  echo "  $prog <args> > /tmp/out.txt"
  echo
  echo "Previewing is always allowed, piped or not: add --dry-run."
} >&2
exit 2
