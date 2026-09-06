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
# 4. `git merge` / `git pull` of anything but a ticket branch's OWN recorded base
#    A gate-fix agent merged an unrelated branch into a ticket's work branch to
#    pull in fixtures it needed. That merge commit dragged in a pile of commits
#    from OTHER tickets along with it — mixed ticket/non-ticket history that a
#    later re-point could no longer repair automatically, and a person had to
#    back up the branch and rebase it by hand. `git merge`/`git pull` succeed
#    silently even when the branch they just polluted is a ticket's own — there
#    is no conflict to stop them, unlike a rebase (see below).
#
#    The workflow that owns a ticket's branch already records which base branch
#    it was planned against, in its own per-repo run-state row
#    (agent_logs/<TICKET>-dev-cycle-state/<repo>-planned.json, `.base_branch` —
#    see docs/adr/0025-the-runs-base-is-state-and-the-pr-is-asserted-against-it.md
#    and docs/adr/0018-dev-cycle-keeps-its-own-run-state.md). This rule reads that
#    SAME row rather than re-deriving a base of its own: on a branch matching
#    `feature/<PREFIX>-<n>` or `fix/<PREFIX>-<n>` (ticket_prefix from
#    workspace.config.yaml), a merge/pull may only target the recorded base
#    branch or the ticket branch's own remote — anything else is blocked.
#
#    Deliberately out of scope: `git rebase` (a foreign rebase target still stops
#    on its own conflicts, and is the documented human repair path for exactly
#    this failure — `--accept-base-change` in docs/agents/workflow-resume.md);
#    a remote named anything other than `origin` (this workspace's own
#    convention); a bare `merge`/`pull` with no explicit ref, an octopus merge,
#    or a target of `FETCH_HEAD`/`MERGE_HEAD` (all ambiguous — fails open rather
#    than guess); and any branch with no recorded base at all (nothing to
#    enforce yet, fails open).
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

