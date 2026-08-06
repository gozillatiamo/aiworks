#!/usr/bin/env bash
#
# aiworks-gc.sh  (`aiworks gc`) — reclaim disk from Superset worktrees, WITHOUT ever making
# two worktrees wait for each other.
#
# THE PROBLEM
#   Superset's UI "Delete" removes the workspace row but leaves behind (measured, 2026-08-06):
#     * the worktree DIRECTORY tree, build artifacts and all,
#     * the `git worktree` registration + .git/worktrees/<name> metadata in the parent repo,
#     * the local branch.
#   The slack-dispatch service leaks the same way, harder: it creates a worktree per @-mention
#   and has no cleanup path at all (only a manual one-liner in its RUNBOOK). One project
#   had 16.4 GiB of orphaned worktrees and a further 24.8 GiB of build artifacts.
#
# THE PARALLELISM INVARIANT  (the whole reason this is a reaper and not a shared cache)
#   Every worktree must stay able to build CONCURRENTLY with every other worktree. That rules
#   out the obvious disk fix — a shared CARGO_TARGET_DIR — because cargo takes an EXCLUSIVE
#   lock per target directory, so a second worktree's `cargo build` would block on the first.
#   The same objection applies to any shared, mutable, lock-guarded build dir.
#
#   So this script never creates shared state. It only DELETES per-worktree state, and only
#   from worktrees it has proven are idle. Three invariants, all enforced below:
#
#     I1. Nothing is ever made shared. Each worktree keeps its own target/ and node_modules.
#         There is no new lock, no new contention point, no change to how a build runs.
#     I2. Nothing is touched unless provably idle — three INDEPENDENT liveness checks
#         (recent mtime · held cargo lock · a process cwd inside), any one of which vetoes.
#     I3. --force relaxes the GIT safety refusal (dirty / unpushed) and NEVER the liveness
#         checks from I2. Deleting target/ under a running build corrupts it; no flag buys that.
#
#   The rebuild cost that I1 implies is answered separately, and also without shared locks:
#   `--enable-sccache` wires a compilation cache that is a concurrency-safe SERVER rather than
#   a locked directory, so a reaped worktree rebuilds from cache while others build in parallel.
#
# SOURCE OF TRUTH
#   Which workspaces still exist is read from `superset ws list --json`, never from
#   ~/.superset/*.sqlite. Reading the sqlite file directly under-reported live workspaces in
#   testing (it missed 2 of 6, including a 17 GiB one) — a GC that trusts it deletes live work.
#
# Usage: aiworks-gc.sh [selector…] [options]
#
#   Selectors — with NONE, every category is REPORTED and nothing is changed:
#     --orphans        reap worktrees Superset no longer lists (the UI-Delete leftovers)
#     --artifacts      reap target/ + node_modules from IDLE worktrees, live ones included
#     --dispatch       reap slack/req-* dispatch worktrees past their TTL
#     --all            all three
#
#   Options:
#     --project NAME   only this Superset project (default: every project)
#     --idle-days N    (--artifacts) idle threshold, default 3
#     --ttl-days N     (--dispatch)  age threshold, default 7
#     -n, --dry-run    print what WOULD happen; change nothing
#     -f, --force      remove even when dirty/unpushed (never overrides the liveness checks)
#     --enable-sccache one-time host setup: install sccache + wire it as rustc-wrapper
#     -v, --verbose    per-candidate detail, including why something was skipped
#     -h, --help       show this help
#
set -uo pipefail

