#!/usr/bin/env bash
#
# Workspace run — start a product's full local stack.
#
#   .superset/run.sh [product] [-s <site>] [-G] [-v]   (default product: ofb-platform)
#
# Options:
#   -s, --site <name>  player-site profile for the product (e.g. paotung | ohanabet | all;
#                      default: paotung). Sets OFB_PLAYER_SITE for the product file.
#   -G, --no-games   skip Phase 6 (fetch games).
#   -v, --verbose    show the full step-by-step log (quiet by default).
#   -h, --help       show this help.
#
# Sequence (defined per product in .superset/products/<product>.sh):
#   1. databases + migrations  (run_databases)
#   2. backends — docker       (run_backends)
#   3. frontends               (run_frontends)
#   4. aggregator setup        (run_aggregator_setup)   — optional
#   5. wait for backend ready  (wait_backends_ready)     — optional
#   6. fetch games             (fetch_games)             — optional
#
# Phases 4–6 are optional product hooks: run.sh runs each only if the product
# file defines it, so a product that omits them collapses back to the 1–3 flow.
# Phase 6 is additionally skipped on demand with -G / --no-games.
#
# Docker services are managed by compose; non-docker apps (e.g. next dev) run in
# the background with pidfiles in .superset/run/<product>/ and logs in
# .superset/logs/<product>/. Idempotent — safe to re-run.
#
set -euo pipefail

cd "$(dirname "$0")/.."
source .superset/lib.sh

usage() { sed -n '4,12p' "$0" | sed 's/^# \{0,1\}//'; }

# Quiet by default; -v/--verbose shows the full step log (exported for lib.sh's log()).
export VERBOSE="${VERBOSE:-0}"
PRODUCT=""
SKIP_FETCH_GAMES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--site)
      [[ $# -ge 2 ]] || { err "--site needs a value (e.g. paotung | ohanabet | all)"; exit 2; }
      export OFB_PLAYER_SITE="$2"; shift 2 ;;
    --site=*)      export OFB_PLAYER_SITE="${1#*=}"; shift ;;
    -G|--no-games) SKIP_FETCH_GAMES=1; shift ;;
    -v|--verbose)  export VERBOSE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    --)            shift; break ;;
    -*)            err "unknown option: $1"; usage >&2; exit 2 ;;
    *)
      if [[ -n "$PRODUCT" ]]; then err "unexpected extra argument: $1"; usage >&2; exit 2; fi
      PRODUCT="$1"; shift ;;
  esac
done
PRODUCT="${PRODUCT:-ofb-platform}"

runtime_dirs "$PRODUCT"
load_product "$PRODUCT"

if ! docker info >/dev/null 2>&1; then
  err "Docker is not running — start Docker Desktop first."
  exit 1
fi

log "Running product '$PRODUCT' (db: ${DB_REPOS[*]:-—} | backend: ${BACKEND_REPOS[*]:-—} | frontend: ${FRONTEND_REPOS[*]:-—})"

# Run an optional product hook only when the product file defines it.
run_phase() {  # <label> <hook-fn>
  log "── $1 ──"
  if declare -f "$2" >/dev/null 2>&1; then
    "$2"
  else
    warn "product '$PRODUCT' defines no '$2' — skipping this phase."
  fi
}

log "── Phase 1/6: databases + migrations ──"
run_databases

log "── Phase 2/6: backends ──"
run_backends

log "── Phase 3/6: frontends ──"
run_frontends

run_phase "Phase 4/6: aggregator setup" run_aggregator_setup

run_phase "Phase 5/6: wait for backend readiness" wait_backends_ready

if [[ "$SKIP_FETCH_GAMES" == 1 ]]; then
  log "── Phase 6/6: fetch games ── skipped (-G)"
else
  run_phase "Phase 6/6: fetch games" fetch_games
fi

# ── conclusion (always shown, even when quiet) ──────────────────────────────────
conclude "Product '$PRODUCT' is up. Teardown with: .superset/teardown.sh $PRODUCT"
