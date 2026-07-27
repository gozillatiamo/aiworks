#!/usr/bin/env bash
#
# PreToolUse(Bash|Write|Edit) hook — enforce the submodule rule from
# docs/agents/submodules.md MECHANICALLY, and — just as importantly — get out of
# the way of the reads that rule was never about.
#
# The rule has exactly one prohibition: do not CREATE, EDIT, or COMMIT inside a
# submodule checkout. That checkout is a read-only pointer; the code belongs to a
# repo that is also cloned as its own primary clone at the workspace root, and the
# change has to land there.
#
# INSPECTING a submodule is not the same act and was never forbidden. Moving a
# submodule's ref to *prove* something — "does the suite go green once this
# pointer is bumped?" — is ordinary review work, and it is exactly what a reviewer
# needs to turn "I reason it will fail" into "I ran it and it failed".
#
# Why this hook exists at all (root-caused 2026-07-27, ticket APP-2179):
#
#   The prohibition was PROSE ONLY — CLAUDE.md and docs/agents/submodules.md. No
#   hook, no deny rule, nothing in settings.json mentioned submodules. So the
#   rule was unenforced against a real write, while a read-only proof got blocked
#   anyway by something else entirely: Claude Code's auto-mode permission
#   classifier. On that run it silently denied 8 commands, among them
#
#     git -C shared-lib checkout --detach origin/feature/APP-2179 && ls … && ./scripts/dev.sh test …
#     git -C … status --porcelain | head -30
#     git show origin/feature/APP-2179:src/routes/…rs | sed -n '236,300p'
#
#   None of those writes anything. They fell to the classifier because a STATIC
#   allow rule like `Bash(git *)` prefix-matches the WHOLE command string, so any
#   compound command — `cd X && …`, a pipe, a heredoc — matches no allow rule and
#   goes to the classifier, which denies conservatively. The reviewer then had to
#   downgrade a hard finding to "unverified" and hand it back to a human.
#
#   So this guard does both halves:
#     DENY  — a real mutation inside a submodule checkout (the actual rule).
#     ALLOW — read-only inspection and a bare ref checkout in one, pre-empting the
#             classifier so a proof run is not blocked by accident.
#
# The ALLOW half is deliberately narrow. It is emitted ONLY when the command
# touches a submodule AND **every** segment of the command is in the recognized
# safe set. One unrecognized segment and the hook says nothing at all (exit 0) and
# the normal permission flow decides — because `permissionDecision: allow` applies
# to the WHOLE command, so `git status && <anything>` must never be waved through
# on the strength of its first segment.
#
# It also never emits ALLOW for a command that mentions a secrets file: `git show
# <ref>:.env` is read-only and still a leak, and that call belongs to
# pretool-env-guard.sh. This guard steps aside so that one can do its job.
#
# Exit 0 = no opinion (normal flow continues) · exit 2 = block, stderr goes to the
# model · JSON permissionDecision=allow on stdout = pre-approved, classifier skipped.
# Fails OPEN on anything it cannot determine.

set -uo pipefail

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"

# --- helpers ---------------------------------------------------------------

# Print the superproject working tree for <dir>, empty if <dir> is not inside a
# submodule. This is the official test (docs/agents/submodules.md) and beats
# sniffing for a `.git` FILE, which is also how a linked git worktree looks.
superproject_of() {
  local d=$1
  [ -n "$d" ] || return 0
  while [ ! -d "$d" ] && [ "$d" != "/" ] && [ -n "$d" ]; do d=$(dirname "$d"); done
  [ -d "$d" ] || return 0
  git -C "$d" rev-parse --show-superproject-working-tree 2>/dev/null
}

# Where the change SHOULD go: the primary clone of the same repo at the workspace
# root, resolved from the submodule's own origin URL (never a hardcoded list).
primary_clone_for() {
  local sub=$1 url repo
  url=$(git -C "$sub" config --get remote.origin.url 2>/dev/null) || return 0
  repo=$(basename "${url%.git}")
  [ -n "$repo" ] && printf '%s/%s' "$ROOT" "$repo"
}

