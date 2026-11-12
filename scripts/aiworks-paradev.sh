#!/usr/bin/env bash
#
# aiworks-paradev.sh  (called by `aiworks add`/`sync`) — keep the workspace lifecycle
# hooks (.paradev/{setup,run,teardown}.sh) present and registered so EVERY onboarded repo
# is covered by setup, run AND teardown.
#
# The three hooks are workspace-level and DYNAMIC: each loops over every cloned product repo
# (a top-level dir with a .git entry) rather than carrying a per-repo list — so a repo added by
# `aiworks add`/`sync` is picked up automatically, with no per-repo edit. This guard only makes
# sure the trio EXISTS and that .paradev/config.toml references each one:
#   * setup.sh / teardown.sh — committed template files; WARN (don't regenerate) if missing.
#   * run.sh                 — the run hook (aiworks run); this script is its source of truth, so
#                              it is CREATED from the embedded template when missing — workspaces
#                              that predate the run hook self-heal on the next add/sync.
#   * config.toml            — written when missing (setup / terminals.dev / archive tables); an
#                              existing file is never rewritten, only warned about. A legacy .superset/
#                              directory is migrated into .paradev/ without overwriting.
#
# Idempotent. add/sync call it automatically; run it yourself after hand-editing .paradev/.
#
# Usage: aiworks-paradev.sh [-n|--dry-run] [-f|--force] [-q|--quiet] [-h|--help]
#   -n, --dry-run   show what WOULD change; write nothing.
#   -f, --force     rewrite .paradev/run.sh from the template even if it already exists.
#   -q, --quiet     only print warnings/errors (used by `aiworks add`).
#   -h, --help      show this help.
#
set -uo pipefail

# ── logging ──────────────────────────────────────────────────────────────────────
c_step=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_step=; c_ok=; c_warn=; c_err=; c_dim=; c_off=; }
QUIET=0
step() { [[ "$QUIET" -eq 1 ]] || printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { [[ "$QUIET" -eq 1 ]] || printf '    %s✓ %s%s\n' "$c_ok" "$*" "$c_off"; }
dim()  { [[ "$QUIET" -eq 1 ]] || printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
warn() { printf '    %s! %s%s\n' "$c_warn" "$*" "$c_off" >&2; }
die()  { printf '%serror: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

# ── args ──────────────────────────────────────────────────────────────────────────
DRY=0 FORCE=0
usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY=1; shift ;;
    -f|--force)   FORCE=1; shift ;;
    -q|--quiet)   QUIET=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown option: $1   (see -h)" ;;
  esac
done

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
[[ -f "$ROOT/mani.yaml" ]] || die "no mani.yaml in $ROOT — run this from a workspace (next to mani.yaml)"
PDIR="$ROOT/.paradev"

# Write the canonical run hook to $1. The body is the source of truth for the run lifecycle.
# A QUOTED heredoc delimiter keeps it verbatim (no expansion when this generator runs).
write_run_hook() {
  cat > "$1" <<'RUNEOF'
#!/usr/bin/env bash
#
# Workspace run — mani multi-repo workspace (provider-agnostic template).
#
# The "run" lifecycle hook (aiworks run -> .paradev/run.sh). Like setup.sh and teardown.sh it
# operates on EVERY cloned product repo: for each it delegates to that repo's scripts/dev.sh run
# — the single source of truth for how to build, launch and drive that app as a non-interactive
# agent path that proves it works and exits with a verdict (scaffolded by `aiworks add` step 10).
# Pass repo name(s) to run only those; default = every cloned repo.
#
# Created/repaired by `aiworks add`/`sync` (scripts/aiworks-paradev.sh) so a freshly onboarded
# repo is covered by setup/run/teardown alike. Re-creatable: delete it and re-run add/sync.
#
#   aiworks run                   # run every cloned repo (scripts/dev.sh run each)
#   aiworks run <repo> [<repo>…]  # run only the named repo(s)
#
set -uo pipefail

cd "$(dirname "$0")/.."

# Optional repo-name filter from positional args. No args -> run every cloned repo.
filter=" $* "
want() { [[ "$filter" == "  " ]] && return 0; case "$filter" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

ran=0 skipped=0 failed=0 notes=()
for repo in */; do
  repo="${repo%/}"
  # Only the cloned product repos: a top-level dir with a .git entry.
  [[ -e "$repo/.git" ]] || continue
  want "$repo" || continue
  if [[ ! -f "$repo/scripts/dev.sh" ]]; then
    echo "==> Skip $repo — no scripts/dev.sh (run 'aiworks sync $repo' to scaffold it)"
    skipped=$((skipped + 1)); notes+=("$repo: no scripts/dev.sh"); continue
  fi
  echo "==> Run $repo  (scripts/dev.sh run)…"
  if ( cd "$repo" && bash scripts/dev.sh run ); then
    ran=$((ran + 1))
  else
    rc=$?
    echo "    ! $repo failed — scripts/dev.sh run exited $rc (diagnose: cd $repo && bash scripts/dev.sh why run)" >&2
    failed=$((failed + 1)); notes+=("$repo: dev.sh run exited $rc")
  fi
done

# A named repo the filter never matched = a typo or an un-cloned repo — surface it.
if [[ "$filter" != "  " ]]; then
  for w in $*; do
    [[ -e "$w/.git" ]] || { echo "==> No cloned repo named '$w' to run" >&2; notes+=("$w: not a cloned repo"); }
  done
fi

echo "==> Done (ran $ran, skipped $skipped, failed $failed)."
[[ "${#notes[@]}" -gt 0 ]] && printf '    • %s\n' "${notes[@]}"
[[ "$failed" -eq 0 ]]
RUNEOF
  chmod +x "$1" 2>/dev/null || true
}

# config.toml table for each lifecycle hook, in canonical order. Paradev reads .paradev/config.toml
# first; the schema is strict (unknown keys are errors), so only these three tables are written.
toml_table() {
  case "$1" in
    setup)    printf '[setup]\nrun = ["./.paradev/setup.sh"]\n' ;;
    run)      printf '[terminals.dev]\nrun = "./.paradev/run.sh"\ndefault = true\n' ;;
    teardown) printf '[archive]\nrun = ["./.paradev/teardown.sh"]\n' ;;
  esac
}

