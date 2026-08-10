#!/usr/bin/env bash
#
# PreToolUse(Bash) hook — close the VCS side-doors that let an agent publish
# something its tool grant deliberately does NOT allow.
#
# 0. `glab mr create` / `gh pr merge` / `glab api --method POST` …
#    The provider CLI reaches the forge directly, so it bypasses scripts/vcs/
#    entirely — the adapter's title/body conventions, its provider-swappability
#    (CONTEXT.md), and the workflow phase that owns PR/MR creation. Two agents in
#    one dev-cycle run went down this exact road: the mandated adapter call was
#    denied for being compound, they read that as a broken adapter, and reached
#    for `glab mr create --yes` against the real remote instead. The prohibition
#    was already written in CLAUDE.md, CONTEXT.md and three skills, and was
#    enforced only in a delegation BRIEF (pretool-agent-brief-guard.sh) — never
#    on the command an agent actually runs. Prose lost twice; this is the fix.
#    READ-ONLY use stays allowed (`glab mr view`, `gh pr list`) — the point is
#    that nothing MUTATES the forge except through the adapter.
#
# 1. `git push -o merge_request.create` (or --push-option=…)
#    A GitLab *push option* creates a merge request server-side. It needs only
#    `Bash(git *)`, so an agent whose grant intentionally omits
#    `Bash(*scripts/vcs/*)` — development-planner, for one — can still open an
#    MR with it, bypassing the VCS adapter, its title/body conventions, and the
#    workflow phase that actually owns PR/MR creation. PR/MR creation goes
#    through scripts/vcs/open-pr.sh, by an agent that is granted it.
#
# 2. `git add -f` past a COMMITTED .gitignore
#    -f is the only way to stage an ignored path. Two different things can hide
#    a path, and only one of them is policy:
#
#      .gitignore         committed, shared, intentional — agent_logs/ (local
#                         planning artifacts, see docs/agents/plan-artifacts.md),
#                         build output, and the way a secret file reaches an
#                         index in the first place. Forcing past it is the
#                         violation this guard exists for.
#      .git/info/exclude  LOCAL and personal, in no commit. This workspace uses
#                         it for per-developer product-repo clones and it also
#                         lists scripts/tracker + scripts/vcs — silently hiding
#                         NEW adapter wrappers written there. A feature has
#                         already shipped with no entrypoint because of it, so
#                         -f is the CORRECT move for that case, not a bypass.
#
#    So the paths are resolved and `check-ignore -v` is read for its SOURCE.
#    Anything unresolvable (a glob, `.`) is treated as a block — the point is to
#    catch a broad sweep dragging an ignored artifact in.
#
# 3. `git commit` whose staged set contains a .gitignore'd path (backstop)
#    Catches a force-add that landed in the index some other way — an earlier
#    session, `git update-index`, or a file staged before the rule appeared.
#
# Every check is scoped to the SEGMENT of the command that actually runs that
# git subcommand, split on shell separators. Scanning the whole command string
# would misread an unrelated flag elsewhere in a compound command (`git add x &&
# rm -rf tmp` is not a force-add).
#
# Fails OPEN on anything it cannot determine. Exit 0 = allow, exit 2 = block
# with stderr fed back to the model.

set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$cmd" ] && exit 0
# `gh` is only two letters and lives inside ordinary words (high, through, night), so this
# fast path deliberately over-matches; command position is decided precisely below.
case "$cmd" in *git*|*glab*|*gh*) ;; *) exit 0 ;; esac

# Split the command into segments on ; && || | & so each git invocation is
# inspected with only its own arguments in view.
segments=$(printf '%s' "$cmd" | sed -E 's/(\|\||&&|[;|&])/\n/g')

