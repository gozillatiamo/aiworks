#!/usr/bin/env bash
#
# PreToolUse/PostToolUse(Read|Write|Edit) hook — when a tool reaches into a product
# repo from a workspace-root session, inject that repo's own instruction and the
# rules that apply to the touched file.
#
# WHY: neither tool loads a nested repo's configuration when the session is rooted
# at the meta-repo.
#   • Cursor loads nothing from a subdirectory — measured: no nested AGENTS.md, no
#     nested .cursor/rules, no nested .cursor/skills, even after the agent has read
#     a file inside that subtree. The multi-root ai-workspace.code-workspace does not
#     change it either.
#   • Claude Code does pick up a nested CLAUDE.md, but .claude/rules/ is
#     project-scoped, so a repo's rules are missed the same way.
# The result in both is an agent editing, say, backoffice/src while holding none of
# backoffice's conventions. This hook closes that by hand, deterministically —
# a prose reminder to "go read the repo's rules" was the approach that already
# failed twice in this workspace (see docs/agents/language.md).
#
# Scope and cost:
#   • Only fires when the session root IS the meta-repo (it has workspace.config.yaml).
#     Open a repo directly and the tool loads its config natively — this stays quiet.
#   • ONCE per (session, repo). The first touch pays; every later one is a no-op.
#   • Injects <repo>/CLAUDE.md plus only those .claude/rules whose globs match the
#     touched path — usually one — under a hard size cap.
#
# Wired on BOTH PreToolUse and PostToolUse on purpose: the two tools do not agree on
# which events accept injected context, and the once-per-repo state file means
# whichever fires first wins and the other is a no-op.
#
# Fails open on anything unexpected: a missing repo, unreadable file, no jq.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -n "$path" ] || exit 0

event=$(printf '%s' "$input" | jq -r '.hook_event_name // "PreToolUse"' 2>/dev/null)
session=$(printf '%s' "$input" | jq -r '.session_id // .conversation_id // "nosession"' 2>/dev/null)

root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$root" ] || exit 0
# Only a meta-repo-rooted session has this problem.
[ -f "$root/workspace.config.yaml" ] || exit 0

# Which repo does the touched path fall into? Accept absolute or root-relative.
rel="$path"
case "$rel" in "$root"/*) rel="${rel#"$root"/}" ;; /*) exit 0 ;; esac
repo="${rel%%/*}"
inrepo="${rel#*/}"
[ -n "$repo" ] && [ "$repo" != "$rel" ] || exit 0
[ -f "$root/$repo/CLAUDE.md" ] || exit 0        # not a product repo we know about

# Once per session per repo — but keyed on the tool call that claimed it, not on
# the repo alone. Both tools invoke a hook more than once for a single tool call
# (Cursor does it for every Read), and a marker that ignored that would let the
# first invocation emit the context and the second return nothing, with the empty
# second result overwriting the first. So a repeat of the SAME tool call re-emits;
# only a genuinely new call is suppressed.
call=$(printf '%s' "$input" | jq -r '.tool_use_id // .tool_call_id // "nocall"' 2>/dev/null)
claim="$call@$event"
state="${TMPDIR:-/tmp}/aiworks-repo-context/$session"
mkdir -p "$state" 2>/dev/null || exit 0
marker="$state/$repo"
if [ -e "$marker" ]; then
  # Same call AND same event = a repeat invocation, re-emit. A different event for
  # the same call is the Pre/Post pair, which would inject the identical text twice.
  [ "$(cat "$marker" 2>/dev/null)" = "$claim" ] || exit 0
else
  printf '%s' "$claim" > "$marker" 2>/dev/null || exit 0
fi

# A rule's glob, as a regex. `**/` may match nothing, `**` crosses directories,
# `*` and `?` stay within one segment.
glob_to_regex() {
  printf '%s' "$1" | awk '{
    gsub(/[.+^$(){}|\[\]]/, "\\\\&")
    gsub(/\*\*\//, "\001")
    gsub(/\*\*/,   "\002")
    gsub(/\*/,     "[^/]*")
    gsub(/\?/,     "[^/]")
    gsub(/\001/,   "(.*/)?")
    gsub(/\002/,   ".*")
    print "^" $0 "$"
  }'
}

# Rules whose paths:/globs: cover this file. Both keys are read: they are kept in
# step by `aiworks cursor`, but a hand-added rule may carry only one.
matched=""
if [ -d "$root/$repo/.claude/rules" ]; then
  while IFS= read -r rf; do
    globs=$(awk '
      /^---[ \t]*$/ { fm++; if (fm >= 2) exit; next }
      fm != 1 { next }
      /^(paths|globs):/ { ing = 1
                          rest = $0; sub(/^[a-z]+:[ \t]*/, "", rest)
                          if (rest != "") { gsub(/^\[|\]$/, "", rest); print rest }
                          next }
      ing && /^[ \t]+-[ \t]/ { sub(/^[ \t]+-[ \t]*/, ""); print; next }
      ing && /^[A-Za-z_]/ { ing = 0 }
    ' "$rf" | tr -d "\"'" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$')
    [ -n "$globs" ] || continue
    while IFS= read -r g; do
      if printf '%s' "$inrepo" | grep -qE "$(glob_to_regex "$g")"; then
        matched="${matched}${rf}"$'\n'
        break
      fi
    done <<EOF
$globs
EOF
  done < <(find "$root/$repo/.claude/rules" -type f -name '*.md' 2>/dev/null | sort)
fi

# Build the payload, capped so a repo with many large rules cannot flood the window.
CAP=24576
ctx="You are touching \`$repo/\`, a product repo of this multi-repo workspace. Neither
Cursor nor Claude Code loads a nested repo's own configuration from a workspace-root
session, so it is injected here — once for this repo, this session.

===== $repo/CLAUDE.md =====
$(cat "$root/$repo/CLAUDE.md" 2>/dev/null)"

while IFS= read -r rf; do
  [ -n "$rf" ] || continue
  [ "${#ctx}" -lt "$CAP" ] || { ctx="$ctx

(Further matching rules omitted for size — read them under $repo/.claude/rules/.)"; break; }
  ctx="$ctx

===== ${rf#"$root"/} (matches $inrepo) =====
$(cat "$rf" 2>/dev/null)"
done <<EOF
$matched
EOF

jq -n --arg ctx "$ctx" --arg ev "$event" \
  '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
exit 0
