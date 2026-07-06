#!/usr/bin/env bash
#
# Workspace setup — mani multi-repo workspace.
#
#   .superset/setup.sh [-v|--verbose]
#
# Output is QUIET by default (only warnings, errors, and the closing summary). Pass
# -v/--verbose for the full step-by-step log when debugging.
#
# 0. Ensures the host CLI tooling is present — installs (if missing) jq, used by aiworks
#    itself (.code-workspace generation, VS Code settings merge) and the tracker/notify
#    adapters (Homebrew / apt, else the official static binary); ngrok, used by the run
#    phase's optional third-party hook (run.sh Phase 4 can tunnel a port through it; macOS: Homebrew, Linux:
#    the official apt repo, else a static binary); and glab, the GitLab CLI the VCS adapter
#    (scripts/vcs/) drives (Homebrew, else the official release tarball). Best-effort.
# 1. `aiworks sync -y` clones + FULLY onboards every product repo declared under
#    products[] in workspace.config.yaml (via the generated mani.d/<product>.yaml)
#    — repos are gitignored and don't travel with a new git worktree. Full onboard
#    toolchain (codegraph index, skill packs, adapter symlinks, Cursor/VS Code
#    search re-inclusion, scripts/dev.sh, lifecycle hooks); -y skips its prompt.
# 2. Copies the REAL local state from the root workspace into this worktree — a fresh
#    worktree carries none of its own: every .env / .env.* (every repo + adapter +
#    .superset/.env) recursively, AND every repo's seeded db-data Postgres cluster. Runs
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

# ── 0. Host CLI prerequisites (mac/linux). jq for aiworks itself (.code-workspace generation,
# VS Code settings merge) + the tracker/notify adapters — so it comes first; ngrok so the run
# phase's optional third-party hook can tunnel a local port; glab (GitLab CLI) for the VCS adapter. Best-effort —
# guarded so a failure never aborts setup.
log "Ensuring host tooling (jq, ngrok, glab)…"
ensure_jq || true
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