# ── logging ──────────────────────────────────────────────────────────────────────
c_step=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_step=; c_ok=; c_warn=; c_err=; c_dim=; c_off=; }
VERBOSE=0
step() { printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s✓ %s%s\n' "$c_ok" "$*" "$c_off"; }
dim()  { [[ "$VERBOSE" -eq 1 ]] && printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; return 0; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    %s! %s%s\n' "$c_warn" "$*" "$c_off"; }
die()  { printf '%serror: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

# ── args ──────────────────────────────────────────────────────────────────────────
DO_ORPHANS=0 DO_ARTIFACTS=0 DO_DISPATCH=0 REPORT_ONLY=1
DRY=0 FORCE=0 IDLE_DAYS=3 TTL_DAYS=7 PROJECT= SCCACHE=0
usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --orphans)   DO_ORPHANS=1;  REPORT_ONLY=0; shift ;;
    --artifacts) DO_ARTIFACTS=1; REPORT_ONLY=0; shift ;;
    --dispatch)  DO_DISPATCH=1; REPORT_ONLY=0; shift ;;
    --all)       DO_ORPHANS=1; DO_ARTIFACTS=1; DO_DISPATCH=1; REPORT_ONLY=0; shift ;;
    --project)   PROJECT="${2:?--project needs a name}"; shift 2 ;;
    --idle-days) IDLE_DAYS="${2:?--idle-days needs a number}"; shift 2 ;;
    --ttl-days)  TTL_DAYS="${2:?--ttl-days needs a number}"; shift 2 ;;
    --enable-sccache) SCCACHE=1; shift ;;
    -n|--dry-run) DRY=1; shift ;;
    -f|--force)   FORCE=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown option: $1   (see -h)" ;;
  esac
done
[[ "$IDLE_DAYS" =~ ^[0-9]+$ ]] || die "--idle-days must be a whole number of days"
[[ "$TTL_DAYS"  =~ ^[0-9]+$ ]] || die "--ttl-days must be a whole number of days"
# No selector: report every category, touch nothing. Reporting is always safe.
if [[ "$REPORT_ONLY" -eq 1 && "$SCCACHE" -eq 0 ]]; then
  DO_ORPHANS=1; DO_ARTIFACTS=1; DO_DISPATCH=1; DRY=1
fi

WT_ROOT="${SUPERSET_HOME:-$HOME/.superset}/worktrees"
FREED_KB=0

# ── helpers ───────────────────────────────────────────────────────────────────────

human() {  # KiB -> human
  awk -v k="${1:-0}" 'BEGIN{
    if (k >= 1048576) printf "%.1f GiB", k/1048576;
    else if (k >= 1024) printf "%.0f MiB", k/1024;
    else printf "%d KiB", k;
  }'
}

size_kb() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }

# The set of worktree paths Superset still knows about. Authoritative — see SOURCE OF TRUTH.
# Emits one absolute path per line. Fails loud: an empty/failed listing must NOT be read as
# "nothing is alive", which would make every worktree look like an orphan.
live_paths() {
  local out
  out="$(superset ws list --json 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "$out" | jq -e -r '.[].worktreePath | select(. != null and . != "")' 2>/dev/null
}

# Superset's workspace id for a path (empty when it is not a live workspace).
live_id_for() {
  superset ws list --json 2>/dev/null \
    | jq -r --arg p "$1" '.[] | select(.worktreePath == $p) | .id' 2>/dev/null | head -1
}

# ── I2: liveness. Three independent checks; ANY hit means "in use, do not touch". ────────
# Returns 0 (busy) / 1 (idle) and echoes the reason when busy.

busy_recent_mtime() {  # $1 dir, $2 days — cheap: -quit stops at the first recent file
  local hit
  hit="$(find "$1" -newermt "-${2} days" -print -quit 2>/dev/null)"
  [[ -n "$hit" ]]
}

busy_cargo_lock() {  # a cargo build holds target/<profile>/.cargo-lock open
  local lock
  while IFS= read -r lock; do
    [[ -n "$lock" ]] || continue
    if lsof -t -- "$lock" >/dev/null 2>&1; then return 0; fi
  done < <(find "$1" -maxdepth 4 -name .cargo-lock -type f 2>/dev/null)
  return 1
}

busy_process_cwd() {  # any running process whose cwd sits inside the tree
  # lsof reports the PHYSICAL path, so compare physical to physical. Skipping this made the
  # check silently useless under a symlinked ancestor (/var -> /private/var on macOS) — a
  # safety check that never fires is worse than none, because it is trusted.
  local p; p="$(cd "$1" 2>/dev/null && pwd -P)" || p="$1"
  # One lsof pass over cwd descriptors only — no directory walk, so this stays fast.
  # awk/index rather than grep: a worktree path is data, not a regex (a `.` in a branch
  # name would otherwise match any character and produce a false "busy").
  lsof -a -d cwd -F n 2>/dev/null \
    | awk -v p="n$p" 'index($0, p) == 1 { c = substr($0, length(p) + 1, 1); if (c == "" || c == "/") { found = 1; exit } } END { exit !found }'
}

