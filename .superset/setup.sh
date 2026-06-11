#!/usr/bin/env bash
#
# Workspace setup — mani multi-repo workspace.
#
#   .superset/setup.sh
#
# 1. `mani sync` clones any product repo (declared under products[] in
#    workspace.config.yaml via the generated mani.d/<product>.yaml) that is
#    missing — repos are gitignored and don't travel with a new git worktree.
# 2. Seeds the adapter .env files and symlinks scripts/{tracker,vcs} into each
#    repo so relative adapter calls resolve from any repo's working dir.
# 3. Installs Node dependencies in every repo that has a package.json
#    (pnpm when the repo uses pnpm, npm otherwise).
# 4. Reports which backend/frontend repos need their .env files reviewed.
#
# Idempotent — safe to re-run.
#
set -euo pipefail

# Always operate from the workspace root, where mani.yaml lives.
cd "$(dirname "$0")/.."
source .superset/lib.sh

if ! command -v mani >/dev/null 2>&1; then
  err "'mani' is not installed — run 'brew install mani', then re-run setup."
  exit 1
fi

log "mani sync (cloning any missing product repos)…"
mani sync

# Seed the adapter .env files (git-ignored local config). On a fresh worktree, copy them
# from the root workspace if present; harmless to skip — each adapter also reads env vars.
seed_env() {
  local rel="$1"
  local root_src="${SUPERSET_ROOT_PATH:-}/$rel"
  if [[ ! -f "$rel" && -n "${SUPERSET_ROOT_PATH:-}" && -f "$root_src" ]]; then
    cp "$root_src" "$rel" && log "Seeded $rel from the root workspace."
  fi
}
seed_env "scripts/tracker/.env"
seed_env "scripts/vcs/.env"

# Symlink the adapters into each cloned repo so agents working in cwd=<repo> can call
# `scripts/tracker/…` / `scripts/vcs/…` relatively (the originals live at the root).
# A cloned repo is a top-level dir containing a .git entry (dir or worktree file).
log "Linking adapters into each repo…"
for repo in */; do
  repo="${repo%/}"
  [[ -e "$repo/.git" ]] || continue
  mkdir -p "$repo/scripts"
  for a in tracker vcs; do
    if [[ ! -e "$repo/scripts/$a" ]]; then
      ln -s "../../scripts/$a" "$repo/scripts/$a" && echo "    linked $repo/scripts/$a"
    fi
    # Hide the symlink from the repo's git status via the LOCAL-only ignore file
    # (.git/info/exclude) — never committed, so the product repo stays untouched.
    exclude_file="$(cd "$repo" && git rev-parse --git-path info/exclude)"
    [[ "$exclude_file" = /* ]] || exclude_file="$repo/$exclude_file"
    mkdir -p "$(dirname "$exclude_file")"
    if ! grep -qxs "scripts/$a" "$exclude_file"; then
      echo "scripts/$a" >>"$exclude_file" && echo "    excluded scripts/$a in $repo (local git ignore)"
    fi
  done
done

# Install Node dependencies in every repo that has a package.json.
log "Installing Node dependencies…"
for repo in */; do
  repo="${repo%/}"
  [[ -e "$repo/.git" && -f "$repo/package.json" ]] || continue
  node_install "$repo"
done

# .env check: seed from the template where one exists, and tell the human which
# backend/frontend repos still need their environment reviewed/filled in.
log "Checking .env files…"
ENV_TODO=()
for repo in */; do
  repo="${repo%/}"
  [[ -e "$repo/.git" ]] || continue
  if [[ -f "$repo/.env.example" && ! -f "$repo/.env" ]]; then
    cp "$repo/.env.example" "$repo/.env"
    warn "$repo/.env created from .env.example — fill in real values."
    ENV_TODO+=("$repo/.env")
  fi
  # repos whose compose stack reads .env.local (e.g. the backend) need it locally
  if grep -qs '\.env\.local' "$repo"/docker-compose*.yml 2>/dev/null && [[ ! -f "$repo/.env.local" ]]; then
    warn "$repo/.env.local is MISSING but required by its docker-compose — create it before running."
    ENV_TODO+=("$repo/.env.local")
  fi
done

log "Workspace ready. Projects:"
# Start the shared, long-lived MCP service containers (one container shared by every
# client/agent over SSE — replaces the old per-client `docker run` servers that orphaned
# on crash). Idempotent and self-skipping if docker is unavailable. See
# .superset/mcp-compose.yml for the rationale.
echo "==> Starting shared MCP services…"
./.superset/mcp-services.sh up || true

echo "==> Workspace ready. Projects:"
mani list projects

if [[ "${#ENV_TODO[@]}" -gt 0 ]]; then
  warn "ACTION REQUIRED — set the environment values in:"
  printf '      %s\n' "${ENV_TODO[@]}"
else
  log "Reminder: review the .env / .env.local values in the backend & frontend repos before running."
fi
log "Next: .superset/run.sh [product]   (default: ofb-platform)"
