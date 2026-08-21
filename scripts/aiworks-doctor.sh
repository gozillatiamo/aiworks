#!/usr/bin/env bash
#
# aiworks-doctor.sh  (`aiworks doctor`) — say what is missing or broken in THIS workspace,
# and print the one command that fixes each thing.
#
# WHY THIS EXISTS: the workspace has many moving parts and every one of them already has an
# owner command — `aiworks sync` clones and onboards, `aiworks setup` links the adapters,
# `aiworks harnesses sync` regenerates selected projections, `aiworks update` moves tooling forward.
# What was missing is the surface that tells you WHICH of them you need to run. Before this,
# a half-finished workspace announced itself as a confusing failure three steps later: an
# adapter dying on a missing token, an agent grepping a repo that was never cloned, a hook
# silently not firing because it lost its +x bit.
#
# A DOCTOR, NOT AN INSTALLER — by default it reads and never writes (the same contract
# `scripts/k8s/setup.sh` and a bare `aiworks gc` keep). `--fix` exists, but it does not carry
# repair logic of its own: it runs the OWNER command for each finding, so there is exactly one
# implementation of every write in this workspace and nothing here can drift from it.
#
# Groups — 1-8 run offline by default; 9-12 need `--deep` (daemons, network, credentials):
#    1 workspace    mani.yaml · workspace.config[.local].yaml parse · required keys · no
#                   comments in the config (hook-enforced) · typo'd booleans · CLAUDE.md budget
#    2 repos        every declared repo cloned with a valid HEAD · mani.d ↔ products[] agree
#                   · each clone is git-ignored, so it cannot dirty the meta-repo
#    3 adapters     per provider: .env present and every REQUIRED var set · provider CLI
#                   installed · writer scripts executable · the .git/info/exclude trap ·
#                   notify / observability skipped when their enabled flag is false
#    4 per-repo     scripts/dev.sh · CLAUDE.md budget · .claude/ · adapter symlinks
#                   (tracker + vcs — the two `aiworks add` links) · .codegraph/ index ·
#                   skills-lock.json · a rules file scoped with `globs:` and no `paths:`
#    5 agent-cfg    every hook in .claude/settings.json exists and is executable · every declared
#                   plugin is actually INSTALLED (sync only declares it) · AGENTS.md
#                   and .cursor/ present per repo (CURSOR DRIFT is --deep: the real detector,
#                   `aiworks cursor --check`, walks every repo and takes ~8s)
#    6 tooling      the prerequisite binaries are on PATH, each missing one named with the
#                   installer that actually owns it (VERSION CURRENCY is --deep and covers
#                   the brew-owned half only — see check_tooling for why that is the honest
#                   scope rather than a green tick over everything)
#    7 voice        delegates `aiworks voice status` — skipped unless voice.enabled
#    8 triage       the read-only deployed-env triage MCPs are registered (offline, and --fix
#                   runs the owner command) · the Kubernetes triage IDENTITY exists and still
#                   cannot write (--deep: gcloud + kubectl per cluster; its fix needs a GCP
#                   project owner, so it is advisory). Skipped unless triage.enabled. ADR 0009
#    9 mcp          --deep · the shared MCP compose stack is up
#   10 services     --deep · the local Postgres / Redis / SonarQube ports answer
#   11 credentials  --deep · each adapter's own reader authenticates for real
#   12 disk         --deep · delegates `aiworks gc` (orphaned / idle / stale worktrees)
#
# HOW A CHECK IS SCORED:
#   ✓ pass   fine.
#   ✗ fail   work is blocked RIGHT NOW — a repo is missing, a token is unset, a hook lost +x.
#   ! warn   degraded or stale but still usable — an index is old, a budget is over, a rules
#            file uses the wrong key, a worktree is orphaned.
#   · skip   deliberately off (`<feature>.enabled: false`) or --deep-only on a default run.
#            A switched-off feature is a decision, not a defect, and never scores against you.
# exit 0 when nothing FAILED, 1 when something did. `--strict` promotes every warn to a fail.
#
# ⚠️ THE .env RULE. This script never reads a secret. The ONLY thing it does to an adapter's
# .env is `grep -q '^VAR=.\+'` — quiet, so the exit code is the whole answer and not one byte
# of the file reaches stdout, stderr, `--json`, or this process's environment. That is the
# idiom CLAUDE.md prescribes and the one `pretool-env-guard.sh` allows by name. Two rules
# follow from it and are asserted by the selftest: never `set -x` anywhere in this file (an
# xtrace line would print the grep's arguments), and never put a value in a `--json` field.
#
# Usage: aiworks-doctor.sh [<repo>] [options]
#   <repo>              narrow to one repo (also --repo a,b). Groups that are not repo-scoped
#                       (tooling, voice, triage, mcp, services, disk) report as skipped.
#       --only a,b      run only these groups (see the list above).
#       --skip a,b      run every group EXCEPT these.
#       --deep          also run groups 9-12: daemons, ports, live credentials, disk — and the
#                       Kubernetes half of `triage`.
#       --json          machine-readable report on stdout. Never contains a secret value.
#       --strict        treat every warn as a fail (exit 1 on a warn-only run).
#       --fix           print the owner command for every fixable finding, then ask to run
#                       them. Carries no repair logic of its own.
#   -y, --yes           answer yes to --fix. REQUIRED when stdin is not a TTY.
#   -n, --dry-run       with --fix: print the plan and stop. Alone: same as a plain run.
#   -v, --verbose       show every passing check, not just the group's summary line.
#   -h, --help          show this help.
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; }

ALL_GROUPS="workspace repos adapters per-repo agent-cfg tooling voice headroom triage mcp services credentials disk"
DEEP_GROUPS="mcp services credentials disk"

# ── args ──────────────────────────────────────────────────────────────────────────
DEEP=0 JSON=0 STRICT=0 FIX=0 YES=0 DRY=0 VERBOSE=0 ONLY="" SKIP="" REPOS_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deep)        DEEP=1 ;;
    --json)        JSON=1 ;;
    --strict)      STRICT=1 ;;
    --fix)         FIX=1 ;;
    -y|--yes)      YES=1 ;;
    -n|--dry-run)  DRY=1 ;;
    -v|--verbose)  VERBOSE=1 ;;
    -h|--help)     usage; exit 0 ;;
    --only)        ONLY="${2:-}"; shift ;;
    --only=*)      ONLY="${1#*=}" ;;
    --skip)        SKIP="${2:-}"; shift ;;
    --skip=*)      SKIP="${1#*=}" ;;
    --repo)        REPOS_ARG="${REPOS_ARG:+$REPOS_ARG,}${2:-}"; shift ;;
    --repo=*)      REPOS_ARG="${REPOS_ARG:+$REPOS_ARG,}${1#*=}" ;;
    -*)            printf 'aiworks doctor: unknown option %q (try -h)\n' "$1" >&2; exit 2 ;;
    *)             REPOS_ARG="${REPOS_ARG:+$REPOS_ARG,}$1" ;;
  esac
  shift
done

[[ -f "$ROOT/mani.yaml" ]] || {
  printf 'aiworks doctor: no mani.yaml in %s — run this from inside a workspace\n' "$ROOT" >&2
  exit 2
}
cd "$ROOT"

# --fix needs a decision from someone. On a pipe there is nobody to ask, and a --fix that
# quietly proceeded there would clone repos inside a CI job that only wanted a report.
if [[ $FIX == 1 && $YES == 0 && $DRY == 0 && ! -t 0 ]]; then
  printf 'aiworks doctor: --fix needs -y/--yes when stdin is not a TTY (or use --fix -n to preview)\n' >&2
  exit 2
fi
[[ $JSON == 1 ]] && VERBOSE=1   # a machine reader wants every check, not a summary

# ── output vocabulary ─────────────────────────────────────────────────────────────
if [[ -t 1 && $JSON == 0 ]]; then
  c_ok=$'\033[32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'
  c_dim=$'\033[2m'; c_hd=$'\033[1;36m'; c_off=$'\033[0m'
else
  c_ok=""; c_warn=""; c_err=""; c_dim=""; c_hd=""; c_off=""
fi

# One record per check, in a single indexed array (bash 3.2 has no associative arrays and
# /bin/bash on macOS is still 3.2). US = the unit separator, which cannot occur in a path.
US=$'\037'
R=()
n_pass=0 n_warn=0 n_fail=0 n_skip=0
FIXES=()          # "<cost>\037<label>\037<command>" — deduped at render time

# add <group> <status> <label> [detail] [fix-command] [fix-cost]
add() {
  local g="$1" s="$2" l="$3" d="${4:-}" f="${5:-}" cost="${6:-fast}"
  R+=("$g$US$s$US$l$US$d$US$f")
  case "$s" in
    pass) n_pass=$((n_pass+1)) ;;
    warn) n_warn=$((n_warn+1)) ;;
    fail) n_fail=$((n_fail+1)) ;;
    skip) n_skip=$((n_skip+1)) ;;
  esac
  [[ -n "$f" ]] && FIXES+=("$cost$US$l$US$f")
  return 0
}
pass() { add "$1" pass "$2" "${3:-}"; }
warn() { add "$1" warn "$2" "${3:-}" "${4:-}" "${5:-fast}"; }
fail() { add "$1" fail "$2" "${3:-}" "${4:-}" "${5:-fast}"; }
skip() { add "$1" skip "$2" "${3:-}"; }

