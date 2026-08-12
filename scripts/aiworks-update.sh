#!/usr/bin/env bash
#
# aiworks-update.sh  (`aiworks update`) — move the workspace's PREREQUISITE tooling forward,
# in one shot.
#
# `aiworks setup` only ever INSTALLS what is missing: every ensure_* helper in .superset/lib.sh
# returns early the moment the binary is on PATH ("glab already installed (…)"), and node_install
# is a lockfile install. So nothing in the workspace ever upgrades a tool — this is that missing
# half. It upgrades each prerequisite THROUGH THE INSTALLER THAT OWNS IT on THIS machine, and
# skips (never fights) a tool that came from somewhere else.
#
# Groups — all run by default; narrow with --only / --skip:
#   brew       the brew-owned prerequisites: mani, glab, gh, jq, dap, k6, pnpm (+ the ngrok
#              cask). Each is upgraded ONLY if brew actually owns it here, so a jq from /usr/bin or
#              a pnpm from nvm is left alone rather than shadowed by a second copy. The list is the
#              one `aiworks doctor` reports currency for, so the command it names can actually fix
#              what it flagged — keep the two in step.
#   rust       rustup update — the Rust toolchain (any Rust service/repo in the workspace).
#   pnpm       corepack prepare pnpm@latest, but ONLY when brew does not own pnpm (else the brew
#              group already handled it). Stays inside the CURRENT node; never switches node.
#   gcloud     gcloud components update.
#   claude     claude update — the Claude Code CLI.
#   codegraph  codegraph upgrade — the per-repo code index CLI.
#   plugins    claude plugin marketplace update, then `claude plugin update` for every plugin in
#              .claude/settings.json enabledPlugins. Needs a Claude Code restart to take effect.
#   skills     npx skills update -p — the third-party Agent Skills declared in skills-lock.json
#              at the workspace ROOT (project scope only; see the note below on the other scopes).
#              There is no binary to version-probe, so "updated" is derived from each skill's
#              computedHash in the lock; -v lists the per-skill hash change. This is the ONE group
#              that rewrites TRACKED files (skills-lock.json + .agents/skills/**) — it never
#              commits: the changed paths are printed for you to review.
#              A LOCALLY PATCHED skill is protected. The CLI rewrites every skill file on every run,
#              so this group 3-way merges each rewritten file — ours (HEAD) + the upstream baseline
#              committed under .agents/.skills-upstream/ + the new upstream copy — keeping BOTH the
#              upstream change and the local patch. With no baseline yet the local version wins and
#              the baseline is seeded (re-run to take upstream on top); on overlapping edits the
#              local version is kept and the new upstream copy is parked at <path>.upstream.new —
#              conflict markers are never written into a file an agent loads as instructions.
#   mcp        docker compose pull the shared MCP images (.superset/mcp-compose.yml), then
#              restart the stack via .superset/mcp-services.sh.
#
# Deliberately NOT touched — each is REPORTED, never performed:
#   • node itself. An nvm major switch moves the global bin dir, so pnpm and every other global
#     package silently drops off PATH. The exact safe command (with --reinstall-packages-from)
#     is printed for you to run by hand.
#   • repo dependencies. `npm update` / `cargo update` REWRITE a lockfile — that is a code change
#     needing a branch, a test run and an MR per repo, not a maintenance chore. `--check-deps`
#     reports what is outdated across every cloned repo and writes nothing.
#   • per-repo and GLOBAL skills. Every clone carries its own TRACKED skills-lock.json (written by
#     `aiworks add` step 6), so bumping 20-odd of them is an MR per repo for the same reason a
#     dependency bump is — and the global scope (~/.agents/skills) is the person's own, outside
#     this workspace. The `skills` group updates the ROOT lock only.
#   • Docker Desktop — a self-updating GUI app; only its version is reported.
#
# Every step is best-effort: a single failure never aborts the run. The closing summary lists each
# tool as updated / current / skipped / FAILED with its before→after version.
#
# Usage: aiworks-update.sh [-n|--dry-run] [--only a,b] [--skip a,b] [--check-deps] [-v] [-h]
#   -n, --dry-run    print the command each group WOULD run; change nothing.
#       --only a,b   run only these groups (comma-separated; see the list above).
#       --skip a,b   run every group EXCEPT these.
#       --check-deps also report outdated dependencies per cloned repo (read-only, slow).
#   -v, --verbose    stream each command's full output (default: a collapsing glance).
#   -h, --help       show this help.
#
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
[[ -f "$ROOT/mani.yaml" ]] || { printf 'error: no mani.yaml in %s — run this from a workspace\n' "$ROOT" >&2; exit 1; }
cd "$ROOT"

