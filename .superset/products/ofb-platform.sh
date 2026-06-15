#!/usr/bin/env bash
#
# Product definition: ofb-platform (the default product).
#
# A product file declares the repos per tier and the six lifecycle hooks the
# orchestrators call (helpers come from .superset/lib.sh):
#
#   run_databases / run_backends / run_frontends      — called by run.sh, in order
#   down_frontends / down_backends / down_databases   — called by teardown.sh, in order
#
# To add a product variant: copy this file to .superset/products/<id>.sh and
# adjust — then `.superset/run.sh <id>` / `.superset/teardown.sh <id>`.
#

DB_REPOS=(agent-db)
BACKEND_REPOS=(agent-webservice)
FRONTEND_REPOS=(paotung-template backoffice)

# ── 1. databases + migrations ─────────────────────────────────────────────────
run_databases() {
  # agent-db: postgres (master-agent :5432, shard :5433, master-lotto :5435)
  # + valkey cache (:6379), then the liquibase migration runners.
  log "agent-db: starting databases + cache (docker compose --profile all up -d)…"
  (cd agent-db && docker compose --profile all up -d)

  wait_for_postgres agent-db master-agent-db
  wait_for_postgres agent-db agent-shard-1
  wait_for_postgres agent-db master-lotto-db

  run_migration agent-db master.yml master-db
  run_migration agent-db shard.yml  shard-db
  run_migration agent-db lotto.yml  lotto-db
}

# ── 2. backends (docker) ──────────────────────────────────────────────────────
run_backends() {
  # agent-webservice: rust API on :3000/:4000, hot-reload via the compose
  # override (cargo watch). Needs .env.local + ~/.ssh key for private deps.
  if [[ ! -f agent-webservice/.env.local ]]; then
    warn "agent-webservice/.env.local is missing — the backend will not start correctly."
  fi
  log "agent-webservice: starting backend (docker compose up -d --build)…"
  (cd agent-webservice && docker compose up -d --build)
}

# ── 3. frontends ──────────────────────────────────────────────────────────────
run_frontends() {
  # paotung-template: nginx (docker, :80) + next dev on :3004 (pnpm).
  log "paotung-template: starting nginx (docker compose up -d nginx)…"
  (cd paotung-template && docker compose up -d nginx)
  start_node_app paotung-template dev 3004

  # backoffice: next dev on :3001 (npm), no docker.
  start_node_app backoffice dev 3001
}

# ── teardown (reverse order) ──────────────────────────────────────────────────
down_frontends() {
  stop_node_app backoffice 3001
  stop_node_app paotung-template 3004
  log "paotung-template: docker compose down…"
  (cd paotung-template && docker compose down --remove-orphans) || true
}

down_backends() {
  log "agent-webservice: docker compose down…"
  (cd agent-webservice && docker compose down --remove-orphans) || true
}

down_databases() {
  log "agent-db: docker compose --profile all down…"
  (cd agent-db && docker compose --profile all down --remove-orphans) || true
  # one-shot migration runners, in case any exited container lingers
  for f in master.yml shard.yml lotto.yml; do
    (cd agent-db && docker compose -f "$f" down) >/dev/null 2>&1 || true
  done
}
