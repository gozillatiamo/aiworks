#!/usr/bin/env bash
#
# Shared helpers for the .superset lifecycle scripts (setup / run / teardown).
# Sourced, never executed. Works on macOS bash 3.2 (no associative arrays).
#

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m err\033[0m %s\n' "$*" >&2; }

# Runtime state for background (non-docker) apps, per product.
# Set by run.sh/teardown.sh before sourcing a product file.
runtime_dirs() {  # <product>
  RUN_DIR=".superset/run/$1"
  LOG_DIR=".superset/logs/$1"
  mkdir -p "$RUN_DIR" "$LOG_DIR"
}

# Pick the package manager for a repo: pnpm when a pnpm lockfile or
# packageManager field says so, else npm.
node_pm() {  # <repo>
  if [[ -f "$1/pnpm-lock.yaml" ]] || grep -q '"packageManager": *"pnpm' "$1/package.json" 2>/dev/null; then
    echo pnpm
  else
    echo npm
  fi
}

# Install node deps for one repo (skips repos without package.json).
node_install() {  # <repo>
  local repo="$1" pm
  [[ -f "$repo/package.json" ]] || return 0
  pm="$(node_pm "$repo")"
  if ! command -v "$pm" >/dev/null 2>&1; then
    warn "$repo: '$pm' not installed — skipping dependency install."
    return 0
  fi
  log "$repo: $pm install"
  if ! (cd "$repo" && "$pm" install); then
    if [[ "$pm" == npm ]]; then
      # repos with lockfiles resolved under npm's legacy peer-deps rules
      # (e.g. cypress plugin peer ranges) fail a strict install — retry.
      warn "$repo: npm install hit a peer-deps conflict — retrying with --legacy-peer-deps."
      (cd "$repo" && npm install --legacy-peer-deps)
    else
      return 1
    fi
  fi
}

# Start a long-running package.json script in the background, with a pidfile
# and a logfile under .superset/{run,logs}/<product>/.
start_node_app() {  # <repo> <script> [port]
  local repo="$1" script="$2" port="${3:-}"
  local pidfile="$PWD/$RUN_DIR/$repo.pid" logfile="$PWD/$LOG_DIR/$repo.log" pm pid
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    log "$repo: already running (pid $(cat "$pidfile")) — skipping."
    return 0
  fi
  pm="$(node_pm "$repo")"
  # Launched under nohup (no TTY). Before `run`, pnpm runs a deps-status check;
  # when node_modules is out of sync with the lockfile it tries to purge+reinstall,
  # which needs a TTY to confirm and otherwise aborts the launch with
  # ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY (the app never starts). CI=true makes
  # that purge/reinstall non-interactive — pnpm's own documented remedy — so the app
  # self-heals instead of failing. Harmless to `npm run` (npm does not purge on run).
  (cd "$repo" && CI=true nohup "$pm" run "$script" >"$logfile" 2>&1 & echo $! >"$pidfile")
  pid="$(cat "$pidfile")"
  log "$repo: started '$pm run $script' (pid $pid${port:+, port $port}) — log: $LOG_DIR/$repo.log"
}

# Stop a background app started by start_node_app: kill the pid tree, then
# anything still bound to the port (dev servers fork child processes).
stop_node_app() {  # <repo> [port]
  local repo="$1" port="${2:-}"
  local pidfile="$RUN_DIR/$repo.pid" pid
  if [[ -f "$pidfile" ]]; then
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      log "$repo: stopped (pid $pid)."
    fi
    rm -f "$pidfile"
  fi
  if [[ -n "$port" ]]; then
    local strays
    strays="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
    if [[ -n "$strays" ]]; then
      echo "$strays" | xargs kill -TERM 2>/dev/null || true
      log "$repo: killed stray process(es) on port $port."
    fi
  fi
}

# Stop a background process recorded in a pidfile (TERM the pid + its tree), then
# remove the pidfile. For host-level helpers started outside the node-app scheme
# (e.g. the ngrok tunnel amb_setup.sh starts). No pidfile → nothing to do, so a
# process we did NOT start (and never tracked) is left untouched.
stop_pidfile() {  # <pidfile> <label>
  local pidfile="$1" label="$2" pid
  [[ -f "$pidfile" ]] || return 0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    log "$label: stopped (pid $pid)."
  else
    log "$label: not running (stale pidfile) — cleaning up."
  fi
  rm -f "$pidfile"
}

# Wait until a postgres service inside a repo's compose stack answers pg_isready.
wait_for_postgres() {  # <repo> <compose-service> [profile] [tries]
  local repo="$1" svc="$2" profile="${3:-all}" tries="${4:-30}"
  log "$repo: waiting for postgres service '$svc'…"
  until (cd "$repo" && docker compose --profile "$profile" exec -T "$svc" pg_isready -U postgres -q) >/dev/null 2>&1; do
    tries=$((tries - 1))
    if [[ "$tries" -le 0 ]]; then
      err "$repo: postgres service '$svc' did not become ready."
      return 1
    fi
    sleep 2
  done
  log "$repo: '$svc' is ready."
}

# Wait until an HTTP endpoint answers — i.e. the listener is accepting requests.
# Success = curl gets ANY HTTP status back (http_code != 000), not a specific
# code, so a service that boots into a 404/401 still counts as "up". Returns 0
# when ready, 1 on timeout (the caller decides whether that is fatal).
wait_for_http() {  # <url> [tries] [sleep-secs] [label]
  local url="$1" tries="${2:-60}" nap="${3:-5}" label="${4:-$1}" code
  log "waiting for $label ($url)…"
  while :; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"
    if [[ -n "$code" && "$code" != "000" ]]; then
      log "$label is up (HTTP $code)."
      return 0
    fi
    tries=$((tries - 1))
    if [[ "$tries" -le 0 ]]; then
      err "$label did not answer after the wait window: $url"
      return 1
    fi
    sleep "$nap"
  done
}

# Run a one-shot migration compose file (e.g. liquibase runner) and propagate
# the runner's exit code, then clean up the exited container.
run_migration() {  # <repo> <compose-file> <service>
  local repo="$1" file="$2" svc="$3" rc=0
  log "$repo: applying migrations ($file)…"
  (cd "$repo" && docker compose -f "$file" up --exit-code-from "$svc") || rc=$?
  # plain `down` only removes the services defined in $file (the one-shot
  # runner). NEVER pass --remove-orphans here: the runner shares the compose
  # project with the repo's main docker-compose.yml, so orphan-removal would
  # delete the running database containers themselves.
  (cd "$repo" && docker compose -f "$file" down) >/dev/null 2>&1 || true
  if [[ "$rc" -ne 0 ]]; then
    err "$repo: migration runner $file failed (exit $rc)."
    return "$rc"
  fi
  log "$repo: migrations from $file applied."
}

# Source the product definition file; lists available products on a miss.
load_product() {  # <product>
  local product="$1" file=".superset/products/$1.sh"
  if [[ ! -f "$file" ]]; then
    err "unknown product '$product'. Available products:"
    ls .superset/products/ 2>/dev/null | sed -e 's/\.sh$//' -e 's/^/  - /' >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$file"
}
