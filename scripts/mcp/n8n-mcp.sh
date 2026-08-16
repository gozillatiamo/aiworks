#!/usr/bin/env bash
# stdio bridge for a remote n8n MCP (Streamable HTTP).
#
# Why this exists: Cursor does not substitute ${VAR} inside HTTP `headers` in
# .mcp.json (measured: literal Bearer ${N8N_MCP_ACCESS_TOKEN} → 401; the same
# token from the process env → 200). Claude Code expands those headers; Cursor
# does not. Spawning through bash lets the shell expand secrets from the
# environment (direnv / .env / settings.local.json → process env).
#
# Cursor also mangles `--header` values that contain spaces when they are plain
# mcp.json args — keep the header construction inside this script.
#
# Required env:
#   N8N_MCP_URL            e.g. https://<host>/mcp-server/http
#   N8N_MCP_ACCESS_TOKEN   instance MCP access token from n8n settings
set -euo pipefail

: "${N8N_MCP_URL:?N8N_MCP_URL is unset — e.g. https://<host>/mcp-server/http}"
: "${N8N_MCP_ACCESS_TOKEN:?N8N_MCP_ACCESS_TOKEN is unset — export it (direnv /.env) or set env.N8N_MCP_ACCESS_TOKEN in .claude/settings.local.json}"

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH:-/usr/bin:/bin}"

exec npx -y mcp-remote "${N8N_MCP_URL}" \
  --header "Authorization: Bearer ${N8N_MCP_ACCESS_TOKEN}"