# log / warn / err / conclude / run_glance — the same renderer the .superset lifecycle scripts
# use, so `aiworks update` reads like `aiworks setup`. lib.sh is pure function definitions.
# shellcheck source=/dev/null
. "$ROOT/.superset/lib.sh"

ALL_GROUPS="brew rust pnpm gcloud claude codegraph plugins skills mcp"

# ── args ─────────────────────────────────────────────────────────────────────────
DRY=0 CHECK_DEPS=0 ONLY="" SKIP=""
usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)  DRY=1; shift ;;
    --only)        ONLY="${2:-}"; shift 2 ;;
    --only=*)      ONLY="${1#*=}"; shift ;;
    --skip)        SKIP="${2:-}"; shift 2 ;;
    --skip=*)      SKIP="${1#*=}"; shift ;;
    --check-deps)  CHECK_DEPS=1; shift ;;
    -v|--verbose)  VERBOSE=1; export VERBOSE; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) err "unknown option: $1   (see -h)"; exit 1 ;;
  esac
done

# Validate the group names up front — a typo in --only would otherwise silently run nothing.
for g in $(printf '%s' "$ONLY$SKIP" | tr ',' ' '); do
  case " $ALL_GROUPS " in *" $g "*) ;; *) err "unknown group '$g' (valid: $(echo "$ALL_GROUPS" | tr ' ' ','))"; exit 1 ;; esac
done

want() {  # <group> — is this group in scope?
  local g="$1"
  if [[ -n "$ONLY" ]]; then case ",$ONLY," in *",$g,"*) return 0 ;; *) return 1 ;; esac; fi
  case ",$SKIP," in *",$g,"*) return 1 ;; esac
  return 0
}

# ── summary ledger (bash 3.2: a TSV temp file, not an associative array) ─────────
SUMMARY="$(mktemp -t aiworks-update)" || SUMMARY=""
record() { [[ -n "$SUMMARY" ]] && printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:--}" "${4:--}" >>"$SUMMARY"; }
cleanup() { [[ -n "$SUMMARY" ]] && rm -f "$SUMMARY"; }
trap cleanup EXIT

# First version-ish line a tool prints, squeezed to one line. Tries the usual spellings so one
# helper covers `--version`, bare `version`, and the tools that only answer on stderr.
tool_version() {  # <binary>
  local b="$1" v=""
  command -v "$b" >/dev/null 2>&1 || { printf 'absent'; return; }
  v="$("$b" --version 2>/dev/null | head -1)"
  [[ -z "$v" ]] && v="$("$b" version 2>/dev/null | head -1)"
  [[ -z "$v" ]] && v="$("$b" --version 2>&1 | head -1)"
  printf '%s' "${v:-unknown}" | tr -d '\r' | cut -c1-40
}

# Run one upgrade and record the outcome, comparing the tool's version before and after so
# "current" and "updated" are DERIVED from the binary rather than guessed from the exit code.
# Pass the binary to version-probe (or "" to skip the probe and just report ok/failed).
upgrade() {  # <label> <probe-binary|""> <cmd> [args…]
  local label="$1" probe="$2"; shift 2
  local before="" after="" rc=0
  [[ -n "$probe" ]] && before="$(tool_version "$probe")"
  if [[ "$DRY" == 1 ]]; then
    conclude "would run: $*"
    record "$label" "dry-run" "$before" "-"
    return 0
  fi
  run_glance "$label" "$@" || rc=$?
  [[ -n "$probe" ]] && after="$(tool_version "$probe")"
  if [[ "$rc" -ne 0 ]]; then
    warn "$label: exited $rc — left as-is."
    record "$label" "FAILED" "$before" "$after"
  elif [[ -z "$probe" ]]; then
    # No binary to compare (a marketplace refresh, an image pull, a service restart) — the exit
    # code proves it RAN, not that anything moved. Saying "updated" here would inflate the count
    # with steps that may well have been no-ops.
    record "$label" "ok" "-" "-"
  elif [[ "$before" == "$after" ]]; then
    record "$label" "current" "$before" "$after"
  else
    record "$label" "updated" "$before" "$after"
  fi
  return 0
}