deny_write() { # <target-path-or-dir> <what>
  local target=$1 what=$2 sup primary
  sup=$(superproject_of "$target")
  [ -n "$sup" ] || return 1
  local subroot
  subroot=$(git -C "$(dirname "$target")" rev-parse --show-toplevel 2>/dev/null) \
    || subroot=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$subroot" ] || subroot=$target
  primary=$(primary_clone_for "$subroot")
  [ -n "$primary" ] || primary="the repo's primary clone at the workspace root"
  printf '⛔ Blocked: %s inside a git SUBMODULE checkout.\n\n' "$what" >&2
  printf '  submodule checkout   : %s\n' "$subroot" >&2
  printf '  superproject         : %s\n' "$sup" >&2
  printf '  develop here instead : %s\n\n' "$primary" >&2
  cat >&2 <<'EOF'
A submodule checkout is a read-only pointer — a detached-HEAD snapshot the
superproject pins to one commit. The code belongs to a repo that is ALSO cloned as
its own primary clone at the workspace root; branch, commit and open the PR/MR
there, then bump the superproject pointer as a separate, deliberate step.

Reading it is fine, and so is checking out a ref inside it to PROVE something
(`git -C <sub> checkout <ref>`, `fetch`, `show`, `status`, `diff`, `log`) — this
guard blocks only creating, editing and committing. See docs/agents/submodules.md.
EOF
  return 0
}

# Echo the tokens of a git segment that come AFTER its subcommand.
#
# Needed because `git -C <dir> checkout <ref>` carries a `-C` that is NOT a checkout
# flag. Reading flags from the whole segment made this guard DENY the very proof
# checkout it exists to permit — caught by its own smoke test, 2026-07-27, and the
# reason the flag scans below are anchored to the post-subcommand tokens only.
args_after_sub() { # <segment> <subcommand>
  printf '%s' "$1" | awk -v want="$2" '{
    seen=0
    for(i=2;i<=NF;i++){
      if(seen){ printf "%s ", $i; continue }
      if($i==want) seen=1
    }
  }'
}

# --- Write / Edit ----------------------------------------------------------