# ── config reader ─────────────────────────────────────────────────────────────────
# Block-style YAML, pure awk, same parser shape as scripts/stagehand/lib.sh and
# scripts/voice/lib.sh — no yq, so a workspace that has not run `aiworks update` yet can
# still be diagnosed. Prints nothing for an absent path, so "absent" is distinguishable
# from "false" and the caller can fall through to the next file.
_yaml_get() {
  local f="$1" want="$2"
  [[ -f "$f" ]] || return 0
  awk -v want="$want" '
    function val(s){ sub(/^[^:]*:[ \t]*/,"",s); sub(/[ \t]+#.*$/,"",s);
                     gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
    /^[ \t]*(#|$)/  { next }
    /^[ \t]*-/      { next }
    {
      ind = match($0, /[^ ]/) - 1
      rest = substr($0, ind + 1)
      if (rest !~ /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:/) next
      key = rest; sub(/[ \t]*:.*/, "", key)
      d = int(ind / 2)
      stack[d] = key
      for (i = d + 1; i <= 20; i++) stack[i] = ""
      p = stack[0]
      for (i = 1; i <= d; i++) p = p "." stack[i]
      if (p == want) { v = val(rest); if (v != "") { print v; exit } }
    }
  ' "$f"
}

CFG="$ROOT/workspace.config.yaml"
CFG_LOCAL="$ROOT/workspace.config.local.yaml"

cfg() {  # <dotted.path> [default]
  local v
  v="$(_yaml_get "$CFG_LOCAL" "$1")"; [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  v="$(_yaml_get "$CFG" "$1")";       [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  printf '%s' "${2:-}"
}
cfg_bool() {  # <dotted.path> [default] — a value that is neither truthy nor falsy is a TYPO
  local v; v="$(cfg "$1" "${2:-false}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    true|yes|1|on)     return 0 ;;
    false|no|0|off|'') return 1 ;;
    *)                 return 2 ;;   # caller decides how loudly to complain
  esac
}

# ── where are we ──────────────────────────────────────────────────────────────────
# A linked worktree (Superset, slack-dispatch) is a first-class place to run this, but its
# adapter .env files are stubs by design — the fix there is a copy from the main clone, not
# "go make a token". Same finding, same severity, different instruction.
MAIN_CLONE=""
if command -v git >/dev/null 2>&1; then
  _common="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)" || _common=""
  if [[ -n "$_common" ]]; then
    case "$_common" in /*) ;; *) _common="$ROOT/$_common" ;; esac
    _main="$(cd "$(dirname "$_common")" 2>/dev/null && pwd)" || _main=""
    [[ -n "$_main" && "$_main" != "$ROOT" ]] && MAIN_CLONE="$_main"
  fi
fi
IN_WORKTREE=0; [[ -n "$MAIN_CLONE" ]] && IN_WORKTREE=1

# ── group selection ───────────────────────────────────────────────────────────────
in_list() { case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

group_state() {  # prints run | skip-deep | skip-flag
  local g="$1"
  [[ -n "$ONLY" ]] && { in_list "$g" "$ONLY" || { printf 'skip-flag'; return; }; }
  [[ -n "$SKIP" ]] && { in_list "$g" "$SKIP" && { printf 'skip-flag'; return; }; }
  if in_list "$g" "$(printf '%s' "$DEEP_GROUPS" | tr ' ' ',')" && [[ $DEEP == 0 ]]; then
    printf 'skip-deep'; return
  fi
  printf 'run'
}

# ── repo enumeration ──────────────────────────────────────────────────────────────
# The EXPECTED set comes from the committed mani.d/*.yaml (`path: ../<repo>`), which exists
# in every worktree from the first checkout — no `mani` binary and no clone required. The
# config's products[].repos[].url is the other half of the same truth; group 2 asserts they
# still agree, because a repo added to one and not the other is invisible to half the tooling.
mani_repos() {
  awk 'match($0, /path:[[:space:]]*\.\.\/[A-Za-z0-9._-]+/) {
         s = substr($0, RSTART, RLENGTH); sub(/.*\//, "", s); print s
       }' "$ROOT"/mani.d/*.yaml 2>/dev/null | sort -u
}
config_repos() {
  grep -oE '^ +- url: .*\.git' "$CFG" 2>/dev/null | sed 's#.*/##; s#\.git$##' | sort -u
}

EXPECTED="$(mani_repos)"
SELECTED="$EXPECTED"
if [[ -n "$REPOS_ARG" ]]; then
  SELECTED=""
  _oldifs="$IFS"; IFS=','
  for r in $REPOS_ARG; do
    [[ -z "$r" ]] && continue
    if printf '%s\n' "$EXPECTED" | grep -qx "$r"; then
      SELECTED="${SELECTED:+$SELECTED
}$r"
    else
      printf 'aiworks doctor: %q is not a declared repo (see mani.d/)\n' "$r" >&2
      IFS="$_oldifs"; exit 2
    fi
  done
  IFS="$_oldifs"
fi
NARROWED=0; [[ -n "$REPOS_ARG" ]] && NARROWED=1

repo_ready() {  # dir exists AND has a valid HEAD (an in-progress clone is not ready)
  [[ -d "$ROOT/$1" ]] || return 1
  git -C "$ROOT/$1" rev-parse --verify HEAD >/dev/null 2>&1
}

# ══════════════════════════════════════════════════════════════════════════════════
# 1 · workspace
# ══════════════════════════════════════════════════════════════════════════════════
check_workspace() {
  local g=workspace
  pass $g "mani.yaml" "$ROOT/mani.yaml"

  if [[ ! -f "$CFG" ]]; then
    fail $g "workspace.config.yaml missing" "the source of truth for every repo and provider" \
         "cp workspace.config.example.yaml workspace.config.yaml"
    return
  fi

  # "Parses" here means: the awk reader can resolve a key it must be able to resolve, and
  # at least one repo url is visible. A config that reads as empty is broken in a way that
  # every downstream reader would hit silently.
  local org; org="$(cfg org.name)"
  if [[ -z "$org" ]]; then
    fail $g "workspace.config.yaml: org.name does not resolve" \
         "block-style 2-space YAML expected — a tab or a flow mapping breaks every reader" \
         "\$EDITOR workspace.config.yaml"
  else
    pass $g "config parses" "org.name=$org"
  fi

  local nrepos; nrepos="$(config_repos | grep -c . || true)"
  if [[ "${nrepos:-0}" -eq 0 ]]; then
    fail $g "no repos declared" "products[].repos[].url is empty or unparseable" \
         "\$EDITOR workspace.config.yaml"
  else
    pass $g "products declared" "$nrepos repos"
  fi

  # Comments are banned in BOTH config files. The keys are documented in the .example, and a
  # comment beside a live value is a second source of truth that goes stale in silence — it is
  # hook-enforced (.claude/rules/workspace-config.md), so doctor reports what the hook blocks.
  local f
  for f in "$CFG" "$CFG_LOCAL"; do
    [[ -f "$f" ]] || continue
    local nc; nc="$(grep -cE '^[[:space:]]*#' "$f" 2>/dev/null || true)"
    if [[ "${nc:-0}" -gt 0 ]]; then
      warn $g "$(basename "$f") has $nc comment line(s)" \
           "comments belong in workspace.config.example.yaml — this file holds values only" \
           "grep -nE '^[[:space:]]*#' $(basename "$f")"
    fi
  done

  [[ -f "$CFG_LOCAL" ]] && pass $g "local overlay" "workspace.config.local.yaml"

  # A value that is neither truthy nor falsy is a typo, not an opt-out. `stagehand.enabled:
  # ture` sat in a personal config for weeks reading as "off" — indistinguishable from a
  # deliberate one. Every feature switch is checked the same way. The two whose default is
  # PERMISSIVE (auto_merge, auto_approve) are checked here too: there a typo does not read as
  # "off", it reads as "merge it" / "skip the plan gate".
  local sw
  for sw in voice.enabled stagehand.enabled diagrams.enabled artifacts.enabled \
            design.enabled image_generation.enabled observability.enabled \
            notify.enabled triage.enabled triage.prod \
            vcs.auto_merge planning.auto_approve planning.to_html \
            headroom.enabled headroom.statusline; do
    local raw; raw="$(cfg "$sw")"
    [[ -z "$raw" ]] && continue
    cfg_bool "$sw"
    if [[ $? == 2 ]]; then
      warn $g "$sw: '$raw' is not a boolean" \
           "every reader resolves it to the default, so a typo and an opt-out look identical" \
           "\$EDITOR workspace.config.yaml"
    fi
  done

  # The CLAUDE.md budget is guarded on every `aiworks sync`; reporting it here means you find
  # out while editing rather than at the next sync.
  if [[ -f "$ROOT/CLAUDE.md" ]]; then
    local n; n="$(grep -c '' "$ROOT/CLAUDE.md")"
    if [[ "$n" -gt 100 ]]; then
      warn $g "root CLAUDE.md is $n lines" "budget is 100 — the guard fails the next aiworks sync" \
           "\$EDITOR CLAUDE.md"
    else
      pass $g "root CLAUDE.md budget" "$n/100 lines"
    fi
  else
    warn $g "no root CLAUDE.md" "agents start this workspace with no instructions"
  fi

  # This repo's doc graph (graphify — prose only, docs/adr/0013). The workspace's own half
  # of the index: codegraph covers the product repos' code and indexes neither shell nor
  # markdown, which is most of what lives here. graph.json is committed, so a fresh clone
  # should already have one — an absent graph means either the commit is missing or someone
  # ran `graphify uninstall --purge`. Never offer a rebuild as a cheap fix: the semantic
  # pass is the most expensive step in the toolchain and it is serialised, so the owner
  # command is deliberately the explicit one.
  if [[ ! -f "$ROOT/.graphifyignore" ]]; then
    warn $g "no .graphifyignore" "the doc graph would index shell, config and generated mirrors" \
         "\$EDITOR .graphifyignore"
  elif [[ -f "$ROOT/graphify-out/graph.json" ]]; then
    # Count "norm_label", not "label": every node carries norm_label and nothing else does,
    # whereas "label" also appears on community labels and hyperedges (it over-counted by 40
    # on a 750-node graph).
    local dn; dn="$(grep -o '"norm_label"' "$ROOT/graphify-out/graph.json" 2>/dev/null | grep -c . || true)"
    pass $g "doc graph" "${dn:-0} nodes"
  else
    warn $g "no doc graph" "prose queries answer from nothing — codegraph indexes no shell and no markdown" \
         "graphify extract . --backend claude-cli" slow
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════
# 2 · repos
# ══════════════════════════════════════════════════════════════════════════════════
check_repos() {
  local g=repos

  # mani.d and products[] are two spellings of one list. A repo in only one of them is
  # invisible to half the tooling — `mani exec --all` skips it, or `aiworks sync` never
  # clones it — and nothing else in the workspace compares them.
  local only_mani only_cfg
  only_mani="$(comm -23 <(mani_repos) <(config_repos) | tr '\n' ' ' | sed 's/ *$//')"
  only_cfg="$(comm -13 <(mani_repos) <(config_repos) | tr '\n' ' ' | sed 's/ *$//')"
  if [[ -n "$only_mani" || -n "$only_cfg" ]]; then
    local d=""
    [[ -n "$only_mani" ]] && d="in mani.d only: $only_mani"
    [[ -n "$only_cfg"  ]] && d="${d:+$d; }in config only: $only_cfg"
    fail $g "mani.d and products[] disagree" "$d" "./aiworks sync -y"
  else
    pass $g "mani.d ↔ products[] agree" "$(mani_repos | grep -c .) repos"
  fi

  # Stale mani.d/<product>.yaml (basename not a products[].id) leaves duplicate project keys
  # after a rename; mani silently drops collisions on import. Sync prunes these.
  local stale_prod="" f base
  local -a live_products=()
  while IFS= read -r base; do
    [[ -n "$base" ]] && live_products+=("$base")
  done < <(awk '
    /^products:[ 	]*$/ { inp=1; next }
    inp && /^  - id:/ {
      sub(/^[^:]*:[ 	]*/, "")
      gsub(/^["'\'' \t]+|["'\'' \t]+$/, "")
      if ($0 != "") print
      next
    }
    inp && /^[A-Za-z_]/ { inp=0 }
  ' "$CFG")
  is_live_prod() {
    local p="$1" x
    for x in "${live_products[@]+"${live_products[@]}"}"; do [[ "$x" == "$p" ]] && return 0; done
    return 1
  }
  shopt -s nullglob
  for f in "$ROOT"/mani.d/*.yaml; do
    base="$(basename "$f" .yaml)"
    is_live_prod "$base" || stale_prod="${stale_prod:+$stale_prod }$base.yaml"
  done
  shopt -u nullglob
  if [[ -n "$stale_prod" ]]; then
    fail $g "stale mani.d product file(s)" "$stale_prod — not in products[].id; duplicate keys make mani drop projects"          "./aiworks sync -y"
  else
    pass $g "mani.d product files match products[].id"
  fi

  # Duplicate project keys across mani.d files — mani drops them silently.
  local dups
  dups="$(awk '
    /^  [A-Za-z0-9._-]+:[[:space:]]*$/ {
      k=$0; sub(/:[[:space:]]*$/, "", k); sub(/^  /, "", k)
      file=FILENAME; sub(/.*\//, "", file)
      if (seen[k] != "" && seen[k] != file) {
        if (!printed[k]++) print k " (" seen[k] " + " file ")"
      } else seen[k]=file
    }
  ' "$ROOT"/mani.d/*.yaml 2>/dev/null || true)"
  if [[ -n "$dups" ]]; then
    fail $g "duplicate mani project key(s)" "$(printf '%s' "$dups" | tr '\n' '; ')"          "./aiworks sync -y"
  else
    pass $g "no duplicate mani project keys"
  fi

  local missing="" ready=0 total=0 r
  for r in $SELECTED; do
    total=$((total+1))
    if repo_ready "$r"; then
      ready=$((ready+1))
      [[ $VERBOSE == 1 ]] && pass $g "$r cloned" "HEAD $(git -C "$ROOT/$r" rev-parse --short HEAD 2>/dev/null)"
    elif [[ -d "$ROOT/$r" ]]; then
      fail $g "$r has no valid HEAD" "the directory exists but the clone did not finish" \
           "rm -rf $r && ./aiworks sync -y $r" slow
    else
      missing="${missing:+$missing }$r"
    fi
  done
  if [[ -n "$missing" ]]; then
    fail $g "$(printf '%s' "$missing" | wc -w | tr -d ' ') repo(s) not cloned" "$missing" \
         "./aiworks sync -y${NARROWED:+ }$( [[ $NARROWED == 1 ]] && printf '%s' "$missing" | tr ' ' ',')" slow
  fi
  [[ $VERBOSE == 0 ]] && pass $g "clones" "$ready/$total ready"

  # A clone that is NOT git-ignored shows up as untracked in the meta-repo, and the next
  # `git add -A` here commits somebody's whole product repo into the workspace.
  local unignored=""
  for r in $SELECTED; do
    [[ -d "$ROOT/$r" ]] || continue
    git -C "$ROOT" check-ignore -q "$r" 2>/dev/null || unignored="${unignored:+$unignored }$r"
  done
  if [[ -n "$unignored" ]]; then
    warn $g "clone(s) not git-ignored" "$unignored — they will show as untracked in this repo" \
         "./aiworks config"
  else
    pass $g "clones are git-ignored"
  fi

  # Every loop above walks the DECLARED set, so a clone on disk that no mani.d entry names is
  # invisible to all of them: `aiworks sync` never onboards it, its step 3.1 never adds the
  # `/<dir>/` line to .gitignore, and the unignored check above never looks at it. Git then
  # treats the nested repo as a GITLINK — `git add -A` stages mode 160000, a bare pointer to
  # a commit nobody who clones this workspace can resolve. The usual cause is a branch switch:
  # the clone is an untracked directory and survives, while the .gitignore line and the
  # products[] entry that arrived with it are tracked and revert.
  #
  # Compared against EXPECTED, not SELECTED — `--repo` narrows what we inspect, and must not
  # make the repos it excluded look undeclared.
  local orphans="" orphans_open="" d
  for d in "$ROOT"/*/; do
    d="${d%/}"; r="${d##*/}"
    [[ -e "$d/.git" ]] || continue                       # also skips the unmatched glob
    printf '%s\n' "$EXPECTED" | grep -qx "$r" && continue
    orphans="${orphans:+$orphans }$r"
    git -C "$ROOT" check-ignore -q "$r" 2>/dev/null || orphans_open="${orphans_open:+$orphans_open }$r"
  done
  if [[ -n "$orphans" ]]; then
    warn $g "clone(s) no mani.d entry declares" \
         "$orphans${orphans_open:+ — and $orphans_open is not git-ignored, so \`git add -A\` stages it as a gitlink}" \
         "see: aiworks add <url> to declare it, or remove the directory"
  else
    pass $g "no undeclared clones"
  fi

  # The same hazard one step later: a gitlink already IN the index. Without a .gitmodules to
  # back it, this is never a real submodule — committing it publishes a pointer that no clone
  # of this workspace can resolve. `git rm --cached` touches the index only, never the files;
  # -f is needed because the staged commit differs from both HEAD and the nested repo's own
  # HEAD the moment that clone moves on, and with --cached it still cannot delete anything.
  local links
  links="$(git -C "$ROOT" ls-files -s 2>/dev/null | awk '$1=="160000"' | cut -f2- | tr '\n' ' ')"
  links="${links% }"
  if [[ -n "$links" && ! -f "$ROOT/.gitmodules" ]]; then
    fail $g "gitlink staged, no .gitmodules" \
         "$links — committing this makes a submodule nobody can clone" \
         "git rm --cached -f -- $links"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════
# 3 · adapters
# ══════════════════════════════════════════════════════════════════════════════════
# The required-var table mirrors each provider's own `*_require_config`, which is the single
# authority on what that provider cannot start without:
#   scripts/tracker/jira/impl.sh · tracker/notion/impl.sh · tracker/linear/impl.sh
#   notify/slack/impl.sh · observability/signoz/impl.sh · vcs/gitlab.sh · vcs/github.sh
# Space-separated names are ALL required; `A|B` means either one satisfies it (slack takes a
# bot token or a webhook). The selftest asserts this table still covers every provider dir,
# so a new provider cannot be added without doctor learning about it.
provider_required_vars() {  # <adapter> <provider>
  case "$1/$2" in
    tracker/jira)        printf 'JIRA_BASE_URL JIRA_EMAIL JIRA_API_TOKEN' ;;
    tracker/notion)      printf 'NOTION_TOKEN NOTION_DB_ID' ;;
    tracker/linear)      printf 'LINEAR_API_KEY' ;;
    notify/slack)        printf 'SLACK_BOT_TOKEN|SLACK_WEBHOOK_URL' ;;
    observability/signoz) printf 'SIGNOZ_BASE_URL SIGNOZ_API_KEY' ;;
    vcs/gitlab|vcs/github) printf '' ;;   # CLI-authenticated, no .env contract
    *)                   printf '' ;;
  esac
}
provider_cli() {  # <adapter> <provider> — the binary the provider dies without
  case "$1/$2" in
    vcs/gitlab) printf 'glab' ;;
    vcs/github) printf 'gh' ;;
    *)          printf '' ;;
  esac
}

