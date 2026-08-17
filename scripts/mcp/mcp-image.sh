#!/usr/bin/env bash
# stdio launcher for mcp-image — loads GEMINI_API_KEY from workspace `.env`.
#
# Cursor does not inject direnv / settings.local `env` into MCP children, and
# `${GEMINI_API_KEY}` in .mcp.json therefore stays empty there. Claude Code
# expands process env when launched under direnv; this wrapper covers both.
#
# Required in workspace `.env`:
#   GEMINI_API_KEY
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=load-workspace-env.sh
. "${SCRIPT_DIR}/load-workspace-env.sh"
load_workspace_env GEMINI_API_KEY IMAGE_OUTPUT_DIR IMAGE_QUALITY

: "${GEMINI_API_KEY:?GEMINI_API_KEY is unset — add it to the workspace .env (https://aistudio.google.com/apikey)}"

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH:-/usr/bin:/bin}"
export IMAGE_OUTPUT_DIR="${IMAGE_OUTPUT_DIR:-/tmp/aiworks-generated-images}"
export IMAGE_QUALITY="${IMAGE_QUALITY:-balanced}"

exec npx -y mcp-image
