#!/usr/bin/env bash
#
# PreToolUse(Bash) hook — close the git side-doors that let an agent publish
# something its tool grant deliberately does NOT allow.
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
case "$cmd" in *git*) ;; *) exit 0 ;; esac

# Split the command into segments on ; && || | & so each git invocation is
# inspected with only its own arguments in view.
segments=$(printf '%s' "$cmd" | sed -E 's/(\|\||&&|[;|&])/\n/g')

# Honour an explicit `git -C <dir>` inside a segment; else the tool's own cwd.
seg_repo_dir() {
  local d
  d=$(printf '%s' "$1" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+("?)([^"[:space:]]+)\1.*/\2/p' | head -1)
  [ -n "$d" ] && printf '%s' "$d" || printf '.'
}

# Arguments of `git <sub>` within one segment.
seg_args() {
  printf '%s' "$1" | sed -nE "s/.*[[:space:]]$2([[:space:]]+|$)//p"
}

is_git_sub() {
  printf '%s' "$1" | grep -qE "(^|[[:space:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)*([[:space:]]+-c[[:space:]]+[^[:space:]]+)*[[:space:]]+$2([[:space:]]|$)"
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
