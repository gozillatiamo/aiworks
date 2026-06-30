#!/usr/bin/env bash
#
# Workspace setup — mani multi-repo workspace.
#
#   .superset/setup.sh [-v|--verbose]
#
# Output is QUIET by default (only warnings, errors, and the closing summary). Pass
# -v/--verbose for the full step-by-step log when debugging.
#
# 0. Ensures the host CLI tooling is present — installs (if missing) ngrok, used by the run
#    phase's AMB aggregator (run.sh Phase 4 tunnels :3000 through it; macOS: Homebrew, Linux:
#    the official apt repo, else a static binary), and glab, the GitLab CLI the VCS adapter
#    (scripts/vcs/) drives (Homebrew, else the official release tarball). Best-effort.
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

# Quiet by default; -v/--verbose flips on the full step log. Exported so lib.sh's log() (reads
# $VERBOSE at call-time) and the child `aiworks sync` both honour it.
export VERBOSE="${VERBOSE:-0}"
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) export VERBOSE=1 ;;
    -h|--help)    sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            err "unknown option: $arg"; exit 2 ;;
  esac
done

if ! command -v mani >/dev/null 2>&1; then
  err "'mani' is not installed — run 'brew install mani', then re-run setup."
  exit 1
fi

# ── 0. Host CLI prerequisites (mac/linux). ngrok so the run phase's AMB aggregator can tunnel
# :3000; glab (GitLab CLI) for the VCS adapter. Best-effort — guarded so a failure never
# aborts setup.
log "Ensuring host tooling (ngrok, glab)…"
ensure_ngrok || true
ensure_glab || true

# ── 1. Clone + FULLY onboard every repo declared in workspace.config.yaml products[]. Runs the
# full `aiworks add` toolchain per repo (codegraph index, skill packs, adapter symlinks into
# each repo + .git/info/exclude, Cursor .cursorindexingignore / VS Code search re-inclusion,
# scripts/dev.sh, the .superset lifecycle hooks). Idempotent — already-onboarded repos SKIP.
# -y skips the Proceed prompt so setup stays non-interactive.
log "aiworks sync -y (clone + fully onboard every product repo)…"
sync_args=(-y); [[ "$VERBOSE" == 1 ]] && sync_args+=(--verbose)
scripts/aiworks sync "${sync_args[@]}"

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
# Superset sets SUPERSET_ROOT_PATH. For a MANUAL `git worktree` (no Superset) it's unset, so
# fall back to git's MAIN worktree — that's the root checkout holding the real git-ignored state
# (the main worktree is always the first entry of `git worktree list`). When this IS the main
# worktree, it equals $PWD and the copy below correctly no-ops.
root_ws="${SUPERSET_ROOT_PATH:-}"
if [[ -z "$root_ws" ]]; then
  root_ws="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree /,""); print; exit}')"
  [[ -n "$root_ws" && "$(cd "$root_ws" 2>/dev/null && pwd)" != "$PWD" ]] \
    && log "Not under Superset — copying git-ignored state from git's main worktree: $root_ws"
fi
if [[ -n "$root_ws" && -d "$root_ws" && "$(cd "$root_ws" && pwd)" != "$PWD" ]]; then
  log "Copying .env / .env.* from the root workspace ($root_ws)…"
  copied=0
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    mkdir -p "$(dirname "$rel")"
    if cp "$root_ws/$rel" "$rel" 2>/dev/null; then echo "    copied $rel"; copied=$((copied + 1))
    else warn "could not copy $rel"; fi
  done < <(cd "$root_ws" && find . \
      \( -name node_modules -o -name .git -o -name .next -o -name dist -o -name build -o -name target -o -name .venv -o -name db-data \) -prune \
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
    # On LINUX, native Docker bind-mounts preserve the postgres CONTAINER uid/gid on the host:
    # PGDATA (master/, shard-1/, master-lotto/, cache/) is owned by uid ~999 mode 0700, so the
    # host user can't read it (macOS Docker Desktop's VM file-sharing remaps to the host user, so
    # this never bites there). A plain rsync/cp then fails with "Permission denied" (rsync exit
    # 23) and the DB is left unseeded. Retry under sudo — `-a`/`-p` preserve uid/gid so THIS
    # worktree's postgres container (same uid) can use the data. Best-effort: never abort setup.
    db_cp() { if command -v rsync >/dev/null 2>&1; then rsync -a "$db_src/" agent-db/db-data/; else cp -a "$db_src/." agent-db/db-data/; fi; }
    if db_cp 2>/dev/null; then
      log "agent-db/db-data is in place."
    elif command -v sudo >/dev/null 2>&1; then
      warn "agent-db/db-data: host user can't read the source — Postgres' PGDATA is owned by the container uid (Linux Docker). Retrying with sudo (may prompt for your password)…"
      if command -v rsync >/dev/null 2>&1; then sudo rsync -a "$db_src/" agent-db/db-data/; else sudo cp -a "$db_src/." agent-db/db-data/; fi \
        && log "agent-db/db-data is in place (copied with sudo)." \
        || warn "agent-db/db-data copy still failed. Copy it by hand (ideally with the agent-db containers stopped):  sudo rsync -a \"$db_src/\" \"$PWD/agent-db/db-data/\""
    else
      warn "agent-db/db-data: permission denied and 'sudo' not available. Copy it by hand (root needed — PGDATA is owned by the container uid):  rsync -a \"$db_src/\" \"$PWD/agent-db/db-data/\"  (run as root, or stop the agent-db containers first)."
    fi
  elif [[ ! -d agent-db ]]; then
    warn "agent-db not cloned here — skipping db-data copy."
  else
    warn "No db-data in the root workspace ($db_src) — skipping the seeded-DB copy."
  fi
else
  # No separate root to copy from: this IS the root/main worktree (so the git-ignored state is
  # already here), or it's a standalone checkout (not a linked worktree). Either way there's
  # nothing to copy — the .env check in step 4 still seeds any missing .env from .env.example.
  log "No separate root workspace — skipping the root state copy (this is the root/main worktree, or a standalone checkout). Set SUPERSET_ROOT_PATH=<path> to copy from a specific checkout."
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
log "Starting shared MCP services…"
if [[ "$VERBOSE" == 1 ]]; then ./.superset/mcp-services.sh up || true
else ./.superset/mcp-services.sh up >/dev/null 2>&1 || true; fi

# ── conclusion (always shown, even when quiet — the run's closing section) ──────────
conclude "Workspace ready. Projects:"
mani list projects

if [[ "${#ENV_TODO[@]}" -gt 0 ]]; then
  warn "ACTION REQUIRED — set the environment values in:"
  printf '      %s\n' "${ENV_TODO[@]}"
fi
conclude "Next: .superset/run.sh [product]   (default: ofb-platform)"