brew_owns() {  # <formula-or-cask> [--cask]
  command -v brew >/dev/null 2>&1 || return 1
  brew list "${2:---formula}" --versions "$1" >/dev/null 2>&1
}

conclude "aiworks update — $ROOT"
[[ "$DRY" == 1 ]] && conclude "DRY RUN — nothing will be changed."

# ── brew ─────────────────────────────────────────────────────────────────────────
# The prerequisites brew CAN own. Each is upgraded only if it actually does: jq is /usr/bin/jq
# on a stock macOS and pnpm usually rides along with nvm's node, so blanket-upgrading either
# would install a SECOND copy that shadows the one the workspace has been running on.
# This list must match the one aiworks-doctor.sh version-currency greps: doctor points its warn
# at `aiworks update --only brew`, so a name it flags but this list omits is a warn no command can
# clear (gh and pnpm were both in that hole). A tool absent from this machine is skipped by
# brew_owns, so listing one costs nothing.
BREW_FORMULAE="mani glab gh jq dap k6 pnpm"
BREW_CASKS="ngrok"
if want brew; then
  if ! command -v brew >/dev/null 2>&1; then
    warn "Homebrew not installed — skipping the brew group."
    record "brew" "skipped" "absent" "-"
  else
    upgrade "brew update (refresh formula index)" "" brew update
    for f in $BREW_FORMULAE; do
      if brew_owns "$f"; then upgrade "brew upgrade $f" "$f" brew upgrade "$f"
      else
        log "$f: not brew-owned here ($(command -v "$f" 2>/dev/null || echo 'not installed')) — leaving it alone."
        record "$f" "skipped" "$(tool_version "$f")" "not brew-owned"
      fi
    done
    for c in $BREW_CASKS; do
      if brew_owns "$c" --cask; then upgrade "brew upgrade --cask $c" "$c" brew upgrade --cask "$c"
      else
        log "$c: not a brew cask here — leaving it alone."
        record "$c" "skipped" "$(tool_version "$c")" "not brew-owned"
      fi
    done
  fi
fi

# ── rust ─────────────────────────────────────────────────────────────────────────
if want rust; then
  if command -v rustup >/dev/null 2>&1; then
    upgrade "rustup update" "cargo" rustup update
  else
    warn "rustup not installed — the Rust services build on the system toolchain."
    record "rust" "skipped" "absent" "-"
  fi
fi

# ── pnpm (only when brew is not the owner — else the brew group already did it) ───
if want pnpm; then
  if brew_owns pnpm; then
    log "pnpm is brew-owned — handled by the brew group."
  elif command -v corepack >/dev/null 2>&1; then
    upgrade "corepack prepare pnpm@latest" "pnpm" corepack prepare pnpm@latest --activate
  elif command -v npm >/dev/null 2>&1; then
    upgrade "npm install -g pnpm@latest" "pnpm" npm install -g pnpm@latest
  else
    warn "no corepack and no npm — cannot update pnpm."
    record "pnpm" "skipped" "$(tool_version pnpm)" "-"
  fi
fi

# ── gcloud ───────────────────────────────────────────────────────────────────────
if want gcloud; then
  if command -v gcloud >/dev/null 2>&1; then
    upgrade "gcloud components update" "gcloud" gcloud components update --quiet
  else
    record "gcloud" "skipped" "absent" "-"
  fi
fi

# ── claude ───────────────────────────────────────────────────────────────────────
if want claude; then
  if command -v claude >/dev/null 2>&1; then
    upgrade "claude update" "claude" claude update
  else
    record "claude" "skipped" "absent" "-"
  fi
fi

# ── codegraph ────────────────────────────────────────────────────────────────────
if want codegraph; then
  if command -v codegraph >/dev/null 2>&1; then
    upgrade "codegraph upgrade" "codegraph" codegraph upgrade
  else
    record "codegraph" "skipped" "absent" "-"
  fi
fi