# Write a canonical config.toml covering the hooks whose script exists. No TOML parser: an
# existing file is never rewritten, only checked for a reference to each present hook.
ensure_config() {
  local cfg="$1" h sep="" body=""
  if [[ ! -f "$cfg" ]]; then
    for h in setup run teardown; do
      [[ -f "$PDIR/$h.sh" ]] || continue
      body="$body$sep$(toml_table "$h")"; sep=$'\n'
    done
    if [[ "$DRY" -eq 1 ]]; then dim "would write .paradev/config.toml (setup/run/teardown)"
    elif [[ -z "$body" ]]; then warn "no lifecycle hook script exists — config.toml not written"
    else printf '%s\n' "$body" > "$cfg" && ok "config.toml written (setup/run/teardown)"; fi
  else
    for h in setup run teardown; do
      [[ -f "$PDIR/$h.sh" ]] || continue
      grep -qF "./.paradev/$h.sh" "$cfg" || warn "config.toml does not reference ./.paradev/$h.sh — add it by hand"
    done
    ok "config.toml present — left untouched"
  fi
  [[ -f "$PDIR/config.json" && -f "$cfg" ]] \
    && warn ".paradev/config.json is ignored by Paradev while config.toml exists — delete it"
  return 0
}

# A workspace synced before the Superset-to-Paradev rename keeps untracked state (product files,
# .env, pidfiles) under .superset/. Move it to the same path under .paradev/, never overwriting.
migrate_legacy() {
  local old="$ROOT/.superset" f rel dst n=0
  [[ -d "$old" && ! -L "$old" ]] || return 0
  while IFS= read -r -d '' f; do
    rel="${f#"$old"/}"; dst="$PDIR/$rel"
    if [[ -e "$dst" || -L "$dst" ]]; then
      warn ".superset/$rel not moved — .paradev/$rel already exists (kept both; resolve by hand)"
    elif [[ "$DRY" -eq 1 ]]; then dim "would move .superset/$rel to .paradev/$rel"
    else mkdir -p "$(dirname "$dst")" && mv "$f" "$dst" && n=$((n + 1)); fi
  done < <(find "$old" \( -type f -o -type l \) -print0)
  if [[ "$DRY" -ne 1 ]]; then
    find "$old" -depth -type d -empty -delete 2>/dev/null
    [[ "$n" -eq 0 ]] || ok "migrated $n file(s) from .superset/ to .paradev/"
    [[ ! -d "$old" ]] || warn ".superset/ still holds files — both directories exist, resolve by hand"
  fi
  return 0
}

step "Ensure .paradev lifecycle hooks (setup/run/teardown) cover every repo"

if [[ ! -d "$PDIR" ]]; then
  if [[ "$DRY" -eq 1 ]]; then dim "would create .paradev/"; else mkdir -p "$PDIR"; fi
fi

migrate_legacy

# ── run.sh — the hook this script owns; create it from the template when missing ──
RUN="$PDIR/run.sh"
if [[ -f "$RUN" && "$FORCE" -ne 1 ]]; then
  ok "run.sh present (every cloned repo → scripts/dev.sh run)"
elif [[ "$DRY" -eq 1 ]]; then
  dim "would $([[ -f "$RUN" ]] && echo rewrite || echo create) .paradev/run.sh (the workspace run hook)"
else
  write_run_hook "$RUN" && ok "$([[ "$FORCE" -eq 1 ]] && echo rewrote || echo created) .paradev/run.sh (delegates to each repo's scripts/dev.sh run)"
fi

# ── setup.sh / teardown.sh — committed template files; warn (don't regenerate) if absent ──
for h in setup teardown; do
  if [[ -f "$PDIR/$h.sh" ]]; then ok "$h.sh present (loops over every cloned repo)"
  else warn "$h.sh MISSING from .paradev/ — restore it from the workspace template (e.g. git checkout .paradev/$h.sh)"; fi
done

# ── config.toml — declare the hooks that exist ──
ensure_config "$PDIR/config.toml"