# var_set <file> <NAME> — quiet grep ONLY. The exit code is the entire answer; nothing from
# the file is printed, captured, or exported. See the .env rule in this file's header.
var_set() { grep -q "^[[:space:]]*\(export[[:space:]]\+\)\?$2=.\+" "$1" 2>/dev/null; }

check_adapters() {
  local g=adapters a provider envf req cli

  for a in vcs tracker notify observability; do
    if [[ ! -d "$ROOT/scripts/$a" ]]; then
      fail $g "scripts/$a missing" "the $a adapter is not installed" "./aiworks setup"
      continue
    fi
    case "$a" in
      vcs)           provider="$(cfg vcs.provider)" ;;
      tracker)       provider="$(cfg tracker.provider)" ;;
      notify)
        # Same contract as voice/triage/credentials: enabled:false is a decision, not a defect.
        # Default matches workspace.config.example.yaml (off).
        cfg_bool notify.enabled false
        case $? in
          1) skip $g "notify" "notify.enabled is false"; continue ;;
          2) warn $g "notify.enabled is not a boolean" \
               "resolved to the default (off) — set true|false" \
               "\$EDITOR workspace.config.yaml"; continue ;;
        esac
        provider="$(cfg notify.provider)"
        ;;
      observability)
        cfg_bool observability.enabled false
        case $? in
          1) skip $g "observability" "observability.enabled is false"; continue ;;
          2) warn $g "observability.enabled is not a boolean" \
               "resolved to the default (off) — set true|false" \
               "\$EDITOR workspace.config.yaml"; continue ;;
        esac
        provider="$(cfg observability.provider)"
        ;;
    esac
    if [[ -z "$provider" ]]; then
      warn $g "$a: no provider in config" "readers fall back to a default that may not be yours" \
           "\$EDITOR workspace.config.yaml"
      continue
    fi

    cli="$(provider_cli "$a" "$provider")"
    if [[ -n "$cli" ]]; then
      if command -v "$cli" >/dev/null 2>&1; then
        pass $g "$a ($provider) CLI" "$cli"
      else
        fail $g "$a ($provider): $cli not installed" "every $a call dies at vcs_require_config" \
             "./aiworks update --only brew" slow
      fi
    fi

    req="$(provider_required_vars "$a" "$provider")"
    [[ -z "$req" ]] && continue

    envf="$ROOT/scripts/$a/.env"
    if [[ ! -f "$envf" ]]; then
      if [[ $IN_WORKTREE == 1 ]]; then
        fail $g "$a ($provider): scripts/$a/.env missing" "worktrees do not inherit it" \
             "cp $MAIN_CLONE/scripts/$a/.env scripts/$a/.env"
      else
        fail $g "$a ($provider): scripts/$a/.env missing" "the adapter cannot authenticate" \
             "cp scripts/$a/.env.example scripts/$a/.env && \$EDITOR scripts/$a/.env"
      fi
      continue
    fi

    local unset_vars="" tok ok one
    for tok in $req; do
      ok=0
      local _oldifs="$IFS"; IFS='|'
      for one in $tok; do var_set "$envf" "$one" && { ok=1; break; }; done
      IFS="$_oldifs"
      [[ $ok == 1 ]] || unset_vars="${unset_vars:+$unset_vars }$(printf '%s' "$tok" | tr '|' '/')"
    done

    if [[ -n "$unset_vars" ]]; then
      # In a worktree this is the expected shape, not a mystery: setup seeds a stub from the
      # .env.example and the real credentials only ever live in the main clone. Same severity
      # (the adapter is just as dead either way) — but the instruction that fixes it differs.
      if [[ $IN_WORKTREE == 1 ]]; then
        fail $g "$a ($provider): scripts/$a/.env is a stub" "unset: $unset_vars" \
             "cp $MAIN_CLONE/scripts/$a/.env scripts/$a/.env"
      else
        fail $g "$a ($provider): unset in scripts/$a/.env" "$unset_vars" \
             "\$EDITOR scripts/$a/.env"
      fi
    else
      pass $g "$a ($provider) configured" "$(printf '%s' "$req" | wc -w | tr -d ' ') required var(s) set"
    fi
  done

  # An adapter entrypoint without +x is a permission-denied three layers down a workflow.
  local noexec="" s
  for s in "$ROOT"/scripts/{vcs,tracker,notify,observability}/*.sh; do
    [[ -f "$s" ]] || continue
    [[ -x "$s" ]] || noexec="${noexec:+$noexec }${s#$ROOT/}"
  done
  if [[ -n "$noexec" ]]; then
    fail $g "adapter script(s) not executable" "$noexec" "chmod +x $noexec"
  else
    pass $g "adapter scripts executable"
  fi

  # THE .git/info/exclude TRAP. That file is local and untracked, so a rule in it hides NEW
  # files from `git add -A` on this machine only: the adapter wrapper gets written, the tests
  # pass locally, and the feature ships with no entrypoint because the file was never
  # committed. Nothing else in the workspace looks at it.
  local exfile="$ROOT/.git/info/exclude"
  [[ $IN_WORKTREE == 1 && -n "$MAIN_CLONE" ]] && exfile="$MAIN_CLONE/.git/info/exclude"
  if [[ -f "$exfile" ]]; then
    local hits; hits="$(grep -vE '^[[:space:]]*(#|$)' "$exfile" 2>/dev/null \
                        | grep -E 'scripts/(vcs|tracker|notify|observability)' | tr '\n' ' ' | sed 's/ *$//')"
    if [[ -n "$hits" ]]; then
      warn $g ".git/info/exclude hides adapter paths" \
           "$hits — a NEW file there is invisible to git add; use 'git add -f'" \
           "grep -vE '^#' .git/info/exclude"
    fi
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════
# 4 · per-repo
# ══════════════════════════════════════════════════════════════════════════════════
check_per_repo() {
  local g=per-repo r n
  local no_dev="" noexec_dev="" no_claude="" over="" no_cg="" no_link="" no_lock="" bad_rules=""
  local checked=0

  for r in $SELECTED; do
    repo_ready "$r" || continue          # group 2 already owns "not cloned"
    checked=$((checked+1))
    local d="$ROOT/$r"

    # A dev.sh that exists without +x and one that was never scaffolded are different
    # problems with different owners: chmod fixes the first, only `aiworks sync` the second.
    if [[ ! -f "$d/scripts/dev.sh" ]]; then no_dev="${no_dev:+$no_dev }$r"
    elif [[ ! -x "$d/scripts/dev.sh" ]]; then noexec_dev="${noexec_dev:+$noexec_dev }$r/scripts/dev.sh"
    fi
    if [[ -f "$d/CLAUDE.md" ]]; then
      n="$(grep -c '' "$d/CLAUDE.md")"
      [[ "$n" -gt 100 ]] && over="${over:+$over }$r($n)"
    else
      no_claude="${no_claude:+$no_claude }$r"
    fi
    [[ -d "$d/.codegraph" ]] || no_cg="${no_cg:+$no_cg }$r"
    [[ -f "$d/skills-lock.json" ]] || no_lock="${no_lock:+$no_lock }$r"

    # `aiworks add` links exactly two adapters into a repo (scripts/aiworks-add.sh: `for a in
    # tracker vcs`). notify and observability are called from the workspace root only — do not
    # demand them here, or every healthy repo reports two failures it cannot fix.
    local a
    for a in tracker vcs; do
      [[ -e "$d/scripts/$a" ]] || no_link="${no_link:+$no_link }$r/$a"
    done

    # `.claude/rules/*.md` scope with `paths:`; `globs:` is Cursor's key for the same idea.
    # A file carrying BOTH is untidy but works — Claude reads paths:, Cursor reads globs:. The
    # broken shape is `globs:` ALONE: the file parses, the rule loads, and it matches nothing.
    if [[ -d "$d/.claude/rules" ]]; then
      local f
      for f in "$d"/.claude/rules/*.md; do
        [[ -f "$f" ]] || continue
        if awk '
             NR==1 && $0!="---" { exit }
             NR>1  && $0=="---" { exit }
             /^globs:/ { g=1 }
             /^paths:/ { p=1 }
             END { exit !(g && !p) }
           ' "$f"; then
          bad_rules="${bad_rules:+$bad_rules }${f#$ROOT/}"
        fi
      done
    fi
  done

  if [[ $checked == 0 ]]; then
    skip $g "no cloned repo to inspect"
    return
  fi

  [[ -n "$no_dev"     ]] && fail $g "scripts/dev.sh not scaffolded" "$no_dev" "./aiworks sync -y" slow
  [[ -n "$noexec_dev" ]] && fail $g "scripts/dev.sh not executable" \
                                 "$noexec_dev — every dev.sh call is a permission error" \
                                 "chmod +x $noexec_dev"
  [[ -z "$no_dev" && -z "$noexec_dev" ]] && pass $g "scripts/dev.sh" "$checked repos"
  [[ -n "$no_claude" ]] && warn $g "no CLAUDE.md" "$no_claude — agents get no repo instructions" "./aiworks sync -y" slow
  [[ -n "$over"      ]] && warn $g "CLAUDE.md over the 100-line budget" "$over" "\$EDITOR <repo>/CLAUDE.md"
  [[ -z "$no_claude" && -z "$over" ]] && pass $g "per-repo CLAUDE.md budget" "$checked repos ≤100 lines"
  [[ -n "$no_link"   ]] && fail $g "adapter link(s) missing in repo" "$no_link" "./aiworks setup" \
                        || pass $g "adapter symlinks" "tracker + vcs in $checked repos"
  [[ -n "$no_cg"     ]] && warn $g "no .codegraph index" "$no_cg — codegraph queries answer from nothing" \
                                "./aiworks sync -y" slow \
                        || pass $g "codegraph index" "$checked repos"
  [[ -n "$no_lock"   ]] && warn $g "no skills-lock.json" "$no_lock" "./aiworks sync -y" slow \
                        || pass $g "skills-lock.json" "$checked repos"
  [[ -n "$bad_rules" ]] && warn $g "rules file scoped with 'globs:' and no 'paths:'" \
                                "$bad_rules — the rule loads and matches nothing" \
                                "\$EDITOR <the files above>" \
                        || pass $g "rules frontmatter" "$checked repos"
  return 0
}

# ══════════════════════════════════════════════════════════════════════════════════
# 5 · agent-cfg
# ══════════════════════════════════════════════════════════════════════════════════
check_agent_cfg() {
  local g=agent-cfg
  local settings="$ROOT/.claude/settings.json"
  local harness_set=""
  if [[ -x "$DIR/aiworks-harnesses.sh" ]]; then
    harness_set=" $($DIR/aiworks-harnesses.sh list 2>/dev/null | tr '\n' ' ') "
    [[ -n "${harness_set// /}" ]] && pass $g "Agent harness set" "${harness_set# }"
  fi

  if [[ ! -f "$settings" ]]; then
    fail $g ".claude/settings.json missing" "no hooks, no permissions, no plugins" "./aiworks sync -y" slow
    return
  fi

  # Read the hook paths out of settings.json rather than hardcoding a list, so a hook added
  # tomorrow is covered without editing this file. A hook that is missing or has lost its +x
  # bit does not error — the harness just never runs it, and the guard it enforced is gone.
  local missing="" noexec="" h n=0
  while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    n=$((n+1))
    if [[ ! -f "$ROOT/$h" ]]; then missing="${missing:+$missing }$h"
    elif [[ ! -x "$ROOT/$h" ]]; then noexec="${noexec:+$noexec }$h"
    fi
  done <<EOF
$(grep -oE '\.claude/hooks/[A-Za-z0-9._/-]+\.sh' "$settings" 2>/dev/null | sort -u)
EOF

  [[ -n "$missing" ]] && fail $g "hook(s) referenced but not present" "$missing" "./aiworks sync -y" slow
  [[ -n "$noexec"  ]] && fail $g "hook(s) not executable" "$noexec — the harness silently skips them" \
                              "chmod +x $noexec"
  [[ -z "$missing" && -z "$noexec" ]] && pass $g "hooks" "$n wired, present, executable"

  [[ -d "$ROOT/.claude/skills" ]] && pass $g ".claude/skills" \
    || warn $g "no .claude/skills" "skill packs are not installed" "./aiworks sync -y" slow

  # The Cursor face of this workspace is GENERATED, and `aiworks cursor --check` is its own
  # drift detector — one exit code, one definition of "in sync", nothing reimplemented here.
  # It walks every repo though, which costs ~8s: four times this whole command's budget. So
  # the default run answers the cheap half (is the projection even THERE?) and the real
  # comparison waits for --deep.
  if [[ "$harness_set" == *" cursor "* ]]; then
    local nomirror="" r
    for r in $SELECTED; do
      repo_ready "$r" || continue
      [[ -f "$ROOT/$r/AGENTS.md" && -d "$ROOT/$r/.cursor" ]] || nomirror="${nomirror:+$nomirror }$r"
    done
    [[ -n "$nomirror" ]] && warn $g "cursor mirror not projected" "$nomirror" "./aiworks cursor" \
                         || pass $g "cursor mirror present" "AGENTS.md + .cursor/ per repo"

    if [[ $DEEP == 1 ]]; then
      if [[ -x "$DIR/aiworks-cursor.sh" ]]; then
        if "$DIR/aiworks-cursor.sh" --check >/dev/null 2>&1; then
          pass $g "cursor mirror in sync"
        else
          warn $g "cursor mirror has drifted" "the .cursor/ projection no longer matches the Claude side" \
               "./aiworks cursor"
        fi
      else
        skip $g "cursor drift" "aiworks-cursor.sh not present"
      fi
    else
      skip $g "cursor drift" "--deep (aiworks cursor --check costs ~8s)"
    fi
  else
    skip $g "cursor projection" "Cursor is not selected in workspace.config.yaml harnesses"
  fi

  # Codex is a generated Harness projection with its own strict drift check. Cheap presence is
  # checked on every run; full source-to-projection comparison waits for --deep like Cursor.
  if [[ "$harness_set" == *" codex "* ]]; then
    if [[ -f "$ROOT/.codex/config.toml" && -f "$ROOT/.codex/hooks.json" \
          && -L "$ROOT/.agents/skills" && -d "$ROOT/.codex/agents" ]]; then
      pass $g "codex projection present" "config + hooks + agents + canonical skill link"
    else
      fail $g "codex projection incomplete" "one or more generated Codex surfaces are missing" "./aiworks codex"
    fi
    if [[ $DEEP == 1 ]]; then
      if "$DIR/aiworks-codex.sh" --check >/dev/null 2>&1; then
        pass $g "codex projection in sync"
      else
        warn $g "codex projection has drifted" "generated .codex no longer matches .claude" "./aiworks codex"
      fi
    else
      skip $g "codex drift" "--deep (aiworks codex --check)"
    fi
  else
    skip $g "codex projection" "Codex is not selected in workspace.config.yaml harnesses"
  fi

  # PLUGIN SCOPE. `.superset/lib.sh` installs every declared plugin at USER scope on purpose
  # (its own comment: one install covers the root AND all 22 clones; project scope would mean 22
  # installs that drift apart). A project-scope entry beside it is not a second plugin — it is a
  # duplicate registration of the same one, pinned to whatever marketplace commit was cached the
  # day it appeared, and `claude plugin update` only ever moves the USER entry. So it silently
  # rots: measured 2026-08-07, this workspace carried one 18 days behind the user-scope install.
  # Cheap enough for the default run — two file reads, no network, no session.
  local reg="$HOME/.claude/plugins/installed_plugins.json"
  if ! command -v jq >/dev/null 2>&1; then
    skip $g "plugin scope" "jq unavailable — cannot read the plugin registry"
  elif [[ ! -f "$reg" ]]; then
    skip $g "plugin scope" "no plugin registry on this machine yet"
  else
    # Report DIVERGENCE, not mere duplication. A project-scope entry appears on its own here
    # (`claude plugin update` refreshed one into this root mid-run on 2026-08-07, and every
    # dispatched worktree gets one), so warning on existence alone would be a warn no command can
    # permanently clear — the same defect this file's `gh` currency warn had. While the two entries
    # carry the SAME version nothing is broken; the failure is when they part, because only the
    # user entry is ever updated. That is the caveman case: project 77 lines vs user 87.
    # Match the project entry on the RESOLVED path, never the recorded string. $ROOT is already
    # physical (`cd … && pwd`) while the registry stores whatever path the session was opened
    # with — on macOS a /var/… symlink of /private/var/… is the same directory spelled two ways,
    # and a string compare silently matches nothing. Caught by the selftest, not by inspection.
    local pkey projscoped="" missing="" dup=0 uv pv ep ev rootp
    rootp="$(cd "$ROOT" 2>/dev/null && pwd -P)" || rootp="$ROOT"
    while IFS= read -r pkey; do
      [[ -z "$pkey" ]] && continue
      uv="$(jq -r --arg k "$pkey" '(((.plugins // .)[$k]) // [])[] | select(.scope == "user") | .version' "$reg" 2>/dev/null | head -1)"
      pv=""
      while IFS="$(printf '\t')" read -r ep ev; do
        [[ -z "$ep" ]] && continue
        [[ "$(cd "$ep" 2>/dev/null && pwd -P)" == "$rootp" ]] && { pv="$ev"; break; }
      done <<INNER
$(jq -r --arg k "$pkey" '(((.plugins // .)[$k]) // [])[] | select(.scope == "project") | "\(.projectPath)\t\(.version)"' "$reg" 2>/dev/null)
INNER
      [[ -n "$pv" ]] && dup=$((dup+1))
      [[ -n "$uv" && -n "$pv" && "$uv" != "$pv" ]] && projscoped="${projscoped:+$projscoped }$pkey"
      # DECLARED BUT NOT INSTALLED. `$uv` is already the user-scope version, so its absence IS
      # the test — no second registry read, no second loop.
      [[ -z "$uv" ]] && missing="${missing:+$missing }$pkey"
    done <<EOF
$(jq -r '(.enabledPlugins // {}) | keys[]' "$settings" 2>/dev/null)
EOF
    # "Declared" reads as done and is not. `aiworks sync` converges enabledPlugins +
    # extraKnownMarketplaces into the root and every declared repo, and stops there — the install is
    # `ensure_claude_plugins` in .superset/lib.sh, which ONLY setup.sh calls. Nothing else
    # reports the gap, and nothing looks broken while it is open: the skills still resolve,
    # because `aiworks cursor` vendors and links them independently of the plugin. What is
    # silently absent is the plugin's HOOKS — which for caveman and ponytail is the entire
    # point, since that is how the ruleset reaches a session and its subagents at all.
    # Reported separately from the scope block below: a machine can be missing one plugin while
    # another has drifted, and collapsing them would hide whichever lost the branch.
    if [[ -n "$missing" ]]; then
      # The owner is ensure_claude_plugins, not a hand-written pair of claude commands: it
      # already adds the marketplace from extraKnownMarketplaces BEFORE installing, and a bare
      # `claude plugin install` without that step fails with "not found in marketplace" —
      # measured 2026-08-13. Sourcing lib.sh keeps the write in the one script that owns it.
      warn $g "declared plugin(s) not installed" \
           "$missing — declaring is not installing: no SessionStart/SubagentStart hooks on this machine" \
           "bash -c '. .superset/lib.sh && ensure_claude_plugins'" slow
    fi

    if [[ -n "$projscoped" ]]; then
      # The uninstall ALSO deletes the plugin's line from the committed settings.json, which is
      # the very file lib.sh reads to install it user-scope everywhere — so the restore is part
      # of the fix, not an afterthought.
      # `claude plugin uninstall` takes ONE plugin, so a bare space-joined list would fail — loop.
      # The trailing checkout is not optional: each uninstall deletes that plugin's line from the
      # committed settings.json, the file lib.sh reads to install it user-scope on every machine.
      warn $g "project-scope plugin copy has drifted from user scope" \
           "$projscoped — the session may serve this older copy; only user scope gets updated" \
           "for p in $projscoped; do claude plugin uninstall \"\$p\" -s project -y; done; git checkout -- .claude/settings.json"
    elif [[ $dup -gt 0 ]]; then
      pass $g "plugin scope" "$dup project-scope duplicate(s), all matching user scope"
    elif [[ -z "$missing" ]]; then
      # Only claim this when every declared plugin is actually there — a "user-scope only" pass
      # beside a not-installed warn would read as the plugins being fine.
      pass $g "plugin scope" "declared plugins are user-scope only"
    fi
  fi

  # RESTART. A plugin update writes a new content-hash cache dir; the RUNNING session keeps
  # serving the old one, because its SessionStart hook already injected that version's ruleset.
  # Nothing else reports this, and it is what team "caveman is misbehaving" reports turn out to
  # be — the old ruleset is missing the rule against dropping not/never/no and the strict
  # language-preservation rule. caveman is checked by name rather than generically because it is
  # the one plugin every session and all 16 agent definitions depend on, and because it is the
  # one that leaves a per-activation marker to compare against: its activate hook rewrites
  # $CLAUDE_CONFIG_DIR/.caveman-active every time it runs, so that file's mtime IS the last
  # activation. Update newer than activation ⇒ no session since has picked the new rules up.
  local flag="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-active"
  if ! command -v jq >/dev/null 2>&1 || [[ ! -f "$reg" ]]; then
    : # already reported by the scope check above
  elif [[ ! -f "$flag" ]]; then
    skip $g "caveman restart" "no .caveman-active marker — caveman is off or has never activated"
  else
    local lu ue fm
    lu="$(jq -r '(((.plugins // .)["caveman@caveman"]) // [])[] | select(.scope == "user") | .lastUpdated' "$reg" 2>/dev/null | head -1)"
    fm="$(stat -f %m "$flag" 2>/dev/null)"
    ue="$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "${lu%.*}" +%s 2>/dev/null)"
    if [[ -z "$lu" || -z "$fm" || -z "$ue" ]]; then
      skip $g "caveman restart" "cannot compare install time with last activation"
    elif [[ "$ue" -gt "$fm" ]]; then
      warn $g "caveman plugin updated since the last activation" \
           "every running session is still serving the OLD ruleset" \
           "see: restart Claude Code (a plugin update cannot reach a live session)"
    else
      pass $g "caveman ruleset current" "activated after the last plugin update"
    fi
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════
# 6 · tooling
# ══════════════════════════════════════════════════════════════════════════════════
# PRESENCE only on a default run. Version currency lives under --deep because the probe that
# answers it (`aiworks update -n`) takes ~7s — longer than this whole command is meant to.
# `aiworks update` moves an INSTALLED tool forward; it never installs a missing one, so it is
# the wrong instruction for something that is not on PATH at all. Point at whoever actually
# owns the install: `aiworks setup` for the tools .superset/lib.sh has an ensure_* helper for,
# brew for the plain formulae, and a `see:` advisory for the ones no command here should run
# on someone's behalf (node switches PATH, Docker Desktop is a GUI app).
tool_installer() {  # <binary> — a runnable command, or a `see:` line meaning "needs you"
  case "$1" in
    jq|glab|gh|pnpm|dap|ngrok) printf './aiworks setup' ;;
    mani|k6|yq)                printf 'brew install %s' "$1" ;;
    git|curl|awk)              printf 'see: %s is part of the base system — install Xcode CLT or coreutils' "$1" ;;
    node)                      printf 'see: nvm install --lts --reinstall-packages-from=current (a node switch moves the global bin dir)' ;;
    docker)                    printf 'see: install Docker Desktop — https://docker.com/products/docker-desktop' ;;
    claude)                    printf 'see: https://claude.com/claude-code — then re-run aiworks update --only claude' ;;
    codegraph)                 printf 'see: %s is installed outside this workspace; reinstall it the way you first did' "$1" ;;
    graphify)                  printf 'uv tool install --python 3.12 "graphifyy[leiden,svg,sql]"' ;;
    *)                         printf 'see: install %s' "$1" ;;
  esac
}

check_tooling() {
  local g=tooling b
  local hard="git jq curl awk mani"
  local soft="node pnpm docker claude codegraph graphify dap k6 yq"

  local miss=""
  for b in $hard; do command -v "$b" >/dev/null 2>&1 || miss="${miss:+$miss }$b"; done
  if [[ -n "$miss" ]]; then
    for b in $miss; do
      fail $g "required tool not on PATH: $b" "the workspace cannot function without it" \
           "$(tool_installer "$b")" slow
    done
  else
    pass $g "required tools" "$hard"
  fi

  local softmiss=""
  for b in $soft; do command -v "$b" >/dev/null 2>&1 || softmiss="${softmiss:+$softmiss }$b"; done
  if [[ -n "$softmiss" ]]; then
    for b in $softmiss; do
      warn $g "optional tool not on PATH: $b" "the features that use it are unavailable" \
           "$(tool_installer "$b")" slow
    done
  else
    pass $g "optional tools" "all present"
  fi

  # CURRENCY, honestly scoped. `aiworks update -n` cannot answer this — dry-run prints the
  # commands it WOULD run and closes with "0 version(s) moved" whether or not anything is
  # behind, so reading it would report every machine as current. `brew outdated` is a real
  # answer, for the formulae brew actually owns; rustup, gcloud, claude and codegraph carry
  # their own updaters and are NOT covered here. Saying which half is checked beats a green
  # tick that quietly means nothing.
  if [[ $DEEP == 0 ]]; then
    skip $g "version currency" "--deep (brew outdated costs ~13s)"
  elif ! command -v brew >/dev/null 2>&1; then
    skip $g "version currency" "brew not installed — no currency source for this machine"
  else
    local behind
    behind="$(brew outdated --quiet 2>/dev/null \
              | grep -xE 'mani|glab|gh|jq|dap|k6|pnpm|ngrok' | tr '\n' ' ' | sed 's/ *$//')"
    if [[ -n "$behind" ]]; then
      warn $g "brew-owned tool(s) behind" "$behind" "./aiworks update --only brew" slow
    else
      pass $g "brew-owned tools current" "rustup/gcloud/claude/codegraph self-update — not checked here"
    fi
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════
# 7 · voice
# ══════════════════════════════════════════════════════════════════════════════════
check_voice() {
  local g=voice
  cfg_bool voice.enabled false
  case $? in
    1) skip $g "voice" "voice.enabled is false"; return ;;
    2) warn $g "voice.enabled is not a boolean" "resolved to the default (off)" "\$EDITOR workspace.config.yaml"; return ;;
  esac
  if [[ -x "$DIR/aiworks-voice.sh" ]]; then
    if "$DIR/aiworks-voice.sh" status >/dev/null 2>&1; then
      pass $g "voice status" "aiworks voice status is clean"
    else
      warn $g "voice is enabled but not healthy" "run the status surface for the switch that decides it" \
           "./aiworks voice status"
    fi
  else
    fail $g "voice enabled but the adapter is missing" "scripts/aiworks-voice.sh not present" "./aiworks sync -y" slow
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════
# 8 · headroom
# ══════════════════════════════════════════════════════════════════════════════════
# Input-side context compression: `hcat <file>` renders a big structured file compressed so its
# raw bytes never enter context, and a PreToolUse gate redirects an oversized Read there once.
# The plugin ships the hooks and the badge; the ENGINE is a separate binary everything shells
# out to. Both halves fail OPEN by design — a missing engine means no compression, no badge and
# no error — so "silently doing nothing" is exactly the shape this group exists to make visible.
#
# The env-guard item is the one that is not about savings. `hcat` is a RENAMED `cat`: it prints
# any file it is given, so it is a .env read the guard must recognise. `\bcat\b` cannot match
# "hcat" (no word boundary after the leading h), so the coverage is a separate alternative that
# a future edit to that alternation could drop without any test going red here. Asserted at the
# root AND in the per-repo copies, because the guard is mirrored into every declared repo by aiworks-add's
# WIRED_HOOKS and a stale copy is a live hole in that repo only.
# Does the configured statusLine actually render our badge? EXECUTED, not parsed. A chain bridge
# keeps the command it replaced in its own cache file, so following the string generalises to
# nothing — one vendor's stash key is not the next one's. Running it is the cheap honest answer:
# Claude Code runs this exact command once a second, and the probe is kept inert — no
# `transcript_path`, so the badge's compute-and-cache path never runs, and a throwaway
# HEADROOM_STATE_DIR so a probe can never write into the real ledger. Bounded at ~5s: a doctor
# that hangs on somebody's bar is worse than one that misses a finding.
badge_renders() {  # badge_renders <statusline-command>
  local cmd="$1" tmp state pid rc=1 i=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/aiworks-badge.XXXXXX" 2>/dev/null)" || return 1
  state="$(mktemp -d "${TMPDIR:-/tmp}/aiworks-badge-state.XXXXXX" 2>/dev/null)" || { rm -f "$tmp"; return 1; }
  (
    printf '{"session_id":"aiworks-doctor-probe","model":{"id":"aiworks-doctor-probe"}}' \
      | HEADROOM_STATE_DIR="$state" bash -c "$cmd" >"$tmp" 2>/dev/null
  ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [[ $i -lt 50 ]]; do sleep 0.1; i=$((i+1)); done
  kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  grep -qi 'headroom' "$tmp" && rc=0
  rm -rf "$tmp" "$state"
  return $rc
}

check_headroom() {
  local g=headroom
  cfg_bool headroom.enabled true
  case $? in
    1) skip $g "headroom" "headroom.enabled is false"; return ;;
    2) warn $g "headroom.enabled is not a boolean" "resolved to the default (on)" \
            "\$EDITOR workspace.config.yaml" ;;
  esac

  # ── the two guards hcat needs (root + every mirrored per-repo copy) ──
  # Checked FIRST and independent of whether headroom is installed: the holes are in OUR hooks,
  # and they are open the moment anyone on the team has hcat, not the moment this machine does.
  local hooks_rel=".claude/hooks/dev-wrapper" stale rp
  local env_rel="$hooks_rel/pretool-env-guard.sh" size_rel="$hooks_rel/pretool-hcat-size-guard.sh"

  # A workspace with no dev-wrapper hooks at all is a different SHAPE, not a regression — and
  # "the guard settings.json wires is missing" is already group 5's (agent-cfg) finding. Skipping
  # here keeps this group about hcat and keeps a fixture/foreign workspace from reading as broken.
  if [[ ! -d "$ROOT/$hooks_rel" ]]; then
    skip $g "hcat guards" "no .claude/hooks/dev-wrapper in this workspace"
  elif [[ ! -f "$ROOT/$env_rel" ]]; then
    skip $g "hcat guards" "no dev-wrapper env guard to extend"
  elif ! grep -q 'hcat' "$ROOT/$env_rel"; then
    fail $g "env guard does not cover hcat" \
         "hcat prints any file it is given, so it is a .env read — and \\bcat\\b cannot match it" \
         "see: restore the hcat alternative in $env_rel (see docs/agents/headroom.md)" slow
  else
    stale=0
    for rp in $SELECTED; do
      repo_ready "$rp" || continue
      [[ -f "$ROOT/$rp/$env_rel" ]] || continue
      grep -q 'hcat' "$ROOT/$rp/$env_rel" || stale=$((stale+1))
    done
    if [[ $stale -gt 0 ]]; then
      fail $g "$stale repo(s) carry a pre-hcat .env guard" \
           "the mirrored copy is stale, so hcat can dump a .env in those repos" "./aiworks sync -y" slow
    else
      pass $g "env guard covers hcat" "root + mirrored copies"
    fi
  fi

  # The size guard is the ceiling the headroom plugin's own gate does not have. Measured: hcat on
  # a 250 MB .log passed the content through unchanged and printed 262 MB in 80s — the gate turns
  # a `cat` of that file INTO that, so without this hook the protection is the flood.
  if [[ ! -d "$ROOT/$hooks_rel" ]]; then
    :                                    # same shape reason as above; already reported once
  elif [[ ! -f "$ROOT/$size_rel" ]]; then
    fail $g "hcat size guard missing" \
         "hcat has no upper bound of its own — a huge file is passed through in full" \
         "./aiworks sync -y" slow
  else
    stale=0
    for rp in $SELECTED; do
      repo_ready "$rp" || continue
      [[ -f "$ROOT/$rp/$size_rel" ]] || stale=$((stale+1))
    done
    if [[ $stale -gt 0 ]]; then
      fail $g "$stale repo(s) have no hcat size guard" "the mirrored copy is missing" "./aiworks sync -y" slow
    else
      pass $g "hcat size guard present" "root + mirrored copies"
    fi
  fi

  # ── the engine ──
  if command -v headroom >/dev/null 2>&1; then
    pass $g "headroom engine" "$(headroom --version 2>/dev/null | head -1)"
  else
    # [mcp], not [all]: we run no proxy and headroom passes code through, so the ML/proxy extras
    # are install time and disk for nothing. See docs/agents/headroom.md.
    local inst
    if command -v uv >/dev/null 2>&1; then
      inst="uv tool install --python 3.13 'headroom-ai[mcp]'"
    elif command -v pipx >/dev/null 2>&1; then
      inst="pipx install 'headroom-ai[mcp]'"
    else
      inst="see: install uv (brew install uv), then uv tool install --python 3.13 'headroom-ai[mcp]'"
    fi
    warn $g "headroom engine not installed" \
         "hcat, the headroom MCP and the savings badge all fail open without it" "$inst" slow
  fi

  # ── the plugin (hooks + badge) ──
  local key="headroom-usage-indicator@headroom-tools"
  local reg="$HOME/.claude/plugins/installed_plugins.json"
  if ! command -v jq >/dev/null 2>&1; then
    skip $g "headroom plugin" "jq not on PATH — cannot read the plugin registry"
  elif [[ -f "$reg" ]] && jq -e --arg k "$key" \
         '(((.plugins // .)[$k]) // []) | any(.scope == "user")' "$reg" >/dev/null 2>&1; then
    pass $g "headroom plugin" "installed at user scope"
  else
    warn $g "headroom plugin not installed" \
         "declared in .claude/settings.json enabledPlugins, but declaring is not installing" \
         "claude plugin install $key -s user" slow
  fi

  # ── a knob the installed plugin does not read (C15) ──
  # DANGI_NUDGE_BYTES is set in .claude/settings.json env. Plugin 2.7.0 hardcodes NUDGE_BYTES=4096
  # and never reads it, so the setting is a statement of intent, not a threshold. Warn while that
  # is true; the check disappears on its own the day a release starts reading it.
  local want_nudge pdir
  want_nudge=$(command -v jq >/dev/null 2>&1 && jq -r '.env.DANGI_NUDGE_BYTES // ""' "$ROOT/.claude/settings.json" 2>/dev/null)
  if [[ -n "${want_nudge:-}" ]]; then
    pdir="$(ls -dt "$HOME"/.claude/plugins/cache/*/headroom-usage-indicator/*/ 2>/dev/null | head -1)"
    if [[ -z "$pdir" ]]; then
      skip $g "nudge threshold" "headroom plugin not installed on this machine — nothing to compare"
    elif grep -rq 'DANGI_NUDGE_BYTES' "$pdir"scripts "$pdir"hooks 2>/dev/null; then
      pass $g "nudge threshold" "the installed plugin reads DANGI_NUDGE_BYTES (=$want_nudge)"
    else
      warn $g "DANGI_NUDGE_BYTES is set but the installed plugin ignores it" \
           "settings.json asks for $want_nudge; $(basename "$(dirname "$pdir")")/$(basename "$pdir") hardcodes NUDGE_BYTES=4096, so every tool result over 4 KB still nudges" \
           "see: docs/agents/headroom.md — the knob is documented DEAD; nothing to fix locally" slow
    fi
  fi

  # ── the savings badge (per-person: it edits a MACHINE-GLOBAL user settings file) ──
  cfg_bool headroom.statusline true
  if [[ $? == 1 ]]; then
    skip $g "savings badge" "headroom.statusline is false"
    return
  fi
  local user_settings="$HOME/.claude/settings.json" sl=""
  if ! command -v jq >/dev/null 2>&1; then
    skip $g "savings badge" "jq not on PATH — cannot read the statusLine"
    return
  fi
  [[ -f "$user_settings" ]] && sl="$(jq -r '.statusLine.command // empty' "$user_settings" 2>/dev/null)"
  # Two ways to be wired, and the lib check below covers BOTH — a chained badge with no attribution
  # lib is exactly as blind as a directly-wired one — so establishing *that* the badge renders is
  # kept separate from asking whether it counts.
  local wired=""
  if printf '%s' "$sl" | grep -q 'headroom-statusline'; then
    wired="into the user statusLine"
  elif [[ -n "$sl" ]] && badge_renders "$sl"; then
    # Someone else's bar chained OURS. A chain bridge stores the command it replaced in its own
    # cache file and re-runs it, so the settings.json string no longer names headroom while the
    # badge still renders every second — a grep for the literal path reports "not wired" and sends
    # a person to re-run the plugin's doctor, which would then chain the bridge and nest them two
    # deep. Following the string is a losing game (each vendor stashes the original somewhere
    # else), so the question is answered the only way that stays true: render the bar and look.
    wired="through a chained statusLine command"
  fi
  if [[ -n "$wired" ]]; then
    # Wired is not the same as counting. The flat copy resolves attribution.jq BESIDE itself and its
    # compute() opens with `[ -n "$JQ_LIB" ] || return 0`, so without the lib the badge reads
    # "idle (not compressing yet)" forever, every session cache records n=0 saved=0 missed=0, and no
    # .totals is ever written — the all-time total is then unrecoverable for those sessions. The
    # plugin's own doctor copies scripts/statusline.sh there but never scripts/lib/, and still scores
    # the copy "current", so a green plugin doctor is NOT evidence the badge measures anything.
    local miss="" f lib
    for f in attribution.jq headroom-state.sh; do
      [[ -f "$HOME/.claude/$f" ]] || miss="$miss $f"
    done
    if [[ -z "$miss" ]]; then
      pass $g "savings badge" "wired $wired, attribution lib beside the copy"
    else
      # -t, not a version sort: BSD ls has no -v and a lexical sort puts 2.7.0 above 2.10.0.
      lib="$(ls -dt "$HOME"/.claude/plugins/cache/*/headroom-usage-indicator/*/scripts/lib 2>/dev/null | head -1)"
      if [[ -n "$lib" ]]; then
        warn $g "savings badge measures nothing" \
             "missing beside ~/.claude/headroom-statusline.sh:$miss — compute() bails, so the badge stays idle however much hcat runs" \
             "cp '$lib/attribution.jq' '$lib/headroom-state.sh' ~/.claude/" slow
      else
        warn $g "savings badge measures nothing" \
             "missing beside ~/.claude/headroom-statusline.sh:$miss, and no plugin scripts/lib to copy from" \
             "see: reinstall the headroom plugin, then re-run aiworks doctor --only headroom" slow
      fi
    fi
  else
    # The plugin's own doctor owns this: its merge is the one that chains an EXISTING statusLine
    # command and keeps the original under _headroomStatusLineBackup (with a .bak). Hand-editing
    # ~/.claude/settings.json here would fight it and lose whatever bar is already installed.
    warn $g "savings badge not wired" \
         "no headroom badge in the user statusLine — compression would run unmeasured" \
         "see: run /headroom-usage-indicator:doctor in Claude Code and accept the statusLine fix" slow
  fi

  # ── the badge's price table ──
  # The badge turns tokens into money with a per-model INPUT $/MTok looked up by substring in a
  # data file. A model absent from that table is not an error anywhere: the badge drops the money
  # segment, writes $0.000000 into that session's .totals, and the "all-time" figure stays at zero
  # however much the team actually compresses — the one number that would justify the feature is
  # the one a missing row silently zeroes. Detected from the ledger the badge itself wrote (tokens
  # saved with no dollars against them) rather than from a model id, because the id this machine
  # runs is not knowable from a shell script — and because that ledger is the symptom itself.
  # The remedy is `see:` on purpose: the framework does not carry a copy of Anthropic's price list.
  local state_dir="${HEADROOM_STATE_DIR:-$HOME/.claude/headroom-indicator}" unpriced
  unpriced=$(cat "$state_dir"/session-*.totals 2>/dev/null \
    | LC_ALL=C awk '$1+0 > 0 && $2+0 == 0 { n++ } END { print n+0 }')
  if [[ ! -d "$state_dir" ]]; then
    skip $g "badge price table" "no headroom ledger on this machine yet"
  elif [[ "${unpriced:-0}" -gt 0 ]]; then
    warn $g "$unpriced session(s) saved tokens the badge could not price" \
         "the model is missing from the badge's price table, so the badge shows no \$ and the all-time total can never leave 0" \
         "see: add that model's input \$/MTok to ~/.claude/headroom-model-prices.json (docs/agents/headroom.md)" slow
  else
    pass $g "badge price table" "every recorded saving is priced"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════
# 9 · triage
# ══════════════════════════════════════════════════════════════════════════════════
# Deployed-environment triage is the one capability workspace bring-up deliberately does NOT
# install: `aiworks sync` only reports it, and the identity behind k8s_triage can be created
# only by someone who owns the GCP project (docs/adr/0009). This group is where that gap
# becomes visible instead of surfacing as an absent MCP tool mid-investigation.
#
# Two items, deliberately at different tiers:
#
#   registration  a jq read of ~/.claude.json — offline and instant, and its owner command
#                 (`scripts/triage-mcp.sh sync`) is a safe, idempotent, local-scope write, so
#                 --fix runs it and the gap sync stopped closing is closed here.
#   k8s identity  gcloud + kubectl round-trips per cluster, which is exactly what --deep exists
#                 to fence off. Its fix needs a GCP project owner this machine may not be, so it
#                 is spelled `see:` and --fix routes it to "needs you" rather than running it.
check_triage() {
  local g=triage
  cfg_bool triage.enabled true
  case $? in
    1) skip $g "triage" "triage.enabled is false"; return ;;
    2) warn $g "triage.enabled is not a boolean" "resolved to the default (on)" \
            "\$EDITOR workspace.config.yaml" ;;
  esac

  # ── the read-only triage MCPs: pg_triage · redis_triage · k8s_triage ──
  local sh="$DIR/triage-mcp.sh"
  if [[ ! -x "$sh" ]]; then
    skip $g "triage MCPs" "scripts/triage-mcp.sh not present"
  elif ! command -v jq >/dev/null 2>&1; then
    # `status` reads the registration with jq. Without it every server would read as absent,
    # which is a tooling gap (group 6 owns it) wearing a triage finding's clothes.
    skip $g "triage MCPs" "jq not on PATH — cannot read the registration"
  else
    local out missing legacy drift
    out="$("$sh" status 2>/dev/null)"
    missing="$(printf '%s\n' "$out" | grep -c 'not registered' || true)"
    legacy="$( printf '%s\n' "$out" | grep -c 'LEGACY registration still present' || true)"
    drift="$(  printf '%s\n' "$out" | grep -c 'registered with a DIFFERENT command' || true)"
    missing="${missing:-0}"; legacy="${legacy:-0}"; drift="${drift:-0}"
    if [[ "$missing" -gt 0 ]]; then
      fail $g "$missing triage MCP(s) not registered" \
           "aiworks sync no longer registers them — this is the command that does" \
           "scripts/triage-mcp.sh sync"
    elif [[ "$legacy" -gt 0 ]]; then
      warn $g "a pre-0005 triage registration is still present" \
           "two servers over the same fleet until it is removed" \
           "scripts/triage-mcp.sh sync"
    elif [[ "$drift" -gt 0 ]]; then
      warn $g "a triage MCP is registered with a different command" \
           "left alone on purpose — somebody set that up by hand" \
           "see: scripts/triage-mcp.sh status"
    else
      pass $g "triage MCPs" "pg_triage · redis_triage · k8s_triage registered (local scope)"
    fi
  fi

  # ── the read-only Kubernetes identity (--deep) ──
  local k="$DIR/k8s/setup.sh"
  if [[ ! -x "$k" ]]; then
    skip $g "kubernetes triage identity" "scripts/k8s/setup.sh not present"
  elif [[ $DEEP == 0 ]]; then
    skip $g "kubernetes triage identity" "--deep only (gcloud + kubectl, per cluster)"
  else
    # --quiet prints nothing at all when there is nothing to check (no kubectl/gcloud, or no
    # GKE cluster in this kubeconfig), a ✓ per ready target, and a "N target(s) need attention"
    # line otherwise. It always exits 0, so the text is the verdict.
    local kout; kout="$("$k" --quiet 2>&1)"
    if [[ -z "${kout//[[:space:]]/}" ]]; then
      skip $g "kubernetes triage identity" "no GKE target in this kubeconfig (or kubectl/gcloud absent)"
    elif printf '%s\n' "$kout" | grep -q 'need attention'; then
      warn $g "the Kubernetes triage identity is not ready" \
           "scripts/k8s/setup.sh names the gap and its owner command, per cluster" \
           "see: scripts/k8s/setup.sh   (then a GCP project owner runs scripts/k8s/bootstrap-sa.sh --context <ctx>)"
    else
      pass $g "kubernetes triage identity" "every derived target reads and cannot write"
    fi
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════
# 9 · mcp   (--deep)
# ══════════════════════════════════════════════════════════════════════════════════
check_mcp() {
  local g=mcp
  local compose="$ROOT/.superset/mcp-compose.yml"
  [[ -f "$compose" ]] || { skip $g "mcp" "no .superset/mcp-compose.yml"; return; }
  command -v docker >/dev/null 2>&1 || { fail $g "docker not on PATH" "the shared MCP stack cannot run" \
                                              "./aiworks update --only brew" slow; return; }
  local running; running="$(docker compose -p aiworks-mcp ps --status running -q 2>/dev/null | grep -c . || true)"
  if [[ "${running:-0}" -gt 0 ]]; then
    pass $g "mcp stack up" "$running container(s)"
  else
    fail $g "mcp stack is down" "no running container in project aiworks-mcp" ".superset/mcp-services.sh up"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════
# 10 · services   (--deep)
# ══════════════════════════════════════════════════════════════════════════════════
port_open() { nc -z -G 1 127.0.0.1 "$1" >/dev/null 2>&1 || nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1; }

# Which ports matter is a per-workspace fact, so none are hardcoded: the list is read from
# the compose file that declares them. A port published there and not answering means the
# service is declared but down — the one thing worth saying that `mcp` (is the stack up at
# all?) does not already cover.
check_services() {
  local g=services
  local compose="$ROOT/.superset/mcp-compose.yml"
  command -v nc >/dev/null 2>&1 || { skip $g "port probes" "nc not on PATH"; return; }
  [[ -f "$compose" ]] || { skip $g "port probes" "no .superset/mcp-compose.yml to read ports from"; return; }

  # `- "127.0.0.1:${VAR:-25432}:8000"` → 25432, and a plain `- "127.0.0.1:25432:8000"` too.
  # The default inside the parameter expansion is what a workspace gets when it overrides
  # nothing, which is the case worth checking. awk, not sed: a two-expression sed split over
  # a continued line leaves the second expression indented, and BSD sed rejects that silently
  # enough that the group reported "no host ports" against a compose publishing three.
  local ports; ports="$(awk '
      match($0, /"[0-9.]*:\$\{[A-Z_]+:-[0-9]+\}:[0-9]+"/) {
        s = substr($0, RSTART, RLENGTH); sub(/.*:-/, "", s); sub(/\}.*/, "", s); print s; next
      }
      match($0, /"[0-9.]*:[0-9]+:[0-9]+"/) {
        s = substr($0, RSTART, RLENGTH); sub(/^"[0-9.]*:/, "", s); sub(/:.*/, "", s); print s
      }
    ' "$compose" | sort -un)"
  if [[ -z "$ports" ]]; then
    skip $g "port probes" "the compose file publishes no host ports"
    return
  fi
  local p n=0
  for p in $ports; do
    n=$((n+1))
    if port_open "$p"; then
      pass $g "port $p" "127.0.0.1:$p answering"
    else
      warn $g "declared port $p not listening" "published by .superset/mcp-compose.yml" \
           ".superset/mcp-services.sh up"
    fi
  done
}

