#!/usr/bin/env bash
# Load selected KEY=VALUE pairs from the workspace-root `.env` (or, when absent,
# the main checkout's) into the current shell when those keys are unset. Never
# prints values.
#
# Source this file from an MCP stdio wrapper:
#   SCRIPT_DIR=… ROOT=…
#   # shellcheck source=load-workspace-env.sh
#   . "$SCRIPT_DIR/load-workspace-env.sh"
#   load_workspace_env N8N_MCP_URL N8N_MCP_ACCESS_TOKEN
#
# Single source of truth for MCP secrets is the git-ignored workspace `.env`
# (direnv `dotenv`). Do not put tokens in `.claude/settings.local.json`.
load_workspace_env() {
  local file="${ROOT:?ROOT unset}/.env" main
  # A fresh linked worktree gets its .env late in setup; until then read the main checkout's
  # (the first `worktree` line), the same file setup links in.
  if [[ ! -f "$file" ]]; then
    main="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
    [[ -n "$main" ]] && file="$main/.env"
  fi
  [[ -f "$file" ]] || return 0
  local line key val
  local -a want=("$@")
  local w
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    local hit=0
    for w in "${want[@]}"; do
      [[ "$key" == "$w" ]] && { hit=1; break; }
    done
    [[ "$hit" -eq 1 ]] || continue
    [[ -n "${!key:-}" ]] && continue
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" == \"*\" && "$val" == *\" ]]; then val="${val:1:${#val}-2}"; fi
    if [[ "$val" == \'*\' && "$val" == *\' ]]; then val="${val:1:${#val}-2}"; fi
    printf -v "$key" '%s' "$val"
    export "$key"
  done < "$file"
}
