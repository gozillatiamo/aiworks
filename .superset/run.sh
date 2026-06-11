#!/usr/bin/env bash
#
# Workspace run — start a product's full local stack.
#
#   .superset/run.sh [product]      (default: ofb-platform)
#
# Sequence (defined per product in .superset/products/<product>.sh):
#   1. databases + migrations  (run_databases)
#   2. backends — docker       (run_backends)
#   3. frontends               (run_frontends)
#
# Docker services are managed by compose; non-docker apps (e.g. next dev) run in
# the background with pidfiles in .superset/run/<product>/ and logs in
# .superset/logs/<product>/. Idempotent — safe to re-run.
#
set -euo pipefail

cd "$(dirname "$0")/.."
source .superset/lib.sh

PRODUCT="${1:-ofb-platform}"
runtime_dirs "$PRODUCT"
load_product "$PRODUCT"

if ! docker info >/dev/null 2>&1; then
  err "Docker is not running — start Docker Desktop first."
  exit 1
fi

log "Running product '$PRODUCT' (db: ${DB_REPOS[*]:-—} | backend: ${BACKEND_REPOS[*]:-—} | frontend: ${FRONTEND_REPOS[*]:-—})"

log "── Phase 1/3: databases + migrations ──"
run_databases

log "── Phase 2/3: backends ──"
run_backends

log "── Phase 3/3: frontends ──"
run_frontends

log "Product '$PRODUCT' is up. Teardown with: .superset/teardown.sh $PRODUCT"