# ══════════════════════════════════════════════════════════════════════════════════
# 11 · credentials   (--deep)
# ══════════════════════════════════════════════════════════════════════════════════
# Group 3 proves a variable is SET. This proves it is ACCEPTED — an expired token is set and
# useless, and the difference only shows against the live API. Each probe is that adapter's
# own read-only reader, so no request shape is invented here.
probe() {  # <group> <label> <fix> <cmd…>
  local g="$1" label="$2" fix="$3"; shift 3
  if "$@" >/dev/null 2>&1; then pass "$g" "$label authenticates"
  else fail "$g" "$label rejected the credential" "the value is set but the API did not accept it" "$fix"
  fi
}

check_credentials() {
  local g=credentials
  local vcsp; vcsp="$(cfg vcs.provider)"
  case "$vcsp" in
    gitlab) command -v glab >/dev/null 2>&1 \
              && probe $g "vcs (gitlab)" "glab auth login" glab api user \
              || skip $g "vcs (gitlab)" "glab not installed" ;;
    github) command -v gh >/dev/null 2>&1 \
              && probe $g "vcs (github)" "gh auth login" gh api user \
              || skip $g "vcs (github)" "gh not installed" ;;
    *)      skip $g "vcs" "no provider configured" ;;
  esac

  local tp; tp="$(cfg tracker.provider)"
  if [[ -z "$tp" ]]; then
    skip $g "tracker" "no provider configured"
  elif [[ -x "$ROOT/scripts/tracker/find-tickets.sh" ]]; then
    probe $g "tracker ($tp)" "\$EDITOR scripts/tracker/.env" \
          "$ROOT/scripts/tracker/find-tickets.sh" --limit 1
  else
    skip $g "tracker" "find-tickets.sh not present"
  fi

  # notify has no probe worth running. `send.sh --dry-run` previews without contacting Slack,
  # so a green there would prove the flags parse and nothing about the token; the call that
  # WOULD prove it posts a message, and a health check must not put noise in a team channel.
  # Reaching auth.test directly is out — adapters are the only sanctioned door to Slack. So
  # this stays honest and unproven: group 3 already confirmed the token is SET.
  local np; np="$(cfg notify.provider)"
  skip $g "notify${np:+ ($np)}" \
       "no read-only probe exists — a dry run never authenticates and a real send would post"

  # --since -5m, not find-traces' default -7d: an unfiltered count over seven days aggregates every
  # span in the estate, takes ~60s, and intermittently hits the gateway timeout — a failure probe()
  # would then report as a rejected credential. Five minutes proves the same thing in ~2s.
  local op; op="$(cfg observability.provider)"
  # Default matches workspace.config.example.yaml (off) — same gate as check_adapters.
  cfg_bool observability.enabled false
  if [[ $? == 1 ]]; then
    skip $g "observability" "observability.enabled is false"
  elif [[ -z "$op" ]]; then
    skip $g "observability" "no provider configured"
  elif [[ -x "$ROOT/scripts/observability/find-traces.sh" ]]; then
    probe $g "observability ($op)" "\$EDITOR scripts/observability/.env" \
          "$ROOT/scripts/observability/find-traces.sh" --since -5m --limit 1
  else
    skip $g "observability" "find-traces.sh not present"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════