# ── claude plugins ───────────────────────────────────────────────────────────────
# The plugins the workspace DECLARES (.claude/settings.json enabledPlugins) — the same list
# ensure_claude_plugins installs at user scope during setup, so update reads the same source.
if want plugins; then
  if ! command -v claude >/dev/null 2>&1; then
    record "plugins" "skipped" "no claude CLI" "-"
  elif ! command -v jq >/dev/null 2>&1; then
    warn "jq unavailable — cannot read enabledPlugins; update plugins by hand (claude plugin update <plugin>@<marketplace>)."
    record "plugins" "skipped" "no jq" "-"
  else
    upgrade "claude plugin marketplace update" "" claude plugin marketplace update
    plugin_keys="$(jq -r '.enabledPlugins // {} | keys[]' .claude/settings.json 2>/dev/null)"
    if [[ -z "$plugin_keys" ]]; then
      log "no plugins declared in .claude/settings.json."
    else
      for key in $plugin_keys; do upgrade "claude plugin update $key" "" claude plugin update "$key"; done
      warn "plugins updated — RESTART Claude Code for the new versions to load."
    fi
  fi
fi

# ── third-party Agent Skills (the `skills` CLI, ROOT project scope) ──────────────
# The skills in skills-lock.json — installed with `npx skills add …` (aiworks add step 6 does the
# same inside each repo). Nothing here has a binary to version-probe, so "updated" is DERIVED from
# the per-skill computedHash the CLI writes into the lock: hashes read before and after, compared
# by name. Same idea as the version probe above, one level down.
skills_hashes() {  # → "<name>\t<hash>" per skill, sorted by name
  [[ -f skills-lock.json ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r '.skills // {} | to_entries[] | "\(.key)\t\(.value.computedHash // "-")"' skills-lock.json 2>/dev/null | sort
  else
    # No jq: one digest of the whole lock under a sentinel name. Enough to say something moved,
    # never WHICH skill — reported as such rather than guessed.
    printf '(whole lock)\t%s\n' "$(shasum -a 256 skills-lock.json 2>/dev/null | cut -d' ' -f1)"
  fi
}

# ── local patches vs a new upstream copy: 3-way merge, not a coin flip ───────────
# The CLI re-downloads and REWRITES every skill file on every run, so a skill this workspace has
# PATCHED (e.g. the LANGUAGE_DIRECTIVE block in diagnosing-bugs/SKILL.md) silently reverts to
# upstream — and its lock hash, computed on UPSTREAM content, cannot move to signal that. Measured
# on the first live run here: 35 local lines vanished under a "current" verdict.
#
# So keep a baseline mirror — the upstream copy as of the LAST update, committed under
# .agents/.skills-upstream/. With it every rewritten file is a real 3-way merge: ours (HEAD,
# patched) + base (old upstream) + theirs (new upstream), so an upstream change AND a local patch
# both survive. Without it (first run, or a skill installed since) the LOCAL version wins — the
# only choice that cannot destroy work — and the baseline is seeded for the next run.
SK_BASE_DIR=".agents/.skills-upstream"

sk_modified() {  # tracked files under .agents/skills that this run rewrote
  git status --porcelain -- .agents/skills 2>/dev/null | awk '/^[ MARC]M/ { print substr($0, 4) }'
}

sk_reconcile() {  # → SK_MERGED / SK_KEPT / SK_CONFLICT, each a space-separated path list
  SK_MERGED="" SK_KEPT="" SK_CONFLICT=""
  local p base ours theirs merged
  ours="$(mktemp -t aiworks-sk)"; theirs="$(mktemp -t aiworks-sk)"; merged="$(mktemp -t aiworks-sk)"
  while IFS= read -r p; do
    [[ -n "$p" && -f "$p" ]] || continue
    base="$SK_BASE_DIR/${p#.agents/skills/}"
    cp "$p" "$theirs"
    git show "HEAD:$p" >"$ours" 2>/dev/null || continue   # not in HEAD → no local version to protect
    if [[ ! -f "$base" ]]; then
      git checkout -- "$p" && SK_KEPT="$SK_KEPT$p "
      mkdir -p "$(dirname "$base")" && cp "$theirs" "$base"
    elif git merge-file -p "$ours" "$base" "$theirs" >"$merged" 2>/dev/null; then
      cat "$merged" >"$p"; cp "$theirs" "$base"; SK_MERGED="$SK_MERGED$p "
    else
      # Overlapping edits. Conflict markers must NEVER land in a skill file — an agent LOADS it as
      # instructions and would read "<<<<<<<" as content. Keep ours, park the new upstream copy
      # beside it, and leave the baseline OLD so the next run offers the same merge again.
      git checkout -- "$p"; cp "$theirs" "$p.upstream.new"; SK_CONFLICT="$SK_CONFLICT$p "
    fi
  done < <(sk_modified)
  rm -f "$ours" "$theirs" "$merged"
}

sk_seed_baseline() {  # <mark-file> — baseline the files the CLI actually WROTE this run
  # -newer the mark, NOT every file: a patched file the CLI happened to skip keeps its old mtime,
  # and baselining THAT would file our own patch as "what upstream says" — the next upstream change
  # would then merge cleanly over it and delete the patch for good.
  local mark="$1" p base n=0
  while IFS= read -r p; do
    base="$SK_BASE_DIR/${p#.agents/skills/}"
    [[ -f "$base" ]] && continue
    mkdir -p "$(dirname "$base")" && cp "$p" "$base" && n=$((n + 1))
  done < <(find .agents/skills -type f -newer "$mark" ! -name '*.upstream.new' 2>/dev/null)
  [[ "$n" -gt 0 ]] && log "seeded $n upstream baseline file(s) under $SK_BASE_DIR/"
  return 0
}

if want skills; then
  if [[ ! -f skills-lock.json ]]; then
    log "no skills-lock.json at the workspace root — no third-party skills to update."
    record "third-party skills" "skipped" "no lock" "-"
  elif ! command -v npx >/dev/null 2>&1; then
    warn "npx (Node) unavailable — update by hand: npx skills@latest update -p -y"
    record "third-party skills" "skipped" "no npx" "-"
  else
    sk_before="$(mktemp -t aiworks-skills)"; sk_after="$(mktemp -t aiworks-skills)"
    skills_hashes >"$sk_before"
    sk_n="$(wc -l <"$sk_before" | tr -d ' ')"
    if [[ "$DRY" == 1 ]]; then
      conclude "would run: npx -y skills@latest update -p -y   ($sk_n skill(s) in the lock)"
      record "third-party skills" "dry-run" "$sk_n skill(s)" "-"
    else
      # -p: project scope (this workspace), never the person's global scope. -y: skip the scope
      # prompt, which would otherwise hang a non-interactive run.
      sk_rc=0
      sk_mark="$(mktemp -t aiworks-sk-mark)"   # every skill file the CLI writes lands NEWER than this
      run_glance "npx skills update (project scope)" npx -y skills@latest update -p -y || sk_rc=$?
      skills_hashes >"$sk_after"
      # Reconcile BEFORE reporting: the patch rescue has to happen even when the CLI exited non-zero
      # (it writes files as it goes), and the hash verdict below should describe the reconciled tree.
      if [[ "$sk_rc" -lt 128 ]]; then
        sk_reconcile
        sk_seed_baseline "$sk_mark"
        sk_nmerged="$(printf '%s' "$SK_MERGED"   | wc -w | tr -d ' ')"
        sk_nkept="$(  printf '%s' "$SK_KEPT"     | wc -w | tr -d ' ')"
        sk_nconf="$(  printf '%s' "$SK_CONFLICT" | wc -w | tr -d ' ')"
        if [[ -n "$SK_MERGED$SK_KEPT$SK_CONFLICT" ]]; then
          record "skills local patches" "reconciled" "$sk_nmerged merged" "$sk_nkept kept-local, $sk_nconf conflict"
          [[ -n "$SK_MERGED" ]] && conclude "merged the new upstream INTO the local patch: $SK_MERGED"
          if [[ -n "$SK_KEPT" ]]; then
            warn "kept the LOCAL version (no upstream baseline existed yet): $SK_KEPT"
            warn "  baseline seeded — re-run 'aiworks update --only skills' to take the upstream change on top of it."
          fi
          if [[ -n "$SK_CONFLICT" ]]; then
            warn "CONFLICT — the local patch and upstream touch the same lines: $SK_CONFLICT"
            warn "  local version kept; the new upstream copy sits beside it as <path>.upstream.new — merge by hand."
          fi
        fi
      fi
      rm -f "$sk_mark"
      # moved = hash changed (or the skill is new to the lock); gone = dropped from the lock.
      sk_moved="$(awk -F'\t' 'NR==FNR{b[$1]=$2;next} !($1 in b){print $1" (new)";next} b[$1]!=$2{print $1}' "$sk_before" "$sk_after" | tr '\n' ' ')"
      sk_gone="$(awk -F'\t'  'NR==FNR{a[$1]=1;next} !($1 in a){print $1}' "$sk_after" "$sk_before" | tr '\n' ' ')"
      sk_nmoved="$(printf '%s' "$sk_moved" | wc -w | tr -d ' ')"
      if [[ "$sk_rc" -ge 128 ]]; then
        # npx/node killed by a signal at launch (memory pressure, a security agent on this box) —
        # a launch failure, not an update failure, and the tree is untouched. Same distinction
        # `aiworks add` step 6 draws, so a crash never reads as "the skill cannot be updated".
        warn "npx crashed (signal $((sk_rc - 128))) — nothing updated; retry: aiworks update --only skills"
        record "third-party skills" "skipped" "npx crashed" "-"
      elif [[ "$sk_rc" -ne 0 ]]; then
        warn "skills update: exited $sk_rc — left as-is."
        record "third-party skills" "FAILED" "$sk_n skill(s)" "-"
      elif [[ -z "$sk_moved$sk_gone" ]]; then
        record "third-party skills" "current" "$sk_n skill(s)" "$sk_n skill(s)"
      else
        record "third-party skills" "updated" "$sk_n skill(s)" "$sk_nmoved moved"
        [[ -n "$sk_moved" ]] && conclude "skills moved: $sk_moved"
        [[ -n "$sk_gone"  ]] && warn "no longer in the lock: $sk_gone"
        # -v: the per-skill hash change behind that count.
        awk -F'\t' 'NR==FNR{b[$1]=$2;next} { o = ($1 in b) ? substr(b[$1],1,8) : "absent"
                                             if (o != substr($2,1,8)) printf "    %-24s %s  →  %s\n", $1, o, substr($2,1,8) }' \
          "$sk_before" "$sk_after" | while IFS= read -r line; do log "$line"; done
      fi
      if [[ "$sk_rc" -lt 128 ]]; then
        # Integrity: every skill in the lock must still be REACHABLE at .claude/skills/<name> — the
        # CLI owns that entry (a symlink into .agents/skills/ here). A rewrite that drops or dangles
        # it takes the skill out of every session with no error anywhere, so check rather than trust.
        sk_broken=""
        while IFS=$'\t' read -r sk_name _; do
          [[ -z "$sk_name" || "$sk_name" == "(whole lock)" ]] && continue
          [[ -e ".claude/skills/$sk_name" ]] || sk_broken+="$sk_name "
        done <"$sk_after"
        if [[ -n "$sk_broken" ]]; then
          warn "unreachable under .claude/skills after the update: $sk_broken"
          warn "  restore them from the lock: npx -y skills@latest experimental_install"
          record "skills integrity" "FAILED" "$(printf '%s' "$sk_broken" | wc -w | tr -d ' ') missing" "-"
        fi
        # The lock, the skill files AND the baseline mirror are tracked here, so an update dirties the
        # tree. It is never committed for you — a merged skill file is new content whose diff the
        # author has to read, and the baseline bump belongs in the same commit as the merge it explains.
        sk_dirty="$(git status --short -- skills-lock.json .agents/skills "$SK_BASE_DIR" 2>/dev/null)"
        if [[ -n "$sk_dirty" ]]; then
          warn "the skills update touched TRACKED files — review and commit them yourself:"
          printf '%s\n' "$sk_dirty" | sed 's/^/        /'
        fi
      fi
    fi
    rm -f "$sk_before" "$sk_after"
  fi
fi

# ── shared MCP service images ────────────────────────────────────────────────────
if want mcp; then
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    warn "docker unavailable / daemon down — skipping the MCP image pull."
    record "mcp images" "skipped" "docker down" "-"
  elif [[ ! -f .superset/mcp-compose.yml ]]; then
    record "mcp images" "skipped" "no mcp-compose.yml" "-"
  else
    # --env-file only when the file is there; the image tags carry no interpolation, so the
    # pull works either way — this just keeps compose from warning about unset variables.
    compose_args=(-f .superset/mcp-compose.yml)
    [[ -f .superset/.env ]] && compose_args+=(--env-file .superset/.env)
    upgrade "docker compose pull (shared MCP images)" "" docker compose "${compose_args[@]}" pull
    if [[ "$DRY" != 1 ]]; then
      # Recreate off the freshly pulled images — a running container keeps its old image.
      upgrade "mcp-services: down" "" .superset/mcp-services.sh down
      upgrade "mcp-services: up"   "" .superset/mcp-services.sh up
    fi
  fi
fi

# ── report-only: the two things this script refuses to change for you ────────────
node_now="$(tool_version node)"
if [[ "$node_now" != absent ]]; then
  if command -v nvm >/dev/null 2>&1 || [[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
    record "node (manual)" "report" "$node_now" "nvm — see the note below"
  else
    record "node (manual)" "report" "$node_now" "not nvm-managed"
  fi
fi
command -v docker >/dev/null 2>&1 && record "docker (manual)" "report" "$(tool_version docker)" "Docker Desktop self-updates"

# ── optional: what repo dependencies are behind (READ-ONLY) ──────────────────────
if [[ "$CHECK_DEPS" == 1 ]]; then
  conclude "Outdated repo dependencies (read-only — nothing is written)"
  for repo in */; do
    repo="${repo%/}"
    [[ -e "$repo/.git" ]] || continue
    if [[ -f "$repo/package.json" ]]; then
      pm="$(node_pm "$repo")"
      if command -v "$pm" >/dev/null 2>&1; then
        # --json + jq, because the human output is NOT one line per package: npm prints a header
        # row and pnpm prints a summary line plus a table whose row count does not match the
        # package count. Both exit non-zero when they FIND something — that is the signal, not a
        # failure, so the status is ignored. No jq → the count is skipped rather than reported wrong.
        if command -v jq >/dev/null 2>&1; then
          n="$( (cd "$repo" && "$pm" outdated --json 2>/dev/null) | jq 'length' 2>/dev/null )"
          [[ "${n:-0}" -gt 0 ]] 2>/dev/null && printf '    %-28s %s package(s) outdated  (cd %s && %s outdated)\n' "$repo" "$n" "$repo" "$pm"
        fi
      fi
    fi
    if [[ -f "$repo/Cargo.toml" ]] && command -v cargo >/dev/null 2>&1; then
      # "Updating crates.io index" is the registry refresh, not a crate — exclude it or every
      # repo reads one crate high (and a repo with nothing to bump reads 1 instead of 0).
      n="$( (cd "$repo" && cargo update --dry-run 2>&1) | grep '^ *Updating ' | grep -vc 'index$' )"
      [[ "$n" -gt 0 ]] && printf '    %-28s %s crate(s) could bump   (cd %s && cargo update)\n' "$repo" "$n" "$repo"
    fi
  done
  warn "A dependency bump REWRITES a lockfile — branch, test and open an MR per repo (/dev-cycle). Never bulk-commit these."
fi

# ── summary ──────────────────────────────────────────────────────────────────────
conclude "Summary"
if [[ -n "$SUMMARY" && -s "$SUMMARY" ]]; then
  awk -F'\t' '
    { mark = ($2 == "FAILED") ? "✗" : ($2 == "updated") ? "✓" : ($2 == "ok") ? "✓" : "·"
      printf "    %s %-34s %-9s %s\n", mark, $1, $2, ($3 == $4 || $4 == "-") ? $3 : $3 "  →  " $4
      if ($2 == "FAILED") failed++
      if ($2 == "ok")      ran++
      if ($2 == "updated") updated++ }
    END { printf "\n    %d version(s) moved, %d step(s) ran, %d failed\n", updated + 0, ran + 0, failed + 0 }
  ' "$SUMMARY"
fi

cat <<'NOTE'

    node is NOT upgraded by this script. An nvm major switch moves the global bin dir, so
    pnpm and every other global package leaves PATH silently. Do it by hand, carrying the
    globals across:

        nvm install --lts --reinstall-packages-from="$(nvm current)"
        nvm alias default lts/*
        corepack prepare pnpm@latest --activate

    Then re-run `aiworks setup` so every repo reinstalls its deps against the new node.
NOTE

exit 0
