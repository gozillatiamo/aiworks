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

# ── frontend profile ──────────────────────────────────────────────────────────
# Each Next.js dev server costs ~2 GB RAM, and you normally play ONE player site
# at a time — so running all three at once needlessly eats ~40% of a 16 GB box and
# forces the machine into swap. The default therefore runs ONE player site + the
# backoffice. Pick which with OFB_PLAYER_SITE (default: paotung):
#
#   OFB_PLAYER_SITE=paotung   .superset/run.sh   → paotung-template + backoffice   (default)
#   OFB_PLAYER_SITE=ohanabet  .superset/run.sh   → front-end        + backoffice
#   OFB_PLAYER_SITE=all       .superset/run.sh   → paotung-template + front-end + backoffice  (old behaviour)
#
# Or the friendlier spelling — `aiworks run --site <paotung|ohanabet|all>` sets
# OFB_PLAYER_SITE for you (run.sh -s/--site).
#
# Or set OFB_FRONTENDS to a custom space-separated list to override entirely, e.g.
#   OFB_FRONTENDS="paotung-template"  .superset/run.sh   → player site only, no backoffice
if [[ -n "${OFB_FRONTENDS:-}" ]]; then
  read -r -a FRONTEND_REPOS <<< "$OFB_FRONTENDS"
else
  case "${OFB_PLAYER_SITE:-paotung}" in
    paotung)  FRONTEND_REPOS=(paotung-template backoffice) ;;
    ohanabet) FRONTEND_REPOS=(front-end backoffice) ;;
    all)      FRONTEND_REPOS=(paotung-template front-end backoffice) ;;
    *) echo "WARN: unknown OFB_PLAYER_SITE='${OFB_PLAYER_SITE:-}', using 'paotung' (paotung-template + backoffice)." >&2
       FRONTEND_REPOS=(paotung-template backoffice) ;;
  esac
fi

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
  # Start only the frontends the profile selected (FRONTEND_REPOS, set above).
  # Ports/commands are unchanged; paotung additionally needs its nginx (docker).
  local repo
  for repo in "${FRONTEND_REPOS[@]}"; do
    case "$repo" in
      paotung-template)
        # paotung-template: nginx (docker, :80) + next dev on :3004 (pnpm).
        log "paotung-template: starting nginx (docker compose up -d nginx)…"
        (cd paotung-template && docker compose up -d nginx)
        start_node_app paotung-template dev 3004 ;;
      front-end)
        # front-end: OHANABET theme — next dev on :3002 (pnpm), no docker.
        start_node_app front-end dev 3002 ;;
      backoffice)
        # backoffice: next dev on :3001 (npm), no docker.
        start_node_app backoffice dev 3001 ;;
      *)
        warn "run_frontends: unknown frontend '$repo' — skipping." ;;
    esac
  done
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
  # run_glance gives this long wait a visible title + a live elapsed/attempt
  # glance even in the default quiet run — before, the wait was log()-only, so
  # right after AMB setup printed "done" the run went DARK for up to 10 min.
  # Non-fatal: if it never answers we still let Phase 6 surface the real error.
  run_glance "agent-webservice: waiting for the backend on :3000 (first cargo build can take ~10 min)" \
       wait_for_http "http://localhost:3000/" 120 5 "agent-webservice (:3000)" \
    || warn "agent-webservice did not become ready — Phase 6 may fail."
}

# ── 6. fetch games ────────────────────────────────────────────────────────────
fetch_games() {
  # Prime the platform's game catalogue via the server-to-server endpoint.
  # NB: this is a long, silent server-side fetch (the backend pulls the whole catalogue
  # from every aggregator). The old version paired quiet-only log() with `curl -s`, so in
  # the default quiet run the phase went completely DARK for up to 2 min and looked frozen.
  # run_glance shows a visible titled section + a live progress glance + ✓/elapsed even in
  # quiet mode; `-fS` makes curl fail (non-zero) on HTTP >=400 so the ✓/✗ is accurate; the
  # body is still saved to $out for inspection. --max-time 300: a cold catalogue can exceed 120s.
  local url="http://localhost:3000/aggregators/fetch-games"
  local out="$LOG_DIR/fetch-games.json"
  if run_glance "agent-webservice: fetching all games ($url)" \
       curl -fS --max-time 300 -o "$out" "$url"; then
    log "fetch-games OK — response saved to $out"
  else
    warn "fetch-games failed — see $out (re-run with -v for the full response)"
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