# 12 · disk   (--deep)
# ══════════════════════════════════════════════════════════════════════════════════
check_disk() {
  local g=disk
  [[ -x "$DIR/aiworks-gc.sh" ]] || { skip $g "worktree disk" "aiworks-gc.sh not present"; return; }
  # Read the COUNT `aiworks gc` prints ("live: 3 · orphaned: 0 · …"), not the number of lines
  # that happen to say "orphan" — its section headings say it too, so a line count reports
  # orphans on a workspace that has none.
  local out; out="$("$DIR/aiworks-gc.sh" 2>&1)"
  local orphans; orphans="$(printf '%s\n' "$out" | sed -n 's/.*orphaned:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
  if [[ -z "$orphans" ]]; then
    skip $g "worktree disk" "aiworks gc printed no orphan count to read"
  elif [[ "$orphans" -gt 0 ]]; then
    warn $g "$orphans orphaned worktree(s)" "Superset no longer lists them but the directories remain" \
         "./aiworks gc --orphans --artifacts" slow
  else
    pass $g "worktree disk" "nothing orphaned"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════
# run
# ══════════════════════════════════════════════════════════════════════════════════
run_group() {
  local g="$1" state; state="$(group_state "$g")"
  [[ "$state" == skip-flag ]] && return 0                    # excluded on purpose: say nothing
  # A repo-narrowed run has nothing to say about machine-wide groups. Checked BEFORE the
  # --deep skip, because "you asked about one repo" is the more specific reason of the two.
  if [[ $NARROWED == 1 ]]; then
    case "$g" in tooling|voice|headroom|triage|mcp|services|credentials|disk)
      skip "$g" "$g" "not repo-scoped"; return 0 ;;
    esac
  fi
  [[ "$state" == skip-deep ]] && { skip "$g" "$g" "--deep only"; return 0; }
  case "$g" in
    workspace)   check_workspace ;;
    repos)       check_repos ;;
    adapters)    check_adapters ;;
    per-repo)    check_per_repo ;;
    agent-cfg)   check_agent_cfg ;;
    tooling)     check_tooling ;;
    voice)       check_voice ;;
    headroom)    check_headroom ;;
    triage)      check_triage ;;
    mcp)         check_mcp ;;
    services)    check_services ;;
    credentials) check_credentials ;;
    disk)        check_disk ;;
  esac
  return 0
}

