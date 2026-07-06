#!/usr/bin/env bash
#
# Product definition: example (a TEMPLATE — copy, don't run).
#
# A product file declares the repos per tier and the lifecycle hooks the
# orchestrators call (helpers come from .superset/lib.sh):
#
#   run_databases / run_backends / run_frontends      — called by run.sh, in order
#   run_thirdparty_setup / wait_backends_ready / seed_data
#                                                     — called by run.sh, optional
#                                                       (skipped if a product omits them)
#   down_thirdparty_setup                             — called by teardown.sh, optional
#   down_frontends / down_backends / down_databases   — called by teardown.sh, in order
#
# To define YOUR product: copy this file to .superset/products/<product-id>.sh
# (matching a products[].id in workspace.config.yaml), replace the placeholder
# repo names with your clone dirs, and delete the hooks you don't need — then
# `.superset/run.sh <product-id>` / `.superset/teardown.sh <product-id>`.
# Real product files are gitignored (like workspace.config.yaml): they describe
# YOUR org's stack, not the template.
#

DB_REPOS=(your-db)
BACKEND_REPOS=(your-api)

# ── frontend profile ──────────────────────────────────────────────────────────
# Each dev server can cost ~2 GB RAM, so default to ONE frontend profile and let
# `run.sh -s/--site <name>` (which exports PRODUCT_SITE) pick another. Override
# the list entirely with PRODUCT_FRONTENDS="repo-a repo-b".
if [[ -n "${PRODUCT_FRONTENDS:-}" ]]; then
  read -r -a FRONTEND_REPOS <<< "$PRODUCT_FRONTENDS"
else
  case "${PRODUCT_SITE:-default}" in
    default) FRONTEND_REPOS=(your-app) ;;
    all)     FRONTEND_REPOS=(your-app your-admin) ;;
    *) echo "WARN: unknown PRODUCT_SITE='${PRODUCT_SITE:-}', using 'default' (your-app)." >&2
       FRONTEND_REPOS=(your-app) ;;
  esac
fi

# ── 1. databases + migrations ─────────────────────────────────────────────────
run_databases() {
  log "your-db: starting databases (docker compose up -d)…"
  (cd your-db && docker compose up -d)

  wait_for_postgres your-db your-db-main

  run_migration your-db migrations.yml your-db-migrate
}

# ── 2. backends (docker) ──────────────────────────────────────────────────────
run_backends() {
  if [[ ! -f your-api/.env.local ]]; then
    warn "your-api/.env.local is missing — the backend will not start correctly."
  fi
  log "your-api: starting backend (docker compose up -d --build)…"
  (cd your-api && docker compose up -d --build)
}

# ── 3. frontends ──────────────────────────────────────────────────────────────
run_frontends() {
  # Start only the frontends the profile selected (FRONTEND_REPOS, set above).
  local repo
  for repo in "${FRONTEND_REPOS[@]}"; do
    case "$repo" in
      your-app)
        # your-app: next dev on :3001.
        start_node_app your-app dev 3001 ;;
      your-admin)
        # your-admin: next dev on :3002.
        start_node_app your-admin dev 3002 ;;
      *)
        warn "run_frontends: unknown frontend '$repo' — skipping." ;;
    esac
  done
}

# ── 4. third-party setup (optional hook) ───────────────────────────
# run_thirdparty_setup() {
#   # Wire any third-party callback to THIS machine (e.g. ngrok -> your backend
#   # port) so the integration is testable locally. Keep it idempotent and never
#   # fatal to the run — warn and carry on.
#   (cd your-api && bash scripts/thirdparty_setup.sh) \
#     || warn "your-api: third-party setup did not complete cleanly — continuing."
# }

# ── 5. wait for backend readiness (optional hook) ─────────────────────────────
wait_backends_ready() {
  # Poll generously — a first docker build can take minutes. Non-fatal: if it
  # never answers, let the next phase surface the real error.
  run_glance "your-api: waiting for the backend on :3000" \
       wait_for_http "http://localhost:3000/" 120 5 "your-api (:3000)" \
    || warn "your-api did not become ready — later phases may fail."
}

# ── 6. seed/prime data (optional hook) ────────────────────────────────────────
# seed_data() {
#   # Prime any catalogue/seed data via a server-to-server endpoint.
#   run_glance "your-api: priming seed data" \
#     curl -fS --max-time 300 -o "$LOG_DIR/seed.json" "http://localhost:3000/seed"
# }

# ── teardown (reverse order) ──────────────────────────────────────────────────
# down_thirdparty_setup() {
#   # Stop only helpers WE started (tracked via pidfiles).
#   stop_pidfile /tmp/ngrok-thirdparty.pid "ngrok (third-party tunnel)"
# }

down_frontends() {
  stop_node_app your-app 3001
  stop_node_app your-admin 3002
}

down_backends() {
  log "your-api: docker compose down…"
  (cd your-api && docker compose down --remove-orphans) || true
}

down_databases() {
  log "your-db: docker compose down…"
  (cd your-db && docker compose down --remove-orphans) || true
}