case "$tool" in
  Write|Edit|NotebookEdit)
    path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
    [ -z "$path" ] && exit 0
    case "$path" in /*) ;; *) path="$ROOT/$path" ;; esac
    if deny_write "$(dirname "$path")" "writing $(basename "$path")"; then exit 2; fi
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

# --- Bash ------------------------------------------------------------------

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# Never pre-approve anything that names a secrets file — pretool-env-guard.sh owns
# that call, and `git show <ref>:.env` is read-only and still a leak.
secretish=0
case "$cmd" in
  *.env.example*|*.env.sample*) ;;
  *.env*|*id_rsa*|*id_ed25519*|*.pem*|*credentials*|*secrets/*) secretish=1 ;;
esac

# Normalise the file-descriptor redirections BEFORE splitting. The separator split
# below cuts on a lone `&`, which slices `2>&1` into the junk segments `2>` and `1`
# — neither is a recognized safe command, so `git … checkout … 2>&1 | tail -2` fell
# out of the safe set and lost its pre-approval. That is the single most common
# shape a proof command takes, so it has to survive the split (measured 2026-07-27:
# it was the exact command the classifier denied).
#   `2>&1`, `1>&2`  — fd duplication, writes nothing → drop entirely
#   `&>file`        — redirects BOTH streams to a file → rewrite to `>` so the
#                     write-target check below still sees the path
cmd_norm=$(printf '%s' "$cmd" | sed -E 's/[0-9]*>&[0-9-]+//g; s/&>>?/>/g')

# Split on shell separators so each invocation is judged with only its own
# arguments in view (same reasoning as pretool-git-guard.sh).
segments=$(printf '%s' "$cmd_norm" | sed -E 's/(\|\||&&|[;|&])/\n/g')

# git subcommands that only READ, plus the ref moves a proof run needs. `checkout`
# and `switch` are here WITHOUT -b/-c/-B/-orphan (branch creation is handled below).
SAFE_GIT='status|show|log|diff|show-ref|rev-parse|rev-list|ls-files|ls-tree|ls-remote|cat-file|grep|describe|blame|shortlog|merge-base|name-rev|for-each-ref|fetch|checkout|switch|restore|worktree|submodule|remote|config|branch|tag|stash|symbolic-ref|count-objects|verify-commit|whatchanged|check-ignore|check-attr|var|help|version'

# git subcommands that WRITE the submodule's own history or index.
MUT_GIT='add|commit|push|merge|rebase|cherry-pick|revert|am|apply|rm|mv|clean|reset|update-index|update-ref|commit-tree|hash-object|write-tree|filter-branch|gc|prune|repack|notes|replace|bisect'

# Non-git commands that create or modify files.
WRITER_CMD='cp|mv|rm|rmdir|install|touch|mkdir|chmod|chown|ln|dd|truncate|patch|tee|shred|unlink'

touches_submodule=0
all_safe=1
cwd="$ROOT"

resolve() { # <maybe-relative-path> -> absolute, against the tracked cwd
  case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$cwd" "$1" ;; esac
}

while IFS= read -r seg; do
  # strip leading whitespace and env-var prefixes (FOO=bar cmd …)
  seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//')
  [ -z "$seg" ] && continue

  # Track `cd <dir>` so a later segment's relative paths resolve correctly.
  case "$seg" in
    cd\ *)
      d=$(printf '%s' "$seg" | awk '{print $2}' | tr -d '"'\''')
      [ -n "$d" ] && cwd=$(resolve "$d")
      continue ;;
  esac

  word=$(printf '%s' "$seg" | awk '{print $1}')
  word=${word##*/}   # /usr/bin/git -> git

  # ---- redirection into a submodule path is a write -----------------------
  if printf '%s' "$seg" | grep -qE '>>?[[:space:]]*[^[:space:]&|]'; then
    tgt=$(printf '%s' "$seg" | sed -E 's/.*>>?[[:space:]]*//' | awk '{print $1}' | tr -d '"'\''')
    if [ -n "$tgt" ] && deny_write "$(dirname "$(resolve "$tgt")")" "redirecting output into"; then exit 2; fi
  fi

  if [ "$word" = "git" ]; then
    # Honour an explicit `git -C <dir>`; awk, not sed — see pretool-git-guard.sh
    # for why the obvious sed back-reference is broken on BSD sed.
    gdir=$(printf '%s' "$seg" | awk '{for(i=1;i<NF;i++) if($i=="-C"){v=$(i+1); gsub(/^["\x27]|["\x27]$/,"",v); print v; exit}}')
    tdir="$cwd"; [ -n "$gdir" ] && tdir=$(resolve "$gdir")

    # first non-flag token after `git` (and after -C <dir>) is the subcommand
    sub=$(printf '%s' "$seg" | awk '{
      for(i=2;i<=NF;i++){
        if($i=="-C"||$i=="-c"||$i=="--git-dir"||$i=="--work-tree"){i++; continue}
        if(substr($i,1,1)=="-") continue
        print $i; exit
      }}')

    # Everything after the subcommand — NEVER the whole segment, or `git -C <dir>`
    # reads as a branch-creating `-C`.
    subargs=$(args_after_sub "$seg" "$sub")

    writes=0
    case "$sub" in
      # A bare ref checkout/switch/restore only moves the working tree to a commit
      # that already exists — that is the proof move, and it stays allowed. Creating
      # a branch does not.
      checkout)
        printf '%s' "$subargs" | grep -qE '(^|[[:space:]])(-b|-B|--orphan)([[:space:]]|$)' && writes=1 ;;
      switch)
        printf '%s' "$subargs" | grep -qE '(^|[[:space:]])(-c|-C|--orphan)([[:space:]]|$)' && writes=1 ;;
      branch)
        printf '%s' "$subargs" | grep -qE '(^|[[:space:]])(-d|-D|-m|-M|--delete|--move)([[:space:]]|$)' && writes=1
        # `git branch <newname>` with a bare operand also creates one
        printf '%s' "$subargs" | grep -qE '^[[:space:]]*[^-[:space:]]' && writes=1 ;;
      worktree)
        printf '%s' "$subargs" | grep -qE '^[[:space:]]*(list|lock|unlock)([[:space:]]|$)' || writes=1 ;;
      stash)
        # `stash` / `stash list|show` read; push/pop/apply/drop/clear rewrite.
        printf '%s' "$subargs" | grep -qE '^[[:space:]]*(list|show)?[[:space:]]*$' || writes=1 ;;
      config)
        printf '%s' "$subargs" | grep -qE '(--get|--get-all|--get-regexp|--list|-l)([[:space:]]|$)' || writes=1 ;;
      tag)
        printf '%s' "$subargs" | grep -qE '(^|[[:space:]])(-l|--list)([[:space:]]|$)' || writes=1 ;;
      submodule)
        printf '%s' "$subargs" | grep -qE '^[[:space:]]*(status|summary|foreach)([[:space:]]|$)' || writes=1 ;;
      restore)
        # `restore` overwrites working-tree files from a ref — a write, unlike checkout
        # of a whole ref, which is what a proof run needs.
        writes=1 ;;
      fetch)
        # fetch only moves remote-tracking refs; it never touches tracked files.
        : ;;
    esac

    if printf '%s' "$sub" | grep -qE "^($MUT_GIT)$" || [ "$writes" = 1 ]; then
      if deny_write "$tdir" "\`git $sub\` (a history/index write)"; then exit 2; fi
      all_safe=0
      continue
    fi

    if printf '%s' "$sub" | grep -qE "^($SAFE_GIT)$"; then
      [ -n "$(superproject_of "$tdir")" ] && touches_submodule=1
      # a submodule path named as an operand counts too: `git show HEAD:shared-lib/x`
      for tok in $seg; do
        case "$tok" in
          -*|git) continue ;;
          */*) [ -n "$(superproject_of "$(resolve "${tok%%:*}")")" ] && touches_submodule=1 ;;
        esac
      done
      continue
    fi
    all_safe=0
    continue
  fi

  # ---- non-git writers ---------------------------------------------------
  if printf '%s' "$word" | grep -qE "^($WRITER_CMD)$"; then
    for tok in $seg; do
      case "$tok" in
        -*|"$word") continue ;;
      esac
      if deny_write "$(dirname "$(resolve "$tok")")" "\`$word\` (a filesystem write)"; then exit 2; fi
    done
    all_safe=0
    continue
  fi

  # `sed -i` / in-place editors
  if [ "$word" = "sed" ] && printf '%s' "$seg" | grep -qE '(^|[[:space:]])-i'; then
    for tok in $seg; do
      case "$tok" in -*|sed) continue ;; esac
      if deny_write "$(dirname "$(resolve "$tok")")" "\`sed -i\` (an in-place edit)"; then exit 2; fi
    done
    all_safe=0
    continue
  fi

  # Read-only shell plumbing a proof command is normally wrapped in.
  case "$word" in
    ls|cat|head|tail|wc|grep|rg|awk|sed|cut|sort|uniq|tr|echo|printf|test|true|pwd|dirname|basename|find|file|stat|jq|column|tee-notused) continue ;;
  esac

  all_safe=0
done <<EOF
$segments
EOF

# --- the ALLOW half -------------------------------------------------------
# Only when the command genuinely touches a submodule, every segment is in the
# recognized safe set, and nothing secrets-shaped is named.
if [ "$touches_submodule" = 1 ] && [ "$all_safe" = 1 ] && [ "$secretish" = 0 ]; then
  jq -cn '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "Read-only submodule inspection / bare ref checkout — no create, edit or commit. Pre-approved by pretool-submodule-guard.sh so a proof run is not blocked by the auto-mode classifier (see docs/agents/submodules.md)."
    }
  }'
  exit 0
fi

exit 0