# A SECOND, QUOTE- AND HEREDOC-STRIPPED view of the same command, for the provider-CLI rule
# only. `glab`/`gh` are words that legitimately appear inside prose an agent WRITES — a commit
# message, a PR body, a doc paragraph about this very prohibition — and this guard's own commit
# message names them. Deciding on the raw string would block writing about the rule. The git
# rules below keep the RAW segments on purpose: they parse real path arguments, which are
# routinely quoted, and stripping quotes would erase them.
# (Both strippers are ported from pretool-adapter-pipe-guard.sh, which learned the same lesson.)
nobody=$(printf '%s' "$cmd" | awk '
  { if (intag != "" ) { if ($0 == intag || $0 == intag";") intag=""; next } }
  { line=$0
    if (match(line, /<<-?[[:space:]]*'"'"'?[A-Za-z_][A-Za-z0-9_]*'"'"'?/)) {
      tag=substr(line, RSTART, RLENGTH); gsub(/^<<-?[[:space:]]*|'"'"'/, "", tag); intag=tag }
    print line }')
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
bare_segments=$(printf '%s' "$bare" | sed -E 's/(\|\||&&|[;|&])/\n/g')

# Honour an explicit `git -C <dir>` inside a segment; else the tool's own cwd.
# awk, not sed: the obvious `sed -E 's/.*-C[[:space:]]+("?)([^"[:space:]]+)\1.*/\2/'`
# looks right and is not — `\1` back-references a group that matched the EMPTY string
# (the optional quote), which BSD sed resolves erratically: it printed nothing for
# `git -C /tmp/svc …` and a TRUNCATED path for others. Both fall through to `.`, i.e.
# the guard silently inspects the WRONG repo — and `git -C /abs/path` is the idiom this
# workspace's own cd-guard tells agents to use, so that is the common case, not a corner.
# awk splits on whitespace independent of the caller's IFS (which is newline here).
seg_repo_dir() {
  local d
  d=$(printf '%s\n' "$1" | awk '{for(i=1;i<NF;i++) if($i=="-C") {print $(i+1); exit}}')
  d=${d%\"}; d=${d#\"}; d=${d%\'}; d=${d#\'}
  [ -n "$d" ] || d="."
  printf '%s' "$d"
}

# Arguments of `git <sub>` within one segment.
seg_args() {
  printf '%s' "$1" | sed -nE "s/.*[[:space:]]$2([[:space:]]+|$)//p"
}

is_git_sub() {
  printf '%s' "$1" | grep -qE "(^|[[:space:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)*([[:space:]]+-c[[:space:]]+[^[:space:]]+)*[[:space:]]+$2([[:space:]]|$)"
}

# The provider CLI in COMMAND POSITION — the segment's first real word, past any leading
# VAR=… assignments and the usual wrappers. Anything else (a path that ends in /gh, the
# word "glab" inside a quoted message, `grep -n glab file`) is NOT an invocation and is
# left alone: this guard blocks what RUNS, never what is merely mentioned.
# Prints "<cli> <group> <verb>", or nothing.
seg_provider() {
  printf '%s' "$1" | awk '{
    i = 1
    while (i <= NF && ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || $i == "sudo" || $i == "env" ||
                       $i == "command" || $i == "exec" || $i == "time" || $i == "nohup")) i++
    if ($i == "glab" || $i == "gh") print $i, $(i+1), $(i+2)
  }'
}

# `check-ignore -v` output is "<source-file>:<line>:<pattern>\t<path>"; a path
# hidden only by info/exclude is dropped, leaving true .gitignore violations.
gitignored_only() {  # <repo_dir> ; paths on stdin
  git -C "$1" check-ignore -v --stdin 2>/dev/null \
    | grep -v '/info/exclude:' \
    | sed -E 's/^[^:]*:[0-9]*:[^\t]*\t//'
}

IFS='
'
IFS='
'
# Provider-CLI rule runs FIRST, over the quote/heredoc-stripped view.
for seg in $bare_segments; do
  # --------------------------------------------------- provider CLI (glab/gh)
  prov=$(seg_provider "$seg")
  if [ -n "$prov" ]; then
    # awk again, not word-splitting: IFS is newline for the segment loop, so `set -- $prov`
    # would hand back ONE field instead of three (the same trap seg_repo_dir documents).
    cli=$(printf '%s' "$prov" | awk '{print $1}')
    group=$(printf '%s' "$prov" | awk '{print $2}')
    verb=$(printf '%s' "$prov" | awk '{print $3}')
    deny=0; what=""
    case "$group" in
      # Forge objects. Fail CLOSED: an unrecognised verb denies rather than slips
      # through, so a subcommand this list has never heard of cannot be the next
      # side-door. Read-only verbs are the allowlist.
      mr|pr|issue|release|repo|label|milestone|variable|schedule)
        case "$verb" in
          view|list|ls|diff|status|browse|search|todo|config|checkout|'') deny=0 ;;
          *) deny=1; what="$cli $group $verb" ;;
        esac ;;
      # Raw API: only a mutating method is a side-door; a GET is just reading.
      api)
        if printf '%s' "$seg" | grep -qiE '(--method|-X)[[:space:]]*=?[[:space:]]*(POST|PUT|PATCH|DELETE)'; then
          deny=1; what="$cli api with a mutating method"
        fi ;;
    esac
    if [ "$deny" -eq 1 ]; then
      {
        echo "⛔ Blocked: $what — the provider CLI mutates the forge directly."
        echo
        echo "Every write to a PR/MR, issue or release goes through the VCS adapter,"
        echo "so the provider stays swappable in one place and the workflow phase that"
        echo "owns the action keeps owning it. Use the adapter instead:"
        echo
        echo "  open a PR/MR      scripts/vcs/open-pr.sh --base <base> --head <branch> --title \"…\" --body \"…\""
        echo "  comment           scripts/vcs/pr-comment.sh <number> [--path <file> --line <n>] --body \"…\""
        echo "  approve           scripts/vcs/pr-approve.sh <number> --body \"…\""
        echo "  merge             scripts/vcs/merge-pr.sh <number> --subject \"…\""
        echo "  close             scripts/vcs/close-pr.sh <number>"
        echo "  read (allowed)    pr-view.sh · pr-comments.sh · pr-threads.sh · list-prs.sh · find-prs.sh"
        echo
        echo "⚠️  A WRITER must run BARE — its own command, no 'cd X && …', no pipe, no"
        echo "    redirect. The compound form is denied and you get NO permission prompt,"
        echo "    which reads exactly like a broken adapter. Enter the repo with a"
        echo "    separate 'cd <absolute path>' call first; Bash cwd persists."
        echo
        echo "If the adapter itself fails, that IS the answer for this step — report the"
        echo "command, its exit code and its stderr. Do not route around it."
      } >&2
      exit 2
    fi
  fi