busy_reason() {  # echoes a reason and returns 0 when busy; returns 1 when idle
  local wt="$1" days="${2:-0}"
  if [[ "$days" -gt 0 ]] && busy_recent_mtime "$wt" "$days"; then
    echo "touched within ${days}d"; return 0
  fi
  if busy_cargo_lock "$wt";   then echo "cargo lock held"; return 0; fi
  if busy_process_cwd "$wt";  then echo "a process is cwd'd inside"; return 0; fi
  return 1
}

# ── git safety: the candidate itself AND every repo nested inside it ─────────────────
# A Superset workspace of this workspace contains ~21 nested product clones, each with its
# own state. Checking only the top level would happily delete a colleague's afternoon.
git_unsafe_reason() {
  local root="$1" gitpath repo dirty ahead
  while IFS= read -r gitpath; do
    [[ -n "$gitpath" ]] || continue
    repo="$(dirname "$gitpath")"
    dirty="$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${dirty:-0}" -gt 0 ]] && { echo "${repo#$root/} has $dirty uncommitted file(s)"; return 0; }
    ahead="$(git -C "$repo" log --oneline '@{u}..' 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${ahead:-0}" -gt 0 ]] && { echo "${repo#$root/} has $ahead unpushed commit(s)"; return 0; }
  done < <(find "$root" -maxdepth 2 -name .git 2>/dev/null)
  return 1
}

# ── removal ───────────────────────────────────────────────────────────────────────
# Three shapes live under worktrees/: a real git worktree (.git is a FILE pointing at the
# parent's .git/worktrees/<name>), a standalone clone (.git is a DIR), and a plain session
# dir (no .git at all). Only the first needs git told about it.
remove_worktree() {
  local wt="$1" kb parent branch
  kb="$(size_kb "$wt")"; kb="${kb:-0}"
  if [[ "$DRY" -eq 1 ]]; then
    info "would remove  $wt  ($(human "$kb"))"
    FREED_KB=$((FREED_KB + kb)); return 0
  fi
  if [[ -f "$wt/.git" ]]; then
    parent="$(sed -n 's/^gitdir: //p' "$wt/.git" | sed 's#/\.git/worktrees/.*##')"
    # Read the BRANCH from the worktree, not the .git/worktrees/<name> directory: git names
    # that directory after the last path segment, so branch `slack/req-x` lives in `req-x`
    # and deleting by the directory name would silently miss the branch.
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [[ -n "$parent" && -d "$parent/.git" ]]; then
      git -C "$parent" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
      git -C "$parent" worktree prune >/dev/null 2>&1
      # -d, never -D: an unmerged branch survives on purpose.
      [[ -n "$branch" && "$branch" != HEAD ]] && git -C "$parent" branch -d "$branch" >/dev/null 2>&1
    else
      rm -rf "$wt"
    fi
  else
    rm -rf "$wt"
  fi
  [[ -e "$wt" ]] && { warn "could not fully remove $wt"; return 1; }
  ok "removed  $wt  ($(human "$kb"))"
  FREED_KB=$((FREED_KB + kb))
}

# ── discovery ─────────────────────────────────────────────────────────────────────
# Classify each dir under worktrees/<project>/ against the live set:
#   exact match            -> ALIVE     (a real workspace; never an orphan)
#   prefix of a live path  -> CONTAINER (e.g. `slack/` holding slack/req-*; descend into it)
#   neither                -> ORPHAN    (stop; do not descend — its children are its content)
# Deriving "container" from the live set rather than hardcoding `slack/` is what makes this
# correct for any branch name with a / in it.
LIVE_LIST=""
classify() {
  local p="$1"
  grep -qxF "$p" <<<"$LIVE_LIST" && { echo alive; return; }
  grep -q "^${p}/" <<<"$LIVE_LIST" && { echo container; return; }
  echo orphan
}

