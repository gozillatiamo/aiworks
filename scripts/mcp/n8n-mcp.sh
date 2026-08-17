#!/usr/bin/env bash
# stdio bridge for a remote n8n MCP (Streamable HTTP).
#
# Why this exists:
#   1. Cursor does not substitute ${VAR} inside HTTP `headers` in .mcp.json
#      (literal Bearer ${N8N_MCP_ACCESS_TOKEN} → 401). Claude Code does expand.
#   2. Cursor does not inject direnv / settings.local `env` into MCP children.
#   Secrets therefore load from the workspace-root `.env` (SoT) via
#   load-workspace-env.sh, then mcp-remote builds the Authorization header.
#
# Required in workspace `.env` (direnv):
#   N8N_MCP_URL            e.g. https://<host>/mcp-server/http
#   N8N_MCP_ACCESS_TOKEN   instance MCP access token from n8n settings
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=load-workspace-env.sh
. "${SCRIPT_DIR}/load-workspace-env.sh"
load_workspace_env N8N_MCP_URL N8N_MCP_ACCESS_TOKEN

: "${N8N_MCP_URL:?N8N_MCP_URL is unset — add it to the workspace .env (e.g. https://<host>/mcp-server/http)}"
: "${N8N_MCP_ACCESS_TOKEN:?N8N_MCP_ACCESS_TOKEN is unset — add it to the workspace .env}"

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH:-/usr/bin:/bin}"

exec npx -y mcp-remote "${N8N_MCP_URL}" \
  --header "Authorization: Bearer ${N8N_MCP_ACCESS_TOKEN}"
