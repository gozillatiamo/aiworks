#!/usr/bin/env bash
# stdio launcher for the local SonarQube MCP container — loads SONARQUBE_TOKEN from the
# workspace `.env` and builds the Authorization header in-process.
#
# Why not an http entry with `Bearer ${SONARQUBE_TOKEN}` in .mcp.json: Claude Code expands
# that only from its own process env (direnv, which a fresh worktree has not allowed), and
# Cursor never expands it in headers. See docs/adr/0043.
#
# Required in workspace `.env`:
#   SONARQUBE_TOKEN
# Optional: MCP_SONARQUBE_PORT (default 25434), MCP_PORT_WAIT_SECS (default 20).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=load-workspace-env.sh
. "${SCRIPT_DIR}/load-workspace-env.sh"
load_workspace_env SONARQUBE_TOKEN MCP_SONARQUBE_PORT

: "${SONARQUBE_TOKEN:?SONARQUBE_TOKEN is unset — add it to the workspace .env}"
port="${MCP_SONARQUBE_PORT:-25434}"

# The container is started by the SessionStart hook, concurrently with MCP connection.
deadline=$(( SECONDS + ${MCP_PORT_WAIT_SECS:-20} ))
until (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; do
  (( SECONDS < deadline )) || { echo "sonarqube MCP not listening on 127.0.0.1:${port} (.superset/mcp-services.sh up)" >&2; exit 1; }
  sleep 1
done

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH:-/usr/bin:/bin}"

exec npx -y mcp-remote "http://localhost:${port}/mcp" \
  --header "Authorization: Bearer ${SONARQUBE_TOKEN}"