done

for seg in $segments; do
  # ---------------------------------------------------------- push options
  if is_git_sub "$seg" push; then
    if printf '%s' "$(seg_args "$seg" push)" | grep -qE '(^|[[:space:]])(-o[[:space:]]*[^[:space:]]|--push-option([[:space:]]|=))'; then
      {
        echo "⛔ Blocked: git push with a push option (-o / --push-option)."
        echo
        echo "A push option creates the MR server-side, bypassing the VCS adapter"
        echo "and whichever agent/phase is actually granted PR/MR creation."
        echo
        echo "Push the branch WITHOUT the option, then open the PR/MR properly:"
        echo "  git push -u origin <branch>"
        echo "  scripts/vcs/open-pr.sh --title \"<type>(<KEY>): <title>\" --body \"…\""
        echo
        echo "If your tool grant has no Bash(*scripts/vcs/*), opening a PR/MR is"
        echo "NOT your job — hand the branch back to the caller and say so."
      } >&2
      exit 2
    fi
  fi

  # ------------------------------------------------------------- force-add
  if is_git_sub "$seg" add; then
    args=$(seg_args "$seg" add)
    if printf '%s' "$args" | grep -qE '(^|[[:space:]])(--force|-[A-Za-z]*f[A-Za-z]*)([[:space:]]|$)'; then
      repo_dir=$(seg_repo_dir "$seg")
      paths=$(printf '%s' "$args" | tr ' ' '\n' | grep -vE '^-|^$|^--$' | tr -d '"'"'")

      violation=""
      broad=0
      [ -z "$paths" ] && broad=1
      for p in $paths; do
        case "$p" in .|./|'*'|*'*'*|*'?'*) broad=1; break ;; esac
        hit=$(printf '%s\n' "$p" | gitignored_only "$repo_dir")
        [ -n "$hit" ] && violation="$violation $p"
      done

      if [ "$broad" -eq 0 ] && [ -z "$violation" ]; then
        echo "ℹ️  git add -f allowed: nothing here is hidden by a committed .gitignore." >&2
        continue
      fi

      {
        if [ "$broad" -eq 1 ]; then
          echo "⛔ Blocked: git add -f with a path this guard cannot resolve (a glob, or '.')."
          echo "   Name the paths explicitly so the ignored ones can be checked."
        else
          echo "⛔ Blocked: git add -f past a committed .gitignore:"
          printf '     %s\n' $violation
        fi
        echo
        echo "A path in .gitignore is ignored on purpose, by a rule everyone shares."
        echo "agent_logs/ in particular holds LOCAL planning artifacts that are"
        echo "never committed — see docs/agents/plan-artifacts.md."
        echo
        echo "Publish a plan/report by REFERENCE instead of committing it:"
        echo "  • scripts/tracker/add-ticket-comment.sh   (onto the ticket)"
        echo "  • the Artifact tool                       (a shareable URL)"
        echo
        echo "If a path genuinely belongs in the repo, change .gitignore in its own"
        echo "reviewed commit. A path hidden only by the LOCAL .git/info/exclude is"
        echo "allowed — name it explicitly."
      } >&2
      exit 2
    fi
  fi

  # -------------------------------------------- commit of an ignored path
  if is_git_sub "$seg" commit; then
    repo_dir=$(seg_repo_dir "$seg")
    staged=$(git -C "$repo_dir" diff --cached --name-only 2>/dev/null) || continue
    [ -z "$staged" ] && continue
    ignored=$(printf '%s\n' "$staged" | gitignored_only "$repo_dir")
    if [ -n "$ignored" ]; then
      {
        echo "⛔ Blocked: commit stages path(s) a committed .gitignore excludes:"
        printf '     %s\n' $ignored
        echo
        echo "These were force-added or staged before the rule existed. Unstage them:"
        echo "  git -C $repo_dir restore --staged $(printf '%s ' $ignored)"
        echo
        echo "Local planning artifacts (agent_logs/) are published by reference —"
        echo "a ticket comment or an Artifact URL, never a commit."
        echo "See docs/agents/plan-artifacts.md."
      } >&2
      exit 2
    fi
  fi
done

exit 0
