#!/usr/bin/env bash
#
# aiworks-superset.sh  (called by `aiworks add`/`sync`) — keep the workspace lifecycle
# hooks (.superset/{setup,run,teardown}.sh) present and registered so EVERY onboarded repo
# is covered by setup, run AND teardown.
#
# The three hooks are workspace-level and DYNAMIC: each loops over every cloned product repo
# (a top-level dir with a .git entry) rather than carrying a per-repo list — so a repo added by
# `aiworks add`/`sync` is picked up automatically, with no per-repo edit. This guard only makes
# sure the trio EXISTS and that .superset/config.json declares each one:
#   * setup.sh / teardown.sh — committed template files; WARN (don't regenerate) if missing.
#   * run.sh                 — the run hook (aiworks run); this script is its source of truth, so
#                              it is CREATED from the embedded template when missing — workspaces
#                              that predate the run hook self-heal on the next add/sync.
#   * config.json            — (re)written so the {setup,run,teardown} keys point at the hooks
#                              that exist, in canonical order, preserving any other keys.
#
# Idempotent. add/sync call it automatically; run it yourself after hand-editing .superset/.
#
# Usage: aiworks-superset.sh [-n|--dry-run] [-f|--force] [-q|--quiet] [-h|--help]
#   -n, --dry-run   show what WOULD change; write nothing.
#   -f, --force     rewrite .superset/run.sh from the template even if it already exists.
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
warn() { printf '    %s! %s%s\n' "$c_warn" "$*" "$c_off"; }
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
SUP="$ROOT/.superset"

# Write the canonical run hook to $1. The body is the source of truth for the run lifecycle.
# A QUOTED heredoc delimiter keeps it verbatim (no expansion when this generator runs).
write_run_hook() {
  cat > "$1" <<'RUNEOF'
#!/usr/bin/env bash
#
# Workspace run — mani multi-repo workspace (provider-agnostic template).
#
# The "run" lifecycle hook (aiworks run -> .superset/run.sh). Like setup.sh and teardown.sh it
# operates on EVERY cloned product repo: for each it delegates to that repo's scripts/dev.sh run
# — the single source of truth for how to build, launch and drive that app as a non-interactive
# agent path that proves it works and exits with a verdict (scaffolded by `aiworks add` step 10).
# Pass repo name(s) to run only those; default = every cloned repo.
#
# Created/repaired by `aiworks add`/`sync` (scripts/aiworks-superset.sh) so a freshly onboarded
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

# (Re)write config.json so the {setup,run,teardown} keys point at the hooks that exist, in
# canonical order, preserving any other keys. Prefers a node merge (keeps unknown keys); falls
# back to a plain canonical write (lifecycle keys only) when node is unavailable.
ensure_config() {
  local cfg="$1" hooks="$2" out rc h f2
  if command -v node >/dev/null 2>&1; then
    out="$(CFG="$cfg" HOOKS="$hooks" node <<'NODE'
const fs = require('fs');
const f = process.env.CFG, hooks = JSON.parse(process.env.HOOKS);
let j = {};
try { const r = fs.readFileSync(f, 'utf8'); if (r.trim() !== '') j = JSON.parse(r); }
catch (e) { if (e.code !== 'ENOENT') { console.log('PARSE_ERROR'); process.exit(0); } }
const order = ['setup', 'run', 'teardown'];
const out = {};
for (const k of order) if (k in hooks) out[k] = hooks[k];                 // present hooks, canonical order
for (const k of Object.keys(j)) if (!(k in out) && !order.includes(k)) out[k] = j[k]; // keep unknown keys
const changed = JSON.stringify(j) !== JSON.stringify(out);
if (changed) fs.writeFileSync(f, JSON.stringify(out, null, 2) + '\n');
console.log(changed ? 'CHANGED' : 'OK');
NODE
)"; rc=$?
    case "$out" in
      CHANGED)     ok "config.json declares setup/run/teardown" ;;
      OK)          ok "config.json already declares the present hooks" ;;
      PARSE_ERROR) warn "config.json is not valid JSON — left untouched; add the \"run\" hook by hand" ;;
      *)           warn "could not update config.json (node rc=$rc)" ;;
    esac
  else
    { printf '{\n'; f2=1
      for h in setup run teardown; do
        [[ -f "$SUP/$h.sh" ]] || continue
        [[ "$f2" -eq 1 ]] || printf ',\n'
        printf '  "%s": ["./.superset/%s.sh"]' "$h" "$h"; f2=0
      done
      printf '\n}\n'; } > "$cfg" && ok "config.json written (setup/run/teardown; node not found)"
  fi
}

step "Ensure .superset lifecycle hooks (setup/run/teardown) cover every repo"

if [[ ! -d "$SUP" ]]; then
  if [[ "$DRY" -eq 1 ]]; then dim "would create .superset/"; else mkdir -p "$SUP"; fi
fi

# ── run.sh — the hook this script owns; create it from the template when missing ──
RUN="$SUP/run.sh"
if [[ -f "$RUN" && "$FORCE" -ne 1 ]]; then
  ok "run.sh present (every cloned repo → scripts/dev.sh run)"
elif [[ "$DRY" -eq 1 ]]; then
  dim "would $([[ -f "$RUN" ]] && echo rewrite || echo create) .superset/run.sh (the workspace run hook)"
else
  write_run_hook "$RUN" && ok "$([[ "$FORCE" -eq 1 ]] && echo rewrote || echo created) .superset/run.sh (delegates to each repo's scripts/dev.sh run)"
fi

# ── setup.sh / teardown.sh — committed template files; warn (don't regenerate) if absent ──
for h in setup teardown; do
  if [[ -f "$SUP/$h.sh" ]]; then ok "$h.sh present (loops over every cloned repo)"
  else warn "$h.sh MISSING from .superset/ — restore it from the workspace template (e.g. git checkout .superset/$h.sh)"; fi
done

# ── config.json — declare the {setup,run,teardown} keys for the hooks that exist ──
CFG="$SUP/config.json"
hooks_json="{"; first=1
for h in setup run teardown; do
  [[ -f "$SUP/$h.sh" ]] || continue
  [[ "$first" -eq 1 ]] || hooks_json+=","
  hooks_json+="\"$h\":[\"./.superset/$h.sh\"]"; first=0
done
hooks_json+="}"

if [[ "$DRY" -eq 1 ]]; then
  dim "would ensure .superset/config.json declares: $hooks_json"
else
  ensure_config "$CFG" "$hooks_json"
fi