ALIVE=() ORPHANS=()
discover() {
  local dir="$1" depth="$2" kind child
  [[ "$depth" -gt 3 ]] && return 0
  for child in "$dir"/*; do
    [[ -d "$child" ]] || continue
    kind="$(classify "$child")"
    case "$kind" in
      alive)     ALIVE+=("$child") ;;
      container) discover "$child" $((depth + 1)) ;;
      orphan)    ORPHANS+=("$child") ;;
    esac
  done
}

# ── sccache (opt-in, one-time host setup) ─────────────────────────────────────────
# The parallel-safe half of the disk story: a cache SERVER, not a locked shared directory,
# so N worktrees can compile at once and still reuse each other's objects.
enable_sccache() {
  step "sccache — parallel-safe rebuild cache"
  if ! command -v sccache >/dev/null 2>&1; then
    if [[ "$DRY" -eq 1 ]]; then info "would: brew install sccache"; else
      command -v brew >/dev/null 2>&1 || die "sccache is missing and Homebrew is not installed — install sccache yourself, then re-run"
      brew install sccache || die "brew install sccache failed"
    fi
  else
    ok "sccache already installed ($(sccache --version 2>/dev/null | head -1))"
  fi
  local cfg="${CARGO_HOME:-$HOME/.cargo}/config.toml"
  if grep -q 'rustc-wrapper' "$cfg" 2>/dev/null; then
    ok "rustc-wrapper already set in $cfg"
  elif [[ "$DRY" -eq 1 ]]; then
    info "would add [build] rustc-wrapper = \"sccache\" to $cfg"
  else
    mkdir -p "$(dirname "$cfg")"
    printf '\n[build]\nrustc-wrapper = "sccache"\n' >> "$cfg"
    ok "wired sccache as rustc-wrapper in $cfg"
  fi
  info "NOTE: sccache does not shrink target/ — it makes the rebuild after a reap cheap."
  info "      CARGO_TARGET_DIR is deliberately NOT set: it would serialize concurrent builds."
}

# ── main ──────────────────────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"

if [[ "$SCCACHE" -eq 1 ]]; then
  enable_sccache
  [[ "$DO_ORPHANS$DO_ARTIFACTS$DO_DISPATCH" == "000" ]] && exit 0
fi

command -v superset >/dev/null 2>&1 || die "the 'superset' CLI is not on PATH — this GC reads the live workspace list from it and refuses to guess"
[[ -d "$WT_ROOT" ]] || { ok "no $WT_ROOT — nothing to collect"; exit 0; }

LIVE_LIST="$(live_paths)" || die "\`superset ws list --json\` returned nothing usable — refusing to run, since an empty live set would classify every worktree as an orphan"

for proj in "$WT_ROOT"/*; do
  [[ -d "$proj" ]] || continue
  [[ -n "$PROJECT" && "$(basename "$proj")" != "$PROJECT" ]] && continue
  discover "$proj" 1
done

step "Superset worktrees under $WT_ROOT"
info "live: ${#ALIVE[@]}   ·   orphaned: ${#ORPHANS[@]}   ·   idle threshold: ${IDLE_DAYS}d   ·   dispatch TTL: ${TTL_DAYS}d"
[[ "$DRY" -eq 1 ]] && info "${c_dim}dry run — nothing will be changed${c_off}"

# ── 1. orphans ────────────────────────────────────────────────────────────────────
if [[ "$DO_ORPHANS" -eq 1 ]]; then
  step "Orphans — worktrees Superset no longer lists"
  [[ "${#ORPHANS[@]}" -eq 0 ]] && info "none"
  for wt in "${ORPHANS[@]:-}"; do
    [[ -n "$wt" ]] || continue
    # I3: liveness first and unconditionally. --force cannot reach past this.
    if reason="$(busy_reason "$wt" 0)"; then warn "skip  $(basename "$wt")  — in use ($reason)"; continue; fi
    if reason="$(git_unsafe_reason "$wt")"; then
      if [[ "$FORCE" -eq 1 ]]; then warn "forcing removal despite: $reason"
      else warn "skip  ${wt#$WT_ROOT/}  — $reason  (--force to override)"; continue; fi
    fi
    remove_worktree "$wt"
  done
fi

# ── 2. build artifacts in IDLE worktrees (live ones included) ─────────────────────
if [[ "$DO_ARTIFACTS" -eq 1 ]]; then
  step "Build artifacts in idle worktrees (target/ · node_modules)"
  busy=0 acted=0
  for wt in "${ALIVE[@]:-}"; do
    [[ -n "$wt" ]] || continue
    # Skipping a BUSY worktree is the invariant working, not a failure — say so out loud
    # rather than printing an empty section that reads like a broken run.
    if reason="$(busy_reason "$wt" "$IDLE_DAYS")"; then
      busy=$((busy + 1)); info "keep  $(basename "$wt")  — in use ($reason)"; continue
    fi
    found=0
    while IFS= read -r art; do
      [[ -n "$art" ]] || continue
      found=1; acted=1; kb="$(size_kb "$art")"; kb="${kb:-0}"
      if [[ "$DRY" -eq 1 ]]; then info "would clear  ${art#$WT_ROOT/}  ($(human "$kb"))"
      else rm -rf "$art" && ok "cleared  ${art#$WT_ROOT/}  ($(human "$kb"))"; fi
      FREED_KB=$((FREED_KB + kb))
    done < <(find "$wt" -maxdepth 3 \( -name target -o -name node_modules \) -type d -prune 2>/dev/null)
    [[ "$found" -eq 0 ]] && dim "none  $(basename "$wt")"
  done
  [[ "$acted" -eq 0 && "$busy" -eq 0 ]] && info "nothing to clear"
  [[ "$busy" -gt 0 ]] && info "${c_dim}$busy worktree(s) left alone so their builds keep running — raise --idle-days to be stricter${c_off}"
fi

# ── 3. dispatch worktrees past their TTL ──────────────────────────────────────────
if [[ "$DO_DISPATCH" -eq 1 ]]; then
  step "slack-dispatch worktrees older than ${TTL_DAYS}d"
  hits=0
  for wt in "${ALIVE[@]:-}" "${ORPHANS[@]:-}"; do
    [[ -n "$wt" ]] || continue
    case "$wt" in */slack/req-*) ;; *) continue ;; esac
    # Age by the worktree root's own mtime; liveness is still checked separately below.
    if [[ -n "$(find "$wt" -maxdepth 0 -newermt "-${TTL_DAYS} days" 2>/dev/null)" ]]; then
      dim "skip  $(basename "$wt")  — younger than ${TTL_DAYS}d"; continue
    fi
    hits=$((hits + 1))
    if reason="$(busy_reason "$wt" 0)"; then warn "skip  $(basename "$wt")  — in use ($reason)"; continue; fi
    if reason="$(git_unsafe_reason "$wt")"; then
      if [[ "$FORCE" -eq 1 ]]; then warn "forcing removal despite: $reason"
      else warn "skip  $(basename "$wt")  — $reason  (--force to override)"; continue; fi
    fi
    # Keep Superset's own list in sync when the worktree is still a live workspace.
    wsid="$(live_id_for "$wt")"
    if [[ -n "$wsid" ]]; then
      if [[ "$DRY" -eq 1 ]]; then info "would also: superset ws delete $wsid"
      else superset ws delete "$wsid" >/dev/null 2>&1 || warn "superset ws delete $wsid failed — removing the directory anyway"; fi
    fi
    remove_worktree "$wt"
  done
  [[ "$hits" -eq 0 ]] && info "none past TTL"
fi

# ── summary ───────────────────────────────────────────────────────────────────────
step "Summary"
if [[ "$DRY" -eq 1 ]]; then
  info "reclaimable: $(human "$FREED_KB")"
  [[ "$REPORT_ONLY" -eq 1 ]] && info "report only — pass --all (or a selector) to act, -n to preview a real run"
else
  ok "reclaimed: $(human "$FREED_KB")"
fi
