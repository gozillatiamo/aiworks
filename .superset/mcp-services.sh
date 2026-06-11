#!/usr/bin/env bash
#
# mcp-services.sh — manage the workspace's SHARED, long-lived MCP service containers.
#
# These replace the old per-client `docker run -i` MCP servers in .mcp.json (which were
# spawned once per agent and orphaned on crash). One long-lived container, shared by every
# client/agent over SSE. See .superset/mcp-compose.yml for the rationale.
#
#   mcp-services.sh up      start (or no-op if already running) the shared MCP stack
#   mcp-services.sh down    stop + remove the shared MCP stack
#   mcp-services.sh reap     kill STRAY per-client MCP containers (orphans not managed
#                            by this compose stack) — the old-model sediment
#   mcp-services.sh status   show the shared stack's containers
#
# Safe to call when docker is absent or the daemon is down: it prints a note and exits 0
# (so a SessionStart hook / setup never breaks a workspace that doesn't use these services).
#
# bash 3.2-compatible (macOS system bash) — no mapfile / associative arrays.
set -uo pipefail

cd "$(dirname "$0")/.."                   # workspace root (sibling of scripts/, .superset/)
COMPOSE_FILE=".superset/mcp-compose.yml"
PROJECT="aiworks-mcp"                     # must match `name:` in the compose file
# Images run as per-client stdio MCP servers in the old model — reaped as strays.
STRAY_IMAGES="crystaldba/postgres-mcp mcp/sonarqube"

[[ -f "$COMPOSE_FILE" ]] || exit 0        # nothing to manage in this workspace

have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

compose() {
  local args=(-f "$COMPOSE_FILE")
  [[ -f .superset/.env ]] && args+=(--env-file .superset/.env)
  docker compose "${args[@]}" "$@"
}

# Echo the IDs of containers for the given image that are NOT part of our compose stack.
strays_for() {
  local image="$1" keep id
  keep=" $(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null | tr '\n' ' ') "
  for id in $(docker ps -aq --filter "ancestor=$image" 2>/dev/null); do
    case "$keep" in *" $id "*) ;; *) printf '%s ' "$id" ;; esac
  done
}

cmd="${1:-up}"
case "$cmd" in
  up)
    have_docker || { echo "mcp-services: docker unavailable — skipping shared MCP startup." >&2; exit 0; }
    compose up -d --quiet-pull && echo "mcp-services: shared MCP stack up (project $PROJECT)."
    ;;
  down)
    have_docker || exit 0
    compose down && echo "mcp-services: shared MCP stack down."
    ;;
  reap)
    have_docker || exit 0
    reaped=0
    for image in $STRAY_IMAGES; do
      ids="$(strays_for "$image")"
      if [[ -n "${ids// }" ]]; then
        # shellcheck disable=SC2086
        docker rm -f $ids >/dev/null 2>&1 && echo "mcp-services: reaped strays for $image:$ids" && reaped=1
      fi
    done
    [[ $reaped -eq 0 ]] && echo "mcp-services: no stray MCP containers to reap."
    ;;
  status)
    have_docker || { echo "mcp-services: docker unavailable."; exit 0; }
    compose ps
    ;;
  *)
    echo "usage: mcp-services.sh up|down|reap|status" >&2
    exit 2
    ;;
esac
