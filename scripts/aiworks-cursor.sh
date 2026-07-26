#!/usr/bin/env bash
#
# aiworks-cursor.sh  (run it as: aiworks cursor) — project the workspace's agent
# configuration onto Cursor, for the workspace root and every product repo.
#
# The workspace is authored for Claude Code: CLAUDE.md, .claude/rules/,
# .claude/skills/, .claude/agents/, .claude/settings.json, .mcp.json. Cursor reads
# NONE of those verbatim — it wants AGENTS.md, .cursor/rules/*.mdc,
# .cursor/skills/, .cursor/agents/, .cursor/hooks.json, .cursor/cli.json,
# .cursor/mcp.json. This script builds that second face WITHOUT duplicating any
# content: everything whose format is already compatible becomes a SYMLINK back to
# the Claude-side file, so there is exactly one copy of every rule, skill, and
# agent on disk and no drift is possible.
#
# What IS generated, because its format has no common shape to link:
#   .cursor/hooks.json        Claude's hook block, re-expressed in Cursor's schema
#   .cursor/cli.json          Claude's permissions, re-expressed in Cursor's schema
#   .cursor/hooks/hook-shim.sh  a copy of scripts/cursor/hook-shim.template.sh
#   .cursor/rules/repos/<repo>/  (root only) each repo's instruction and rules with
#                             every glob prefixed by the repo dir, so they work for a
#                             session opened at the workspace root — see below
#
# hook-shim.sh is a copy rather than a symlink on purpose: the .cursor/ layer is
# committed into each product repo so a standalone clone still works, and a symlink
# from inside a repo to the workspace root would dangle in such a clone. `--check`
# hashes it back against the template so the copy can never silently drift.
#
# NOT covered — Cursor has no equivalent: .claude/workflows/ (dev-cycle, prd, brd).
# Those stay Claude Code only. See docs/agents/cursor.md.
#
# IDEMPOTENT: a link or file that is already correct is left alone and reported as
# ok. Existing Cursor artefacts that a human wrote (a repo's own .cursor/mcp.json,
# a hand-written .cursor/rules/<name>/RULE.mdc) are NEVER clobbered — they are
# reported so you can decide.
#
# Usage:
#   aiworks cursor [<repo>…] [options]
#
#   <repo>…        Only these targets. Use the repo's dir name, or `root` for the
#                  workspace root itself. Default: the root + every repo declared
#                  under products[].repos[] in workspace.config.yaml.
#   --check        Verify only: write nothing, report every drift/missing/broken
#                  link, exit 1 if anything is off. Use it in CI.
#   --user         Also link the enabled Claude plugin skills into ~/.agents/skills
#                  so Cursor can see them (personal machine state; never committed).
#   -v, --verbose  Show every link, not just the per-target summary.
#   -h, --help     Show this help.
#
set -uo pipefail

# ── pretty logging (same surface as aiworks-add.sh / aiworks-remove.sh) ────────
c_step=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_step=; c_ok=; c_warn=; c_err=; c_dim=; c_off=; }
VERBOSE=0; CHECK=0; USER_SCOPE=0
step() { printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { [[ "$VERBOSE" -eq 1 ]] && printf '    %s✓ %s%s\n' "$c_ok" "$*" "$c_off"; return 0; }
dim()  { [[ "$VERBOSE" -eq 1 ]] && printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; return 0; }
warn() { printf '    %s! %s%s\n' "$c_warn" "$*" "$c_off"; }
die()  { printf '%serror: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; }

DRIFT=0        # anything --check would flag
CHANGED=0      # anything actually written this run
NOTES=()       # human decisions we refuse to make automatically

note() { NOTES+=("$*"); warn "$*"; }
drift() { DRIFT=$((DRIFT+1)); printf '    %s✗ %s%s\n' "$c_err" "$*" "$c_off"; }

# Kept as a space-joined string rather than an array: macOS still ships bash 3.2,
# where an empty array expands badly under `set -u`. Repo names never contain spaces.
TARGETS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)        CHECK=1 ;;
    --user)         USER_SCOPE=1 ;;
    -v|--verbose)   VERBOSE=1 ;;
    -h|--help)      usage; exit 0 ;;
    --all)          : ;;   # accepted for symmetry with `aiworks remove --all`
    -*)             die "unknown option: $1 (try -h)" ;;
    *)              TARGETS="${TARGETS:+$TARGETS }$1" ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$ROOT/mani.yaml" ]] || die "no mani.yaml in $ROOT — run this from a workspace"