for grp in $ALL_GROUPS; do run_group "$grp"; done

# ── render ────────────────────────────────────────────────────────────────────────
rec() { printf '%s' "$1" | cut -d"$US" -f"$2"; }

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'; }

if [[ $JSON == 1 ]]; then
  printf '{\n'
  printf '  "workspace": "%s",\n' "$(json_escape "$ROOT")"
  printf '  "worktree": %s,\n' "$( [[ $IN_WORKTREE == 1 ]] && printf 'true' || printf 'false' )"
  printf '  "deep": %s,\n' "$( [[ $DEEP == 1 ]] && printf 'true' || printf 'false' )"
  printf '  "checks": [\n'
  i=0
  for r in ${R+"${R[@]}"}; do
    [[ $i -gt 0 ]] && printf ',\n'
    printf '    {"group":"%s","status":"%s","label":"%s","detail":"%s","fix":"%s"}' \
      "$(json_escape "$(rec "$r" 1)")" "$(json_escape "$(rec "$r" 2)")" \
      "$(json_escape "$(rec "$r" 3)")" "$(json_escape "$(rec "$r" 4)")" \
      "$(json_escape "$(rec "$r" 5)")"
    i=$((i+1))
  done
  printf '\n  ],\n'
  printf '  "summary": {"pass":%d,"warn":%d,"fail":%d,"skip":%d}\n' "$n_pass" "$n_warn" "$n_fail" "$n_skip"
  printf '}\n'
