#!/usr/bin/env bash
#
# Product definition: ofb-platform (the default product).
#
# A product file declares the repos per tier and the lifecycle hooks the
# orchestrators call (helpers come from .superset/lib.sh):
#
#   run_databases / run_backends / run_frontends      — called by run.sh, in order
#   run_aggregator_setup / wait_backends_ready / fetch_games
#                                                     — called by run.sh, optional
#                                                       (skipped if a product omits them)
#   down_aggregator_setup                             — called by teardown.sh, optional
#   down_frontends / down_backends / down_databases   — called by teardown.sh, in order
#
# To add a product variant: copy this file to .superset/products/<id>.sh and
# adjust — then `.superset/run.sh <id>` / `.superset/teardown.sh <id>`.
#

DB_REPOS=(agent-db)
BACKEND_REPOS=(agent-webservice)
FRONTEND_REPOS=(paotung-template front-end backoffice)

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

  # front-end: OHANABET theme — next dev on :3002 (pnpm), no docker.
  start_node_app front-end dev 3002

  # backoffice: next dev on :3001 (npm), no docker.
  start_node_app backoffice dev 3001
}

# ── 4. aggregator setup (AMB) ─────────────────────────────────────────────────
run_aggregator_setup() {
  # Wire the AMB aggregator product callback to THIS machine (ngrok -> :3000) so
  # a game is playable locally. The script is idempotent (skips when the IP is
  # already whitelisted and the callback already points here), starts its own
  # ngrok if none is on :3000, and needs jq + agent-webservice/.env.amb. Never
  # fatal to the run — warn and carry on. See agent-webservice/docs/amb_setup_flow.md.
  local script=agent-webservice/scripts/amb_setup.sh
  if [[ ! -f "$script" ]]; then
    warn "agent-webservice: $script not found — skipping AMB setup."
    return 0
  fi
  if [[ ! -f agent-webservice/.env.amb ]]; then
    warn "agent-webservice/.env.amb is missing — skipping AMB setup (see docs/amb_setup_flow.md)."
    return 0
  fi
  log "agent-webservice: AMB aggregator setup (scripts/amb_setup.sh)…"
  (cd agent-webservice && bash scripts/amb_setup.sh) \
    || warn "agent-webservice: AMB setup did not complete cleanly — continuing."
}

# ── 5. wait for backend readiness ─────────────────────────────────────────────
wait_backends_ready() {
  # agent-webservice serves the main API on :3000. Under docker `cargo watch`
  # the first compile can take several minutes, so poll generously (120×5s ≈ 10m).
  # Non-fatal: if it never answers we still let Phase 6 surface the real error.
  wait_for_http "http://localhost:3000/" 120 5 "agent-webservice (:3000)" \
    || warn "agent-webservice did not become ready — Phase 6 may fail."
}

# ── 6. fetch games ────────────────────────────────────────────────────────────
fetch_games() {
  # Prime the platform's game catalogue via the server-to-server endpoint.
  local url="http://localhost:3000/aggregators/fetch-games"
  local out="$LOG_DIR/fetch-games.json" code
  log "agent-webservice: fetching all games ($url)…"
  code="$(curl -s -o "$out" -w '%{http_code}' --max-time 120 "$url" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    log "fetch-games OK (HTTP 200) — response saved to $out"
  else
    warn "fetch-games returned HTTP ${code:-<no response>} — see $out"
  fi
}

# ── teardown (reverse order) ──────────────────────────────────────────────────
down_aggregator_setup() {
  # Stop the ngrok tunnel that Phase 4 (amb_setup.sh) started. Only the tunnel
  # WE started is tracked (via the pidfile amb_setup.sh writes); a pre-existing
  # ngrok that amb_setup.sh merely reused was never tracked, so it is left alone.
  stop_pidfile /tmp/ngrok-amb.pid "ngrok (AMB tunnel)"
}

down_frontends() {
  stop_node_app backoffice 3001
  stop_node_app front-end 3002
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