# `check-ignore -v` output is "<source-file>:<line>:<pattern>\t<path>"; a path hidden only
# by info/exclude is dropped, and so is a NEGATED pattern (a leading `!`, e.g. `!.env.example`
# re-including a template past the blanket `.env*` rule) — a negation match means the path is
# NOT ignored, the opposite of what this function reports. Leaving it in falsely blocked every
# commit touching scripts/notify/.env.example (a real repo file, never ignored) as though it
# were a force-added secret. What remains are true .gitignore violations.
gitignored_only() {  # <repo_dir> ; paths on stdin
  # --no-index is what makes this work on a path that is ALREADY STAGED. Without it
  # `check-ignore` exempts anything in the index, so a force-added ignored file reads
  # as "not ignored" at commit time — which silently reduced the commit check below to
  # firing on staged DELETIONS only, i.e. to pure false positives. Measured both ways.
  # The `git add -f` caller is unaffected: its operands are not in the index yet, so
  # both forms already agreed there.
  git -C "$1" check-ignore -v --no-index --stdin 2>/dev/null \
    | grep -v '/info/exclude:' \
    | grep -vE '^[^:]*:[0-9]+:!' \
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
        echo "    which reads exactly like a broken adapter. If cwd is not already the"
        echo "    target repo, resolve it once ('git -C <abs> remote get-url origin') and"
        echo "    pass VCS_REPO=<owner/repo> on the SAME bare line as the writer — a prior"
        echo "    separate 'cd' call is not guaranteed to still be in effect."
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
    # --diff-filter=d EXCLUDES deletions. A staged deletion REMOVES a path from the
    # index, so it can never "commit an ignored path" — and `git rm --cached <f>`
    # right after adding <f> to .gitignore is the sanctioned way to untrack a file
    # that just became ignored. Without this the guard blocked exactly that flow:
    # the newly-ignored path is staged (as a deletion) AND matches .gitignore, so
    # the untrack commit could never be made. Additions and modifications of an
    # ignored path are still caught, which is the case this guard exists for.
    staged=$(git -C "$repo_dir" diff --cached --name-only --diff-filter=d 2>/dev/null) || continue
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

  # ------------------- merge/pull limited to the ticket's recorded base ------
  sub=""
  if is_git_sub "$seg" merge; then sub=merge
  elif is_git_sub "$seg" pull; then sub=pull
  fi
  if [ -n "$sub" ]; then
    repo_dir=$(seg_repo_dir "$seg")
    cur_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    proj_root="${CLAUDE_PROJECT_DIR:-.}"
    cfg="$proj_root/workspace.config.yaml"
    prefix=""
    if [ -f "$cfg" ]; then
      prefix=$(grep -m1 -E '^[[:space:]]*ticket_prefix:' "$cfg" 2>/dev/null \
        | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*$//')
      prefix=${prefix%\"}; prefix=${prefix#\"}
      prefix=${prefix%\'}; prefix=${prefix#\'}
    fi
    ticket=""
    if [ -n "$cur_branch" ] && [ "$cur_branch" != "HEAD" ] && [ -n "$prefix" ]; then
      ticket=$(printf '%s' "$cur_branch" | grep -oE "^(feature|fix)/(${prefix}-[0-9]+)$" | sed -E 's#^(feature|fix)/##')
    fi
    if [ -n "$ticket" ]; then
      repo_base=$(basename "$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null)")
      state_file="$proj_root/agent_logs/${ticket}-dev-cycle-state/${repo_base}-planned.json"
      if [ -n "$repo_base" ] && [ -f "$state_file" ]; then
        recorded_base=$(jq -r '.base_branch // empty' "$state_file" 2>/dev/null)
        if [ -n "$recorded_base" ]; then
          # Tokenize the subcommand's OWN arguments (quote-aware, so a quoted
          # `-m "custom message"` value is one token, not two stray words), drop
          # every flag and — for a value-taking flag — the token right after it,
          # so its value is never mistaken for a ref. What remains are positionals.
          positionals=$(printf '%s' "$(seg_args "$seg" "$sub")" | perl -e '
            my $s = do { local $/; <STDIN> };
            my ($SQ,$DQ,$BS) = (chr(39), chr(34), chr(92));
            my @toks; my ($cur, $q, $have) = ("", "", 0);
            my ($i, $n) = (0, length $s);
            while ($i < $n) {
              my $c = substr($s,$i,1);
              if    ($q eq "" and ($c eq $SQ or $c eq $DQ)) { $q = $c; $have = 1 }
              elsif ($q ne "" and $c eq $q)                 { $q = "" }
              elsif ($q ne $SQ and $c eq $BS and $i+1 < $n) { $i++; $cur .= substr($s,$i,1); $have = 1 }
              elsif ($q eq "" and $c =~ /\s/)                { if ($have) { push @toks, $cur; $cur=""; $have=0 } }
              else                                           { $cur .= $c; $have = 1 }
              $i++;
            }
            push @toks, $cur if $have;
            print "$_\n" for @toks;
          ' 2>/dev/null | awk '
            BEGIN { skip = 0 }
            {
              if (skip) { skip = 0; next }
              if ($0 ~ /^-/) {
                if ($0 == "-m" || $0 == "--message" || $0 == "-s" || $0 == "--strategy" ||
                    $0 == "-X" || $0 == "--strategy-option" || $0 == "--into-name") skip = 1
                next
              }
              print
            }')
          count=$(printf '%s\n' "$positionals" | grep -c .)
          target=""
          case "$sub:$count" in
            merge:1) target=$(printf '%s\n' "$positionals" | grep .) ;;
            pull:2)  target=$(printf '%s\n' "$positionals" | grep . | tail -1) ;;
          esac
          # FETCH_HEAD/MERGE_HEAD: what they resolve to isn't visible here — fail open.
          if [ -n "$target" ] && [ "$target" != "FETCH_HEAD" ] && [ "$target" != "MERGE_HEAD" ]; then
            case "$target" in
              "$recorded_base"|"origin/$recorded_base"|"$cur_branch"|"origin/$cur_branch") : ;;
              *)
                {
                  echo "⛔ Blocked: git $sub of '$target' on ticket branch '$cur_branch'."
                  echo
                  echo "This ticket's recorded base is '$recorded_base' ($state_file)."
                  echo "Merging/pulling any other branch here silently pollutes the ticket"
                  echo "branch with unrelated history — exactly what a later re-point cannot"
                  echo "repair without a person."
                  echo
                  echo "Need the base's own newer commits?  git merge origin/$recorded_base"
                  echo
                  echo "Base itself wrong? That's a human/orchestrator call, not something to"
                  echo "route around locally — see"
                  echo "docs/adr/0025-the-runs-base-is-state-and-the-pr-is-asserted-against-it.md"
                  echo "and docs/agents/workflow-resume.md (--accept-base-change)."
                } >&2
                exit 2
                ;;
            esac
          fi
        fi
      fi
    fi
  fi
done

exit 0