else
  printf '\n%saiworks doctor%s  %s%s%s\n' "$c_hd" "$c_off" "$c_dim" "$ROOT" "$c_off"
  if [[ $IN_WORKTREE == 1 ]]; then
    printf '%s  worktree: %s%s\n' "$c_dim" "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)" "$c_off"
    printf '%s  main clone: %s%s\n' "$c_dim" "$MAIN_CLONE" "$c_off"
  fi
  printf '\n'
  # A detail is often a list of every repo that tripped the check. All 22 of them on one line
  # buries the finding it is meant to explain, so the line is capped and the remainder counted
  # — the fix command is the same either way, and -v / --json still carry the full list.
  ellip() {
    local s="$1" max="${2:-96}"
    if [[ ${#s} -le $max ]]; then printf '%s' "$s"; return; fi
    local head="${s:0:$max}"; head="${head% *}"
    local rest="${s:${#head}}"
    local more; more="$(printf '%s' "$rest" | wc -w | tr -d ' ')"
    printf '%s … (+%s more)' "$head" "$more"
  }

  for grp in $ALL_GROUPS; do
    shown=0 npass_g=0
    # Collapsed passes become one count on the group's own line: a healthy group should take
    # one line, not fifteen, or the two that are broken never catch your eye.
    if [[ $VERBOSE == 0 ]]; then
      for r in ${R+"${R[@]}"}; do
        [[ "$(rec "$r" 1)" == "$grp" && "$(rec "$r" 2)" == pass ]] && npass_g=$((npass_g+1))
      done
      if [[ $npass_g -gt 0 ]]; then
        printf '  %-12s %s %s%d ok%s\n' "$grp" "${c_ok}✓${c_off}" "$c_dim" "$npass_g" "$c_off"
        shown=1
      fi
    fi
    for r in ${R+"${R[@]}"}; do
      [[ "$(rec "$r" 1)" == "$grp" ]] || continue
      st="$(rec "$r" 2)"; lb="$(rec "$r" 3)"; dt="$(rec "$r" 4)"; fx="$(rec "$r" 5)"
      [[ "$st" == pass && $VERBOSE == 0 ]] && continue
      case "$st" in
        pass) gl="${c_ok}✓${c_off}" ;;
        warn) gl="${c_warn}!${c_off}" ;;
        fail) gl="${c_err}✗${c_off}" ;;
        skip) gl="${c_dim}·${c_off}" ;;
      esac
      if [[ $shown == 0 ]]; then printf '  %-12s %s %s\n' "$grp" "$gl" "$lb"
      else                       printf '  %-12s %s %s\n' "" "$gl" "$lb"; fi
      [[ -n "$dt" ]] && printf '  %-12s   %s%s%s\n' "" "$c_dim" "$(ellip "$dt")" "$c_off"
      [[ -n "$fx" ]] && printf '  %-12s   %s→ %s%s\n' "" "$c_hd" "$(ellip "$fx" 110)" "$c_off"
      shown=$((shown+1))
    done
  done
  printf '\n  %s%d pass%s · %s%d warn%s · %s%d fail%s · %s%d skip%s\n' \
    "$c_ok" "$n_pass" "$c_off" "$c_warn" "$n_warn" "$c_off" \
    "$c_err" "$n_fail" "$c_off" "$c_dim" "$n_skip" "$c_off"
  [[ $VERBOSE == 0 ]] && printf '  %s-v for every passing check · --deep for daemons, ports and live credentials%s\n' \
    "$c_dim" "$c_off"
