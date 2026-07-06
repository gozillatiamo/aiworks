#!/usr/bin/env bash
#
# Workspace teardown — stop a product's full local stack.
#
#   .superset/teardown.sh [product] [--purge-repos] [-v|--verbose]   (default: the ONE product file)
#
# Output is QUIET by default; pass -v/--verbose for the full step log.
#
# Downs every service in reverse run order (defined per product in
# .superset/products/<product>.sh):
#   1. frontends   (down_frontends)
#   2. backends    (down_backends)
#   3. databases   (down_databases)
#
# --purge-repos additionally REMOVES the cloned product repos (the original
# Superset worktree-removal behaviour). Destructive: push uncommitted work in
# the clones first. Without the flag, repos (and db-data volumes) are kept.
# Undoes setup: stops the shared MCP service containers, then removes the product repos
# that `mani sync` cloned into the workspace root (and the adapter symlinks inside them).
# The clones are untracked (gitignored from the parent repo), so clearing them lets
# Superset remove the worktree cleanly. Deleting a workspace discards its state by design
# — push uncommitted work in these clones first.
#
set -euo pipefail

cd "$(dirname "$0")/.."
source .superset/lib.sh

export VERBOSE="${VERBOSE:-0}"   # quiet by default; -v/--verbose shows the full step log
PRODUCT=""
PURGE_REPOS=false
for arg in "$@"; do
  case "$arg" in
    --purge-repos) PURGE_REPOS=true ;;
    -v|--verbose)  export VERBOSE=1 ;;
    *) PRODUCT="$arg" ;;
  esac
done
PRODUCT="${PRODUCT:-$(default_product)}" || exit 2

log "Stopping shared MCP services…"
if [[ "$VERBOSE" == 1 ]]; then ./.superset/mcp-services.sh down || true; ./.superset/mcp-services.sh reap || true
else ./.superset/mcp-services.sh down >/dev/null 2>&1 || true; ./.superset/mcp-services.sh reap >/dev/null 2>&1 || true; fi

runtime_dirs "$PRODUCT"
load_product "$PRODUCT"

log "Tearing down product '$PRODUCT'…"

# Host-level helpers first (ngrok etc.) — these don't depend on docker, so stop
# them whether or not docker is up. Optional per product (guarded).
if declare -f down_thirdparty_setup >/dev/null 2>&1; then
  log "── Stopping third-party helpers (ngrok) ──"
  down_thirdparty_setup
fi

if docker info >/dev/null 2>&1; then
  log "── Phase 1/3: frontends ──"
  down_frontends

  log "── Phase 2/3: backends ──"
  down_backends

  log "── Phase 3/3: databases ──"
  down_databases
else
  warn "Docker is not running — skipping container teardown (only stopping background apps)."
  for repo in "${FRONTEND_REPOS[@]:-}"; do
    [[ -n "$repo" ]] && stop_node_app "$repo"
  done
fi

rm -rf ".superset/run/$PRODUCT"

# Optional: remove the cloned product repos so Superset can delete the
# worktree cleanly (they are untracked, gitignored clones).
purged_note=""
if [[ "$PURGE_REPOS" == true ]]; then
  removed=0
  for repo in */; do
    repo="${repo%/}"
    [[ -e "$repo/.git" ]] || continue
    rm -rf "$repo" && log "Removed cloned repo: $repo" && removed=$((removed + 1))
  done
  log "Purged $removed cloned repo(s)."
  purged_note=" — purged $removed cloned repo(s)"
fi

# ── conclusion (always shown, even when quiet — the last line) ──────────────────────
conclude "Product '$PRODUCT' is down.${purged_note}"