# ── 2. Bring the REAL local state (git-ignored, so a fresh worktree carries NONE of it) into
# this worktree from the root workspace — by DEFAULT as symlinks (one source of truth; cheap):
#   • every .env / .env.* file (except .env.example, which is committed upstream and already
#     travels with the clone), recursively, preserving each file's relative path — every
#     repo's + adapter's env AND .superset/.env (read by the MCP service containers in step 4).
#     SUPERSET_ENV (default symlink) → symlink each at the root's (edit once, every worktree
#     sees it), =copy for an independent per-worktree snapshot, or =skip to manage them yourself.
#   • <repo>/db-data — a seeded local Postgres cluster a DB repo's containers bind-mount;
#     without it the local DB comes up empty. Every <repo>/db-data dir found in the root
#     workspace is provisioned. SUPERSET_DB_DATA (default symlink — instant, no big copy,
#     no sudo) → symlink the root's, =copy for an isolated per-worktree copy, or =skip to
#     manage it yourself.
# Runs BEFORE the MCP services start so they come up on real config + a seeded DB, not defaults.
# SUPERSET_ROOT_PATH is set by Superset to the root workspace path; the root stays the source of
# truth (an existing file/link at the destination is replaced to match it).
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
  # Env provisioning mode → SUPERSET_ENV (default: symlink). symlink keeps ONE source of truth
  # (the root's file); copy snapshots it per-worktree; skip leaves the worktree's env alone.
  env_mode="${SUPERSET_ENV:-symlink}"
  if [[ "$env_mode" == skip ]]; then
    log "env files: SUPERSET_ENV=skip — leaving them as-is."
  else
    if [[ "$env_mode" == symlink ]]; then log "Symlinking .env / .env.* from the root workspace ($root_ws)…"
    else                                  log "Copying .env / .env.* from the root workspace ($root_ws)…"; fi
    env_count=0
    while IFS= read -r -d '' rel; do
      rel="${rel#./}"
      mkdir -p "$(dirname "$rel")"
      if [[ "$env_mode" == symlink ]]; then
        if [[ -L "$rel" && "$(readlink "$rel")" == "$root_ws/$rel" ]]; then env_count=$((env_count + 1)); continue; fi
        rm -f "$rel" 2>/dev/null   # replace any stale link / copied file with the link
        if ln -s "$root_ws/$rel" "$rel" 2>/dev/null; then echo "    linked $rel"; env_count=$((env_count + 1))
        else warn "could not symlink $rel"; fi
      else
        [[ -L "$rel" ]] && rm -f "$rel"   # was a symlink → drop it before copying the file in
        if cp "$root_ws/$rel" "$rel" 2>/dev/null; then echo "    copied $rel"; env_count=$((env_count + 1))
        else warn "could not copy $rel"; fi
      fi
    done < <(cd "$root_ws" && find . \
        \( -name node_modules -o -name .git -o -name .next -o -name dist -o -name build -o -name target -o -name .venv -o -name db-data \) -prune \
        -o -type f \( -name '.env' -o -name '.env.*' \) ! -name '.env.example' -print0)
    env_verb="linked"; [[ "$env_mode" == copy ]] && env_verb="copied"
    log "$env_verb $env_count env file(s) from the root workspace."
  fi

  # <repo>/db-data — seeded local Postgres clusters (git-ignored). A DB repo's containers
  # bind-mount its db-data subdirs, so without it the local DB comes up empty. Every
  # <repo>/db-data dir found in the root workspace is provisioned here. Provisioning mode →
  # SUPERSET_DB_DATA (default: symlink). See the step-2 header above for the trade-offs.
  db_mode="${SUPERSET_DB_DATA:-symlink}"
  if [[ "$db_mode" == skip ]]; then
    log "db-data: SUPERSET_DB_DATA=skip — leaving seeded DB clusters as-is."
  else
    for db_src in "$root_ws"/*/db-data; do
      [[ -d "$db_src" ]] || continue
      db_repo="$(basename "$(dirname "$db_src")")"
      db_dst="$db_repo/db-data"
      if [[ ! -d "$db_repo" ]]; then
        warn "$db_repo not cloned here — skipping its db-data provisioning."
      elif [[ "$db_mode" == symlink ]]; then
        # Point this worktree's db-data at the root's seeded cluster. Docker (Linux native)
        # resolves the symlink when it sets up the bind mounts, so the containers read the
        # root's PGDATA — no big copy and no sudo to read the 0700 dirs. All worktrees + root
        # then share ONE physical DB.
        if [[ -L "$db_dst" && "$(readlink "$db_dst")" == "$db_src" ]]; then
          log "$db_dst already symlinked to the root workspace ($db_src)."
        else
          # A real dir in the way must go first — likely root-owned (PGDATA = container uid),
          # so its removal may need sudo. Best-effort; never abort setup.
          if [[ -e "$db_dst" && ! -L "$db_dst" ]]; then
            if ! rm -rf "$db_dst" 2>/dev/null; then
              if command -v sudo >/dev/null 2>&1; then
                warn "$db_dst: removing the existing per-worktree copy needs root (PGDATA owned by the container uid) — sudo may prompt…"
                sudo rm -rf "$db_dst" || warn "$db_dst: could not remove the existing copy — remove it by hand, then re-run."
              else
                warn "$db_dst: a real copy is in the way and can't be removed (no sudo). Remove it by hand, or set SUPERSET_DB_DATA=copy."
              fi
            fi
          fi
          rm -f "$db_dst" 2>/dev/null   # drop any stale / wrong-target symlink
          if [[ ! -e "$db_dst" ]] && ln -s "$db_src" "$db_dst"; then
            log "$db_dst → $db_src (symlinked; shared with the root workspace)."
          else
            warn "$db_dst: could not symlink to the root workspace (a real dir may remain). Remove it and re-run, or use SUPERSET_DB_DATA=copy."
          fi
        fi
      else
        # copy mode — an ISOLATED per-worktree DB. Mirror with rsync (diffs only — cheap on
        # re-run); cp -a as a fallback. Trailing "/" (rsync) and "/." (cp) copy the CONTENTS
        # in so re-runs don't nest the dir.
        [[ -L "$db_dst" ]] && rm -f "$db_dst"   # was a symlink → drop it before copying in
        log "Copying $db_dst (seeded local DB) from the root workspace…"
        mkdir -p "$db_dst"
        # On LINUX, native Docker bind-mounts preserve the postgres CONTAINER uid/gid on the
        # host: PGDATA is owned by uid ~999 mode 0700, so the host user can't read it (macOS
        # Docker Desktop's VM file-sharing remaps to the host user, so this never bites there).
        # A plain rsync/cp then fails with "Permission denied" (rsync exit 23) and the DB is
        # left unseeded. Retry under sudo — `-a`/`-p` preserve uid/gid so THIS worktree's
        # postgres container (same uid) can use the data. Best-effort: never abort setup.
        db_cp() { if command -v rsync >/dev/null 2>&1; then rsync -a "$db_src/" "$db_dst/"; else cp -a "$db_src/." "$db_dst/"; fi; }
        if db_cp 2>/dev/null; then
          log "$db_dst is in place."
        elif command -v sudo >/dev/null 2>&1; then
          warn "$db_dst: host user can't read the source — Postgres' PGDATA is owned by the container uid (Linux Docker). Retrying with sudo (may prompt for your password)…"
          if command -v rsync >/dev/null 2>&1; then sudo rsync -a "$db_src/" "$db_dst/"; else sudo cp -a "$db_src/." "$db_dst/"; fi \
            && log "$db_dst is in place (copied with sudo)." \
            || warn "$db_dst copy still failed. Copy it by hand (ideally with the $db_repo containers stopped):  sudo rsync -a \"$db_src/\" \"$PWD/$db_dst/\""
        else
          warn "$db_dst: permission denied and 'sudo' not available. Copy it by hand (root needed — PGDATA is owned by the container uid):  rsync -a \"$db_src/\" \"$PWD/$db_dst/\"  (run as root, or stop the $db_repo containers first)."
        fi
      fi
    done
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
conclude "Next: .superset/run.sh [product]"