fi

# ── --fix ─────────────────────────────────────────────────────────────────────────
# Every command below belongs to another script. This runs them; it does not reimplement
# them, so there is still exactly one place in the workspace that performs each write.
if [[ $FIX == 1 ]]; then
  # A fix is AUTOMATABLE only if running it unattended is the whole answer. Three kinds are
  # not: anything that opens an editor (a secret, a judgement call), anything whose "fix" is
  # to go read something, and anything spelled `see:` — the advisory form for an install this
  # script has no business performing on your machine.
  manual_fix() {
    case "$1" in
      'see:'*|*'$EDITOR'*|'grep '*|*' grep -'*) return 0 ;;
      *) return 1 ;;
    esac
  }

  PLAN=(); MANUAL=()
  for f in ${FIXES+"${FIXES[@]}"}; do
    cost="$(rec "$f" 1)"; label="$(rec "$f" 2)"; cmd="$(rec "$f" 3)"
    if manual_fix "$cmd"; then MANUAL+=("$f"); continue; fi
    dup=0
    for p in ${PLAN+"${PLAN[@]}"}; do [[ "$(rec "$p" 3)" == "$cmd" ]] && { dup=1; break; }; done
    [[ $dup == 0 ]] && PLAN+=("$cost$US$label$US$cmd")
  done

  printf '\n%s--fix%s\n' "$c_hd" "$c_off"
  if [[ ${#PLAN[@]} -eq 0 ]]; then
    printf '  nothing to run automatically.\n'
  else
    printf '  will run, in order:\n'
    for p in "${PLAN[@]}"; do
      printf '    %-52s %s%s%s\n' "$(rec "$p" 3)" "$c_dim" \
        "$( [[ "$(rec "$p" 1)" == slow ]] && printf 'slow' || printf 'fast' )" "$c_off"
    done
  fi
  if [[ ${#MANUAL[@]} -gt 0 ]]; then
    printf '  needs you (a secret or a judgement call):\n'
    for m in "${MANUAL[@]}"; do printf '    %s\n      %s\n' "$(rec "$m" 2)" "$(rec "$m" 3)"; done
  fi

  if [[ ${#PLAN[@]} -gt 0 ]]; then
    if [[ $DRY == 1 ]]; then
      printf '\n  --dry-run: nothing was run.\n'
    else
      go=$YES
      if [[ $go == 0 ]]; then
        printf '\n  proceed? [y/N] '
        read -r ans || ans=""
        case "$ans" in y|Y|yes|YES) go=1 ;; esac
      fi
      if [[ $go == 1 ]]; then
        printf '\n'
        nfixed=0 nfailed=0
        for p in "${PLAN[@]}"; do
          cmd="$(rec "$p" 3)"
          printf '  %s→ %s%s\n' "$c_hd" "$cmd" "$c_off"
          if fixout="$( (cd "$ROOT" && eval "$cmd") 2>&1 )"; then
            printf '    %s✓ done%s\n' "$c_ok" "$c_off"; nfixed=$((nfixed+1))
          else
            printf '    %s✗ failed%s\n' "$c_err" "$c_off"; nfailed=$((nfailed+1))
            printf '%s\n' "$fixout" | tail -n 8 | sed 's/^/      /'
          fi
        done
        printf '\n  %d fixed · %d failed · %d need you\n' "$nfixed" "$nfailed" "${#MANUAL[@]}"
        printf '  re-run: aiworks doctor\n'
      else
        printf '  cancelled.\n'
      fi
    fi
  fi
fi

# ── verdict ───────────────────────────────────────────────────────────────────────
if [[ $n_fail -gt 0 ]]; then exit 1; fi
if [[ $STRICT == 1 && $n_warn -gt 0 ]]; then exit 1; fi
exit 0
