#!/usr/bin/env bash
#
# Workspace setup — mani multi-repo workspace.
#
#   .superset/setup.sh
#
# 1. `aiworks sync -y` clones + FULLY onboards every product repo declared under
#    products[] in workspace.config.yaml (via the generated mani.d/<product>.yaml)
#    — repos are gitignored and don't travel with a new git worktree. Full onboard
#    toolchain (codegraph index, skill packs, adapter symlinks, Cursor/VS Code
#    search re-inclusion, scripts/dev.sh, lifecycle hooks); -y skips its prompt.
# 2. Copies the REAL local state from the root workspace into this worktree — a fresh
#    worktree carries none of its own: every .env / .env.* (every repo + adapter +
#    .superset/.env) recursively, AND agent-db's seeded db-data Postgres cluster. Runs
#    before the MCP services so they come up on real config + a seeded DB.
# 3. Installs Node dependencies in every repo that has a package.json
#    (pnpm when the repo uses pnpm, npm otherwise — aiworks does not do this).
# 4. Starts the shared MCP service containers, then reports which repos still
#    need their .env reviewed.
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

# ── 1. Clone + FULLY onboard every repo declared in workspace.config.yaml products[]. Runs the
# full `aiworks add` toolchain per repo (codegraph index, skill packs, adapter symlinks into
# each repo + .git/info/exclude, Cursor .cursorindexingignore / VS Code search re-inclusion,
# scripts/dev.sh, the .superset lifecycle hooks). Idempotent — already-onboarded repos SKIP.
# -y skips the Proceed prompt so setup stays non-interactive.
log "aiworks sync -y (clone + fully onboard every product repo)…"
scripts/aiworks sync -y

# ── 2. Copy the REAL local state (git-ignored, so a fresh worktree carries NONE of it) from
# the root workspace into this worktree:
#   • every .env / .env.* file (except .env.example, which is committed upstream and already
#     travels with the clone), recursively, preserving each file's relative path — every
#     repo's + adapter's env AND .superset/.env (read by the MCP service containers in step 4);
#   • agent-db/db-data — the seeded local Postgres cluster the agent-db containers bind-mount
#     (master :5432, shard-1 :5433, …); without it the local DB comes up empty.
# We pull the actual secrets + data from the root checkout. Runs BEFORE the MCP services start
# so they come up on real config + a seeded DB, not defaults. SUPERSET_ROOT_PATH is set by
# Superset to the root workspace path. The copy overwrites (root is the source of truth) and
# prunes build/dependency dirs.
root_ws="${SUPERSET_ROOT_PATH:-}"
if [[ -n "$root_ws" && -d "$root_ws" && "$(cd "$root_ws" && pwd)" != "$PWD" ]]; then
  log "Copying .env / .env.* from the root workspace ($root_ws)…"
  copied=0
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    mkdir -p "$(dirname "$rel")"
    if cp "$root_ws/$rel" "$rel" 2>/dev/null; then echo "    copied $rel"; copied=$((copied + 1))
    else warn "could not copy $rel"; fi
  done < <(cd "$root_ws" && find . \
      \( -name node_modules -o -name .git -o -name .next -o -name dist -o -name build -o -name target -o -name .venv \) -prune \
      -o -type f \( -name '.env' -o -name '.env.*' \) ! -name '.env.example' -print0)
  log "Copied $copied env file(s) from the root workspace."

  # agent-db/db-data — the seeded local Postgres cluster (~1G, git-ignored). The agent-db
  # containers bind-mount its subdirs (./db-data/master → :5432, ./db-data/shard-1 → :5433,
  # master-lotto, cache), so a fresh clone's empty data dir means an unseeded local DB. Mirror
  # it from the root with rsync (only transfers diffs — cheap on re-run); cp -R as a fallback.
  # Trailing "/" (rsync) and "/." (cp) copy the CONTENTS in, so re-runs don't nest the dir.
  db_src="$root_ws/agent-db/db-data"
  if [[ -d "$db_src" && -d agent-db ]]; then
    log "Copying agent-db/db-data (seeded local DB) from the root workspace…"
    mkdir -p agent-db/db-data
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "$db_src/" agent-db/db-data/ && log "agent-db/db-data is in place."
    else
      cp -R "$db_src/." agent-db/db-data/ && log "agent-db/db-data is in place."
    fi
  elif [[ ! -d agent-db ]]; then
    warn "agent-db not cloned here — skipping db-data copy."
  else
    warn "No db-data in the root workspace ($db_src) — skipping the seeded-DB copy."
  fi
else
  warn "SUPERSET_ROOT_PATH unset or equals this workspace — skipping the root env copy (running in the root workspace itself?)."
fi

# ── 3. Install Node dependencies in every repo that has a package.json (aiworks does not).
log "Installing Node dependencies…"
for repo in */; do
  repo="${repo%/}"
  [[ -e "$repo/.git" && -f "$repo/package.json" ]] || continue
  node_install "$repo"
done

# .env check: after the root copy above, fall back to .env.example for any repo still without
# a .env, and tell the human which backend/frontend repos still need their environment filled.
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

# NOTE: Cursor (.cursorindexingignore) and VS Code (.vscode/settings.json) search
# re-inclusion, plus the per-repo adapter symlinks, are handled by `aiworks sync` above
# (the `aiworks add` toolchain, per repo) — no longer duplicated here.

# ── 4. Start the shared, long-lived MCP service containers (one container shared by every
# client/agent over SSE — replaces the old per-client `docker run` servers that orphaned
# on crash). Reads .superset/.env (copied from the root in step 2) for DATABASE_URI etc.
# Idempotent and self-skipping if docker is unavailable. See .superset/mcp-compose.yml.
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
