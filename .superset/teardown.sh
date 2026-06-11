#!/usr/bin/env bash
#
# Workspace teardown — stop a product's full local stack.
#
#   .superset/teardown.sh [product] [--purge-repos]      (default: ofb-platform)
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
#
set -euo pipefail

cd "$(dirname "$0")/.."
source .superset/lib.sh

PRODUCT="ofb-platform"
PURGE_REPOS=false
for arg in "$@"; do
  case "$arg" in
    --purge-repos) PURGE_REPOS=true ;;
    *) PRODUCT="$arg" ;;
  esac
done

runtime_dirs "$PRODUCT"
load_product "$PRODUCT"

log "Tearing down product '$PRODUCT'…"

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
log "Product '$PRODUCT' is down."

# Optional: remove the cloned product repos so Superset can delete the
# worktree cleanly (they are untracked, gitignored clones).
if [[ "$PURGE_REPOS" == true ]]; then
  removed=0
  for repo in */; do
    repo="${repo%/}"
    [[ -e "$repo/.git" ]] || continue
    rm -rf "$repo" && log "Removed cloned repo: $repo" && removed=$((removed + 1))
  done
  log "Purged $removed cloned repo(s)."
fi