WC="$ROOT/workspace.config.yaml"
[[ -f "$WC" ]] || die "no workspace.config.yaml in $ROOT"
TEMPLATE="$ROOT/scripts/cursor/hook-shim.template.sh"
[[ -f "$TEMPLATE" ]] || die "missing $TEMPLATE — the shim template is the source for every repo's copy"
AWKRULE="$ROOT/scripts/cursor/root-rule.awk"
[[ -f "$AWKRULE" ]] || die "missing $AWKRULE — needed to re-scope a repo's rules for a root session"
command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"

# Parse products[].repos[] → repo dir names. Same indentation contract as
# aiworks-sync.sh: products: at col 0, `  - id:` per product, `    repos:`,
# `      - url:` per repo, `        <field>:`.
parse_repo_dirs() {
  awk '
    function val(s){ sub(/^[^:]*:[ \t]*/,"",s); sub(/[ \t]+#.*$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
    function setkv(line){ k=line; sub(/^[ \t]*/,"",k)
      if(k ~ /^url:/) url=val(k); else if(k ~ /^path:/) path=val(k) }
    function flush(){ if(url!=""){ d=path; if(d==""){ d=url; sub(/\.git$/,"",d); sub(/^.*\//,"",d) } print d }
      url=""; path="" }
    /^products:[ \t]*$/ { inp=1; next }
    inp && /^  - id:/ { flush(); inrepos=0; next }
    inp && /^    repos:[ \t]*$/ { inrepos=1; next }
    inp && /^    [A-Za-z_]/ { inrepos=0; next }
    inrepos && /^      - / { flush(); l=$0; sub(/^      - /,"",l); setkv(l); next }
    inrepos && /^        [A-Za-z_]/ { setkv($0); next }
    /^[A-Za-z_]/ { flush(); inp=0; inrepos=0 }
    END{ flush() }
  ' "$WC"
}

# ── primitives ────────────────────────────────────────────────────────────────

# Collapse `a/b/../c` to `a/c` textually. Needed because a link's target is written
# relative to a .cursor/ directory that may not exist yet, and `test -e` on a path
# routed through a missing directory is false even when the real target is there.
norm() {
  local p="$1" prev=""
  while [[ "$p" != "$prev" ]]; do prev="$p"; p="${p//\/.\///}"; p="$(printf '%s' "$p" | sed -E 's#(^|/)[^/]+/\.\./#\1#g')"; done
  printf '%s' "$p"
}

# link <link-path> <target-relative-to-link-dir> <label>
# Creates (or verifies) a relative symlink. Refuses to replace a real file/dir.
link() {
  local lnk="$1" tgt="$2" label="$3" dir; dir="$(dirname "$lnk")"
  if [[ ! -e "$(norm "$dir/$tgt")" ]]; then dim "skip $label — no $tgt to link to"; return 0; fi
  if [[ -L "$lnk" ]]; then
    if [[ "$(readlink "$lnk")" == "$tgt" ]]; then ok "$label"; return 0; fi
    if [[ "$CHECK" -eq 1 ]]; then drift "$label points at $(readlink "$lnk"), expected $tgt"; return 0; fi
    rm -f "$lnk"
  elif [[ -e "$lnk" ]]; then
    note "$label: $lnk is a real file/dir, not a link — resolve it by hand, leaving it alone"
    return 0
  fi
  if [[ "$CHECK" -eq 1 ]]; then drift "$label missing"; return 0; fi
  mkdir -p "$dir" && ln -s "$tgt" "$lnk" && { CHANGED=$((CHANGED+1)); ok "$label -> $tgt"; }
}

# emit <path> <label> < content-on-stdin
# Writes a generated file, or in --check mode diffs it against what we would write.
emit() {
  local path="$1" label="$2" tmp; tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; ok "$label"; return 0; fi
  if [[ "$CHECK" -eq 1 ]]; then
    [[ -f "$path" ]] && drift "$label is stale" || drift "$label missing"
    rm -f "$tmp"; return 0
  fi
  mkdir -p "$(dirname "$path")" && mv "$tmp" "$path" && { CHANGED=$((CHANGED+1)); ok "$label written"; }
}

# ── .cursor/rules — one .mdc symlink per .claude/rules markdown file ──────────
# The .mdc extension is required (Cursor ignores plain .md under .cursor/rules),
# but the CONTENT is identical: rule files carry both `paths:` (Claude) and
# `globs:` (Cursor) in their frontmatter, and each side ignores the other's key.
# So the extension is all the symlink has to provide. Nested dirs (coding_standards/)
# are mirrored so a rule's path keeps its meaning.

# A rule file is read by BOTH tools through the same inode, so its frontmatter has
# to satisfy both vocabularies: Claude scopes a rule with `paths:`, Cursor with
# `globs:`. Each ignores the key it does not know, so carrying both is safe and is
# what makes the symlink possible at all. This mirrors `paths:` into `globs:` in
# place, idempotently — a rule that already has `globs:`, or that has neither key
# (description-only, which Cursor treats as apply-intelligently and Claude as
# always-eligible), is left exactly as it is.
ensure_dual_key() {
  local f="$1" label="$2" tmp
  # Only look at the frontmatter block, not at prose that happens to start with globs:.
  awk '/^---[ \t]*$/{fm++; next} fm==1 && /^globs:/{found=1} fm>1{exit} END{exit !found}' "$f" && { return 0; }
  tmp="$(mktemp)"
  awk '
    function flush(){ if(inpaths){ if(buf!="") printf "globs:\n%s", buf; inpaths=0; buf="" } }
    /^---[ \t]*$/                      { if (fm==1) flush(); fm++; print; next }
    fm==1 && /^paths:[ \t]*$/          { print; inpaths=1; buf=""; next }
    fm==1 && inpaths && /^[ \t]+-[ \t]/{ print; buf = buf $0 "\n"; next }
    fm==1 && inpaths                   { flush(); print; next }
    fm==1 && /^paths:[ \t]*[^ \t]/     { print; v=$0; sub(/^paths:[ \t]*/,"",v); print "globs: " v; next }
                                       { print }
  ' "$f" > "$tmp"
  if cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
  if [[ "$CHECK" -eq 1 ]]; then drift "$label has paths: but no globs: — Cursor cannot scope it"; rm -f "$tmp"; return 0; fi
  mv "$tmp" "$f" && { CHANGED=$((CHANGED+1)); ok "$label frontmatter now carries globs: alongside paths:"; }
}

sync_rules() {
  local base="$1" src="$1/.claude/rules" dst="$1/.cursor/rules"
  [[ -d "$src" ]] || { dim "no .claude/rules"; return 0; }
  local f rel lnk up depth
  while IFS= read -r f; do
    rel="${f#"$src"/}"
    ensure_dual_key "$f" "rules/$rel"
    lnk="$dst/${rel%.md}.mdc"
    depth=$(( $(printf '%s' "${lnk#"$base"/}" | tr -cd '/' | wc -c) ))
    up=""; for ((i=0;i<depth;i++)); do up+="../"; done
    link "$lnk" "${up}.claude/rules/$rel" "rules/${rel%.md}.mdc"
  done < <(find "$src" -type f -name '*.md' | sort)

  # Drop .mdc links we own whose Claude-side source is gone.
  [[ -d "$dst" ]] || return 0
  while IFS= read -r lnk; do
    [[ -L "$lnk" ]] || continue
    [[ -e "$lnk" ]] && continue
    if [[ "$CHECK" -eq 1 ]]; then drift "dangling rule link ${lnk#"$base"/}"; else
      rm -f "$lnk"; CHANGED=$((CHANGED+1)); ok "removed dangling ${lnk#"$base"/}"
    fi
  done < <(find "$dst" -name '*.mdc' 2>/dev/null)
}

# ── .cursor/hooks.json — Claude's hook block in Cursor's schema ───────────────
# Every command is wrapped in the shim so the hook scripts themselves stay
# single-source and Claude-shaped. Events Cursor does not implement
# (Notification, PermissionRequest) are dropped; matchers naming a tool Cursor
# does not have (Glob, WebFetch, WebSearch) are dropped with a note.
gen_hooks_json() {
  local settings="$1"
  jq -c '
    def event_map: {
      "PreToolUse":       "preToolUse",
      "PostToolUse":      "postToolUse",
      "UserPromptSubmit": "beforeSubmitPrompt",
      "SessionStart":     "sessionStart",
      "SessionEnd":       "sessionEnd",
      "Stop":             "stop",
      "SubagentStop":     "subagentStop",
      "PreCompact":       "preCompact"
    };
    # Claude tool names -> Cursor tool names, confirmed by capturing real preToolUse
    # payloads: the shell tool is "Shell", the subagent tool is "Task" (and its
    # tool_input carries the same description/prompt/subagent_type the guard reads).
    # Read/Write/Edit keep their names. Glob/WebFetch/WebSearch have no Cursor tool.
    def matcher_map(m):
      (m | gsub("\\bBash\\b"; "Shell") | gsub("\\bAgent\\b"; "Task")) as $m
      | if ($m == "*" or $m == "") then null else $m end;
    def unsupported(m): (m // "") | test("\\b(Glob|WebFetch|WebSearch)\\b");

    (.hooks // {}) as $h
    | reduce (event_map | to_entries[]) as $e ({};
        ($h[$e.key] // []) as $groups
        | ($groups
           | map(select(unsupported(.matcher) | not)
                 | .matcher as $m
                 | (.hooks // [])
                 | map(select(.type == "command")
                       | { command: ("./.cursor/hooks/hook-shim.sh " + (.command | @sh)) }
                       + (if (.timeout // null) != null then {timeout: .timeout} else {} end)
                       + (if matcher_map($m // "*") != null then {matcher: matcher_map($m)} else {} end)))
           | flatten) as $entries
        | if ($entries | length) > 0 then .[$e.value] = $entries else . end)
    | {version: 1, hooks: .}
  ' "$settings" | jq .
}

# ── .cursor/cli.json — Claude's permissions in Cursor's schema ────────────────
#   Bash(x)          -> Shell(x)          Edit(x)  -> Write(x)   (Cursor has no Edit)
#   Read/Write bare  -> Read(**)/Write(**)          (Cursor entries always take an arg)
#   mcp__srv         -> Mcp(srv:*)        mcp__srv__tool -> Mcp(srv:tool)
#   Grep/Glob/Skill/WebSearch — no Cursor permission type, dropped.
# Deny beats allow in both models, so the safety half survives the translation.
gen_cli_json() {
  local settings="$1"
  jq -c '
    # `Read(//etc/**)` in settings.json is a stray double slash Claude tolerates;
    # normalise it so the Cursor entry addresses a real path.
    def tidy: gsub("\\(//"; "(/");
    def conv:
      (. | tidy) as $e
      | if   ($e | test("^Bash\\(")) then ($e | sub("^Bash\\("; "Shell("))
        elif ($e | test("^Edit\\(")) then ($e | sub("^Edit\\("; "Write("))
        elif ($e | test("^(Read|Write|WebFetch)\\(")) then $e
        elif ($e == "Read")  then "Read(**)"
        elif ($e == "Write") then "Write(**)"
        elif ($e == "Edit")  then "Write(**)"
        elif ($e | test("^mcp__[a-zA-Z0-9_]+__")) then
             ($e | sub("^mcp__"; "") | sub("__"; ":") | "Mcp(" + . + ")")
        elif ($e | test("^mcp__")) then ($e | sub("^mcp__"; "") | "Mcp(" + . + ":*)")
        else null end;
    {permissions: {
       allow: [((.permissions.allow // [])[] | conv) | select(. != null)] | unique,
       deny:  [((.permissions.deny  // [])[] | conv) | select(. != null)] | unique
    }}
  ' "$settings" | jq .
}

# ── dead hook copies ──────────────────────────────────────────────────────────
# Four repos were found carrying byte-identical copies of workspace-root hooks that
# their own settings.json never wired and nothing else referenced — dead weight, and
# in one case a revision older than the root's. Reported, never deleted: whether a
# copy is dead or is someone's work in progress is a human call. This lives in the
# Cursor generator because --check became the workspace's one verify entry point,
# and because a stale hook is exactly what the generator would otherwise wire into
# .cursor/hooks.json without comment.
#
# TOP LEVEL ONLY (-maxdepth 1). Subdirectories of .claude/hooks/ are bundles that
# aiworks add installs whole — dev-wrapper/, caveman-statusline/ — where most members
# are legitimately unwired in a given repo. Flagging each of those would bury the
# real finding in noise, and a check nobody reads catches nothing.
check_dead_hook_copies() {
  local base="$1" name="$2" src="$1/.claude/hooks" settings="$1/.claude/settings.json"
  [[ -d "$src" && -f "$settings" ]] || return 0
  local f rel
  while IFS= read -r f; do
    rel="${f#"$src"/}"
    [[ -f "$ROOT/.claude/hooks/$rel" ]] || continue          # not a copy of a root hook
    cmp -s "$f" "$ROOT/.claude/hooks/$rel" || continue       # diverged — leave it alone
    grep -qF "$(basename "$rel")" "$settings" 2>/dev/null && continue   # actually wired
    note "$name: .claude/hooks/$rel duplicates the root hook and no settings.json wires it — dead copy, delete it and let the root keep the only one"
  done < <(find "$src" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort)
}

# ── the workspace root's per-repo rule slices ─────────────────────────────────
# Everything above gives a repo its Cursor face for a session opened INSIDE that
# repo. A session opened at the workspace root gets none of it: Cursor reads no
# configuration from subdirectories, so from the root an agent sees no repo's
# rules and no repo's project instruction. (Measured both with a plain folder and
# with the multi-root .code-workspace — the workspace file restores the Source
# Control panels, not the agent config.)
#
# What Cursor DOES honour from the root is a rule whose glob is path-prefixed:
# a root rule globbed `game/src/**` fires on game/src/adapter.rs and stays silent
# for every other repo. Measured 2026-07-26, seven probe rules over three
# cursor-agent runs, with negative controls and a reciprocal run.
#
# So the root gets a generated slice per repo: the repo's project instruction,
# plus every one of its rules, each re-globbed under the repo's directory.
#
# They are gitignored — derived from twenty-one other git repositories, and
# `aiworks sync` rebuilds them — but HOW they are gitignored decides whether the
# feature works at all:
#
#   .cursor/rules/repos/**/*.mdc     ignores the FILES        Cursor reads them
#   .cursor/rules/repos/             ignores the DIRECTORY    Cursor reads nothing
#
# Measured, one cursor-agent run, four rules with distinct tokens and a tracked
# control: every file-level-ignored rule fired, including one with no negation
# anywhere; the directory-level-ignored ones stayed silent. Cursor prunes an
# ignored directory instead of descending into it, so the rules inside are never
# discovered. Nothing re-includes them afterwards — negating in `.cursorignore` or
# `.cursorindexingignore` does not bring a pruned directory back (also measured;
# Cursor's own docs note that a negation cannot re-include through an excluded
# parent). Cursor's rules docs say nothing about ignore files either way.
#
# The same trap arrives from the other direction: a repo-clone pattern must be
# ANCHORED (`/game/`, not `game/`), because a bare directory pattern matches at
# every depth and excludes `.cursor/rules/repos/game/` too — taking that repo's
# whole slice down with no error anywhere. `aiworks add` writes the anchored form;
# the loop below catches any that slip through.
IGNORE_LINE=".cursor/rules/repos/**/*.mdc"

ensure_gitignore() {
  local gi="$ROOT/.gitignore"
  if ! grep -qxF "$IGNORE_LINE" "$gi" 2>/dev/null; then
    if [[ "$CHECK" -eq 1 ]]; then
      drift ".gitignore does not exclude $IGNORE_LINE — the generated slices would show as untracked"
    else
      {
        printf '\n# Generated by `aiworks cursor`: every product repo'"'"'s instruction and rules,\n'
        printf '# re-globbed so they fire for a Cursor session opened at the workspace root.\n'
        printf '# Derived from the repo clones — regenerated, never committed.\n#\n'
        printf '# FILES, not the directory. A directory pattern makes Cursor skip the whole tree\n'
        printf '# and silently lose every rule in it; excluding only the .mdc files leaves the\n'
        printf '# directories traversable and Cursor still reads them. Measured both ways.\n'
        printf '%s\n' "$IGNORE_LINE"
      } >> "$gi"
      CHANGED=$((CHANGED+1)); ok ".gitignore now excludes $IGNORE_LINE"
    fi
  fi

  # A directory anywhere in this tree being ignored is the silent killer.
  local d p
  for d in "" $*; do
    p="$ROOT/.cursor/rules/repos${d:+/$d}"
    git -C "$ROOT" check-ignore -q "$p" 2>/dev/null || continue
    note "git ignores the DIRECTORY .cursor/rules/repos/${d:+$d/} (pattern \`$(git -C "$ROOT" check-ignore -v "$p" 2>/dev/null | awk -F'\t' '{print $1}' | awk -F: '{print $3}')\`) — Cursor skips an ignored directory, so ${d:-every repo}'s root rules are invisible. Anchor it (\`/${d:-<repo>}/\`) and ignore the files instead"
  done
}

root_slice() {
  # Declared separately: under `set -u`, `local a="$1" b="$a"` makes `a` a
  # declared-but-unset local while the second word is expanded, and the whole run
  # dies on the first repo. Same reason link() splits its `dir`.
  local repo="$1"; local base="$ROOT/$repo"; local dst="$ROOT/.cursor/rules/repos/$repo"
  [[ -d "$base" ]] || { dim "$repo: not cloned — no root slice"; return 0; }
  local src="$base/.claude/rules"; local gen f rel

  if [[ -f "$base/CLAUDE.md" ]]; then
    gen="$(mktemp)"
    {
      printf -- '---\n'
      printf 'description: Project instruction for the `%s` repo — its stack, layout, commands and conventions.\n' "$repo"
      printf 'globs:\n  - "%s/**"\nalwaysApply: false\n---\n\n' "$repo"
      printf 'This is a generated copy of `%s/CLAUDE.md`, the project instruction for the `%s` repo. It governs every file under `%s/` and nothing outside it. That file is authoritative — if it disagrees with the text below, this copy is stale and `aiworks cursor` needs re-running.\n\n' "$repo" "$repo" "$repo"
      cat "$base/CLAUDE.md"
    } > "$gen"
    emit "$dst/00-instruction.mdc" "root repos/$repo/00-instruction.mdc" < "$gen"
    rm -f "$gen"
  fi

  # An "about" card, description-only and deliberately WITHOUT globs. Cursor picks a
  # rule's type from its frontmatter: `globs:` makes it Auto Attached, which the docs
  # define as "auto-attached when a matching file is in context" — so every slice
  # below is invisible until the agent touches one of that repo's files. Asked at the
  # workspace root "what is the data-cy convention in paotung-template?", with no file
  # open, an Auto Attached rule correctly does nothing.
  #
  # A description with NO globs is the other type, Agent Requested: Cursor lists the
  # rule's description and the agent pulls the body in when it judges it relevant.
  # Measured — the same question then answers from the rule, no source file touched.
  #
  # It carries CLAUDE.md inline (a few kB, and it answers most repo-level questions in
  # one hop) plus an INDEX of the repo's rules rather than their text: concatenating
  # them would put 54 kB of agent-webservice into context on any mention of the name.
  # The index points at the generated slices, so each rule body still exists once.
  if [[ -f "$base/CLAUDE.md" || -d "$src" ]]; then
    gen="$(mktemp)"
    {
      printf -- '---\n'
      printf 'description: Everything about the `%s` repo — its stack, layout, commands, conventions and rules. Pull this in for ANY question about `%s` when no file of its own is open in context.\n' "$repo" "$repo"
      printf 'alwaysApply: false\n---\n\n'
      printf '# The `%s` repo\n\n' "$repo"
      printf 'Lives at `%s/` in this workspace. Everything below governs that directory and nothing outside it.\n\n' "$repo"
      if [[ -f "$base/CLAUDE.md" ]]; then
        printf -- '## Project instruction\n\nGenerated from `%s/CLAUDE.md`, which is authoritative.\n\n' "$repo"
        cat "$base/CLAUDE.md"
        printf '\n'
      fi
      if [[ -d "$src" ]]; then
        printf -- '\n## Rules — read the one that covers your question\n\n'
        printf 'Each is a full copy of the repo rule named beside it. They are NOT in context; open the path to read one.\n\n'
        while IFS= read -r f; do
          rel="${f#"$src"/}"
          d=$(awk '/^---[ \t]*$/{fm++; next} fm==1 && /^description:/{sub(/^description:[ \t]*/,""); print; exit} fm>1{exit}' "$f")
          printf -- '- `.cursor/rules/repos/%s/%s.mdc` — %s\n' "$repo" "${rel%.md}" "${d:-the ${rel%.md} rule}"
        done < <(find "$src" -type f -name '*.md' | sort)
      fi
    } > "$gen"
    emit "$dst/about.mdc" "root repos/$repo/about.mdc" < "$gen"
    rm -f "$gen"
  fi

  if [[ -d "$src" ]]; then
    while IFS= read -r f; do
      rel="${f#"$src"/}"
      gen="$(mktemp)"
      awk -v repo="$repo" \
          -v origin="Generated from \`$repo/.claude/rules/$rel\`, which is authoritative — this rule governs the \`$repo\` repo only, and if the source disagrees with the text below, this copy is stale." \
          -v desc="Rule \`${rel%.md}\` from the \`$repo\` repo." \
          -f "$AWKRULE" "$f" > "$gen"
      emit "$dst/${rel%.md}.mdc" "root repos/$repo/${rel%.md}.mdc" < "$gen"
      rm -f "$gen"
    done < <(find "$src" -type f -name '*.md' | sort)
  fi

  # Drop slices whose source rule (or CLAUDE.md) is gone.
  [[ -d "$dst" ]] || return 0
  local m r2 keep
  while IFS= read -r m; do
    r2="${m#"$dst"/}"; keep=0
    if [[ "$r2" == "00-instruction.mdc" ]]; then
      [[ -f "$base/CLAUDE.md" ]] && keep=1
    elif [[ "$r2" == "about.mdc" ]]; then
      { [[ -f "$base/CLAUDE.md" ]] || [[ -d "$src" ]]; } && keep=1
    else
      [[ -f "$src/${r2%.mdc}.md" ]] && keep=1
    fi
    [[ "$keep" -eq 1 ]] && continue
    if [[ "$CHECK" -eq 1 ]]; then drift "stale root rule repos/$repo/$r2"
    else rm -f "$m"; CHANGED=$((CHANGED+1)); ok "removed stale repos/$repo/$r2"; fi
  done < <(find "$dst" -name '*.mdc' 2>/dev/null)
  find "$dst" -type d -empty -delete 2>/dev/null
}

# Whole slices for repos no longer declared in workspace.config.yaml. Only safe on
# a full run — a single-repo run knows nothing about the repos it was not given.
prune_root_slices() {
  local dir="$ROOT/.cursor/rules/repos" keep=" $* " d nm
  [[ -d "$dir" ]] || return 0
  for d in "$dir"/*/; do
    [[ -d "$d" ]] || continue
    nm="$(basename "$d")"
    [[ "$keep" == *" $nm "* ]] && continue
    if [[ "$CHECK" -eq 1 ]]; then drift "root slice for $nm is not a declared repo"
    else rm -rf "$d"; CHANGED=$((CHANGED+1)); ok "removed root slice $nm"; fi
  done
}

# ── one target ────────────────────────────────────────────────────────────────
do_target() {
  local base="$1" name="$2" is_root="$3"
  [[ -d "$base" ]] || { warn "$name: no such directory — skipping"; return 0; }
  step "$name"

  # 1. Project instruction. CLAUDE.md stays canonical; AGENTS.md is its Cursor face.
  if [[ -f "$base/CLAUDE.md" && ! -L "$base/CLAUDE.md" ]]; then
    if [[ -e "$base/AGENTS.md" && ! -L "$base/AGENTS.md" ]]; then
      note "$name: AGENTS.md is a real file with its own content — archive it (git mv to docs/) before this can become a link"
    else
      link "$base/AGENTS.md" "CLAUDE.md" "AGENTS.md"
    fi
  else
    dim "no CLAUDE.md — nothing to expose as AGENTS.md"
  fi

  # 2. Skills and agents: identical on-disk format, so a directory symlink is enough.
  link "$base/.cursor/skills" "../.claude/skills" "skills/"
  link "$base/.cursor/agents" "../.claude/agents" "agents/"

  # 3. Rules: per-file, because the extension has to change.
  sync_rules "$base"

  # 4. MCP: only at the root. Repos that ship their own .cursor/mcp.json (a
  #    repo-specific server like next-devtools) keep it — matching what a
  #    repo-only Claude Code session sees today, which is also nothing extra.
  if [[ "$is_root" -eq 1 ]]; then
    link "$base/.cursor/mcp.json" "../.mcp.json" "mcp.json"
  elif [[ -f "$base/.cursor/mcp.json" ]]; then
    dim "keeping this repo's own .cursor/mcp.json"
  fi

  # 5. Hook shim + the two generated configs.
  local settings="$base/.claude/settings.json"
  if [[ -f "$settings" ]]; then
    emit "$base/.cursor/hooks/hook-shim.sh" "hooks/hook-shim.sh" < "$TEMPLATE"
    [[ "$CHECK" -eq 1 ]] || chmod +x "$base/.cursor/hooks/hook-shim.sh" 2>/dev/null
    # Generated via a temp file rather than a pipe: `… | emit` would run emit in a
    # subshell and its DRIFT/CHANGED counter updates would be lost.
    local gen; gen="$(mktemp)"
    gen_hooks_json "$settings" > "$gen"; emit "$base/.cursor/hooks.json" "hooks.json" < "$gen"
    gen_cli_json   "$settings" > "$gen"; emit "$base/.cursor/cli.json"   "cli.json"   < "$gen"
    rm -f "$gen"
  else
    dim "no .claude/settings.json — no hooks or permissions to project"
  fi

  [[ "$is_root" -eq 1 ]] || check_dead_hook_copies "$base" "$name"
}

# ── user scope: make the enabled Claude plugin skills visible to Cursor ───────
# Plugin skills live under ~/.claude/plugins/marketplaces/<mp>/skills/<name>/, which
# is NOT one of the paths Cursor scans (it reads ~/.claude/skills and ~/.agents/skills).
# Link them into ~/.agents/skills so both tools see one copy. Personal machine
# state — nothing here is committed.
do_user_scope() {
  step "user scope (~/.agents/skills)"
  local dest="$HOME/.agents/skills" src
  [[ "$CHECK" -eq 1 ]] || mkdir -p "$dest"
  local found=0
  while IFS= read -r src; do
    found=1
    local nm; nm="$(basename "$src")"
    if [[ -e "$dest/$nm" && ! -L "$dest/$nm" ]]; then note "~/.agents/skills/$nm exists as a real dir — leaving it"; continue; fi
    if [[ -L "$dest/$nm" && "$(readlink "$dest/$nm")" == "$src" ]]; then ok "$nm"; continue; fi
    if [[ "$CHECK" -eq 1 ]]; then drift "plugin skill $nm not linked"; continue; fi
    rm -f "$dest/$nm"; ln -s "$src" "$dest/$nm" && { CHANGED=$((CHANGED+1)); ok "$nm -> $src"; }
  done < <(find "$HOME/.claude/plugins/marketplaces" -mindepth 3 -maxdepth 4 -type d -path '*/skills/*' \
             -exec test -f '{}/SKILL.md' ';' -print 2>/dev/null | sort)
  [[ "$found" -eq 1 ]] || dim "no plugin skills found under ~/.claude/plugins/marketplaces"
}

# ── run ───────────────────────────────────────────────────────────────────────
ALL_REPOS=""
while IFS= read -r r; do [[ -n "$r" ]] && ALL_REPOS="${ALL_REPOS:+$ALL_REPOS }$r"; done < <(parse_repo_dirs)

SLICES=""   # repos whose root slice this run is responsible for
FULL=0      # a run that saw every declared repo, so it may prune

if [[ -n "$TARGETS" ]]; then
  for t in $TARGETS; do
    if [[ "$t" == "root" || "$t" == "." ]]; then
      # Asking for the root means asking for the root's whole rule tree, and that
      # tree is made of every repo's slice.
      do_target "$ROOT" "root" 1; SLICES="$ALL_REPOS"; FULL=1
    else
      do_target "$ROOT/$t" "$t" 0; SLICES="${SLICES:+$SLICES }$t"
    fi
  done
else
  do_target "$ROOT" "root" 1
  for r in $ALL_REPOS; do do_target "$ROOT/$r" "$r" 0; done
  SLICES="$ALL_REPOS"; FULL=1
fi

if [[ -n "$SLICES" ]]; then
  step "root rules for nested repos"
  ensure_gitignore $SLICES
  for r in $SLICES; do root_slice "$r"; done
  [[ "$FULL" -eq 1 ]] && prune_root_slices $ALL_REPOS
fi

[[ "$USER_SCOPE" -eq 1 ]] && do_user_scope

echo
if [[ "$CHECK" -eq 1 ]]; then
  if [[ "$DRIFT" -gt 0 ]]; then
    printf '%s%d drift(s) found — run `aiworks cursor` to fix%s\n' "$c_err" "$DRIFT" "$c_off"
    exit 1
  fi
  printf '%sCursor layer is in sync%s\n' "$c_ok" "$c_off"
else
  printf '%sCursor layer up to date (%d change(s) this run)%s\n' "$c_ok" "$CHANGED" "$c_off"
fi

if [[ ${#NOTES[@]} -gt 0 ]]; then
  printf '\n%sNeeds a human decision:%s\n' "$c_warn" "$c_off"
  for n in "${NOTES[@]}"; do printf '  - %s\n' "$n"; done
fi
exit 0
