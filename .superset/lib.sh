#!/usr/bin/env bash
#
# Shared helpers for the .superset lifecycle scripts (setup / run / teardown).
# Sourced, never executed. Works on macOS bash 3.2 (no associative arrays).
#

# Output is QUIET by default — progress chatter (`log`) is suppressed; only warnings,
# errors, and the final conclusion show. Set VERBOSE=1 (the lifecycle scripts' -v/--verbose
# flag exports it) to see every step. warn/err ALWAYS print (you want to know about problems);
# `conclude` ALWAYS prints — it's the run's closing section, so the output always ends with it.
VERBOSE="${VERBOSE:-0}"
log()      { [[ "$VERBOSE" == 1 ]] || return 0; printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn()     { printf '\033[1;33m !!\033[0m %s\n' "$*"; }
err()      { printf '\033[1;31m err\033[0m %s\n' "$*" >&2; }
conclude() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

# How many trailing output lines the quiet-mode "glance" keeps on screen (override with
# GLANCE_MAX=N). The debug/verbose mode ignores this and streams everything.
GLANCE_MAX="${GLANCE_MAX:-5}"

# Render ONE slow command as a docker-build-style SECTION: a bold topic title, with the
# command's output streaming beneath it in GRAY as a live "glance" — like watching a package
# install scroll inside a build step. The title carries the status marker (▸ running, then ✓ /
# ✗ with elapsed time on completion).
#   • VERBOSE=1 (debug)      → title, the command's FULL output verbatim, then the ✓/✗ status.
#   • quiet (default) + TTY  → title, then ONLY the last GLANCE_MAX lines in gray, truncated to
#                              the terminal width and redrawn IN PLACE so nothing scrolls. On
#                              success the gray glance collapses away and the title becomes
#                              "✓ <title> (Ns)"; on failure the last lines stay put under a
#                              "✗ <title>" so the error is visible.
#   • quiet + no TTY (CI)    → title + ✓/✗ status line; the tail is dumped (stderr) on failure.
# Combined stdout+stderr is shown. Returns the command's OWN exit status. macOS bash 3.2 safe.
# Pass an optional-sudo prefix UNQUOTED ($SUDO) — an empty value simply drops out.
run_glance() {  # <title> <cmd> [args…]
  local title="$1"; shift
  local start="$SECONDS" rc=0 i
  # palette: bold cyan marker + bold title; green/red status; gray (90m) for the glance body.
  local MK='\033[1;36m' TI='\033[1m' OK='\033[1;32m' ER='\033[1;31m' GY='\033[90m' OFF='\033[0m'

  if [[ "$VERBOSE" == 1 ]]; then
    printf '%b▸%b %b%s%b\n' "$MK" "$OFF" "$TI" "$title" "$OFF"
    "$@" || rc=$?
    if [[ "$rc" -eq 0 ]]; then printf '%b✓%b %b%s%b %b(%ds)%b\n'    "$OK" "$OFF" "$TI" "$title" "$OFF" "$GY" "$((SECONDS - start))" "$OFF"
    else                       printf '%b✗%b %b%s%b %b(exit %d)%b\n' "$ER" "$OFF" "$TI" "$title" "$OFF" "$GY" "$rc" "$OFF"; fi
    return "$rc"
  fi

  # Always print the topic title — quiet mode is no longer dead-silent for the slow bits.
  printf '%b▸%b %b%s%b\n' "$MK" "$OFF" "$TI" "$title" "$OFF"

  if [[ ! -t 1 ]]; then  # no TTY (CI / piped): can't redraw — status line, tail only on failure.
    local out; out="$("$@" 2>&1)" || rc=$?
    if [[ "$rc" -eq 0 ]]; then printf '%b  ✓ done (%ds)%b\n' "$GY" "$((SECONDS - start))" "$OFF"
    else printf '%s\n' "$out" | tail -n "$GLANCE_MAX" >&2; printf '%b  ✗ failed (exit %d)%b\n' "$ER" "$rc" "$OFF"; fi
    return "$rc"
  fi

  # quiet + TTY: gray glance of the last GLANCE_MAX lines, redrawn in place beneath the title.
  local rcfile width line printed=0
  rcfile="$(mktemp 2>/dev/null)" || rcfile=""
  width="${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}"
  [[ "$width" =~ ^[0-9]+$ && "$width" -ge 24 ]] || width=100
  local -a ring=()
  # tr '\r' '\n' turns carriage-return progress updates (curl/apt) into discrete lines so the
  # glance shows live progress; $? of the command is stashed in rcfile, off the display pipe.
  while IFS= read -r line; do
    line="${line//$'\t'/    }"
    [[ -z "${line//[[:space:]]/}" ]] && continue          # skip blank lines
    line="${line:0:$((width - 6))}"
    ring+=("$line")
    [[ "${#ring[@]}" -gt "$GLANCE_MAX" ]] && ring=("${ring[@]:1}")
    [[ "$printed" -gt 0 ]] && printf '\033[%dA' "$printed" # cursor up over the old block
    printed=0
    for i in "${ring[@]}"; do
      printf '\033[2K%b   │ %s%b\n' "$GY" "$i" "$OFF"      # clear line, gray, reprint
      printed=$((printed + 1))
    done
  done < <( { "$@" 2>&1; printf '%s' "$?" > "${rcfile:-/dev/null}"; } | tr '\r' '\n' )
  rc=0; [[ -n "$rcfile" ]] && { rc="$(cat "$rcfile" 2>/dev/null || echo 1)"; rm -f "$rcfile"; }
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=1

  if [[ "$rc" -eq 0 ]]; then
    # success → restamp the title with ✓ + elapsed, then collapse the gray glance away.
    printf '\033[%dA' "$((printed + 1))"
    printf '\033[2K%b✓%b %b%s%b %b(%ds)%b\n' "$OK" "$OFF" "$TI" "$title" "$OFF" "$GY" "$((SECONDS - start))" "$OFF"
    if [[ "$printed" -gt 0 ]]; then
      for ((i = 0; i < printed; i++)); do printf '\033[2K\n'; done
      printf '\033[%dA' "$printed"
    fi
  else
    # failure → restamp the title with ✗ but KEEP the gray glance (the error tail) on screen.
    printf '\033[%dA' "$((printed + 1))"
    printf '\033[2K%b✗%b %b%s%b %b(exit %d)%b\n' "$ER" "$OFF" "$TI" "$title" "$OFF" "$GY" "$rc" "$OFF"
    [[ "$printed" -gt 0 ]] && printf '\033[%dB' "$printed"
  fi
  return "$rc"
}

# ── host tooling prerequisites ─────────────────────────────────────────────────
# Ensure the `ngrok` CLI is installed. A third-party phase (run.sh Phase 4,
# a product hook — see .superset/products/example.sh) may tunnel a local port through
# ngrok so an external callback reaches this machine. Best-effort + idempotent: present → no-op; otherwise
# install per OS. NEVER fatal to setup — a missing ngrok only breaks that one optional
# phase (which already warns and carries on). macOS bash 3.2 safe.
ensure_ngrok() {
  if command -v ngrok >/dev/null 2>&1; then
    log "ngrok already installed ($(ngrok version 2>/dev/null | head -1))."
    return 0
  fi
  log "ngrok not found — installing…"
  case "$(uname -s)" in
    Darwin)
      # Homebrew is the canonical macOS install (brew is already assumed — setup needs
      # `mani` via brew). Fall back to the static binary if brew is somehow absent.
      if command -v brew >/dev/null 2>&1; then
        run_glance "ngrok: brew install" brew install ngrok \
          || run_glance "ngrok: brew install (tap)" brew install ngrok/ngrok/ngrok \
          || { warn "brew install ngrok failed — falling back to the static binary."; install_ngrok_tarball; }
      else
        warn "Homebrew not found on macOS — falling back to the static ngrok binary."
        install_ngrok_tarball
      fi
      ;;
    Linux)
      # Debian/Ubuntu: the official ngrok apt repo (needs root/sudo). Anything else, or
      # apt/root missing: the static binary tarball into /usr/local/bin (or ~/.local/bin).
      if command -v apt-get >/dev/null 2>&1; then
        install_ngrok_apt || install_ngrok_tarball
      else
        install_ngrok_tarball
      fi
      ;;
    *)
      warn "unsupported OS '$(uname -s)' for ngrok auto-install — install it by hand: https://ngrok.com/download"
      ;;
  esac
  if command -v ngrok >/dev/null 2>&1; then
    log "ngrok installed ($(ngrok version 2>/dev/null | head -1))."
  else
    warn "ngrok still not on PATH after install — the third-party phase (run.sh Phase 4) will be skipped. Install it by hand: https://ngrok.com/download"
  fi
  return 0
}

# Install ngrok via the official apt repo (Debian/Ubuntu). Returns non-zero (so the caller
# can fall back to the tarball) when root/sudo is unavailable or any apt step fails.
install_ngrok_apt() {
  local SUDO=""
  if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
      warn "ngrok: apt install needs root and 'sudo' is unavailable — trying the static binary."
      return 1
    fi
  fi
  # Prime sudo's credential cache OUTSIDE the glance, so its password prompt isn't tangled in
  # the in-place redraw and the apt steps below then run non-interactively.
  if [[ -n "$SUDO" ]]; then $SUDO -v || { warn "ngrok: sudo authentication failed."; return 1; }; fi
  log "ngrok: adding the official apt repo…"
  if ! { curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
            | $SUDO tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null \
         && echo "deb https://ngrok-agent.s3.amazonaws.com buster main" \
            | $SUDO tee /etc/apt/sources.list.d/ngrok.list >/dev/null; }; then
    warn "ngrok: could not add the apt repo."; return 1
  fi
  run_glance "ngrok: apt-get update"        $SUDO apt-get update         || { warn "ngrok: apt-get update failed."; return 1; }
  run_glance "ngrok: apt-get install ngrok" $SUDO apt-get install -y ngrok || return 1
}

# Install ngrok from the official static binary tarball — the cross-distro fallback (and the
# no-Homebrew macOS path). Installs onto PATH: /usr/local/bin when writable or via sudo, else
# ~/.local/bin. Returns non-zero on any failure so ensure_ngrok's final PATH check warns.
install_ngrok_tarball() {
  local os arch url tmp rc=0
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *) warn "ngrok: no static build for '$(uname -s)'."; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l|armv6l) arch=arm ;;
    *) warn "ngrok: unknown CPU arch '$(uname -m)' — install by hand: https://ngrok.com/download"; return 1 ;;
  esac
  url="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-${os}-${arch}.tgz"
  tmp="$(mktemp -d 2>/dev/null)" || { warn "ngrok: mktemp failed."; return 1; }
  if ! run_glance "ngrok: downloading the static binary" curl -fL --progress-bar "$url" -o "$tmp/ngrok.tgz" \
     || ! tar -xzf "$tmp/ngrok.tgz" -C "$tmp"; then
    warn "ngrok: download/extract failed — install by hand: https://ngrok.com/download"
    rm -rf "$tmp"; return 1
  fi
  if [[ -w /usr/local/bin ]]; then
    install -m 0755 "$tmp/ngrok" /usr/local/bin/ngrok || rc=$?
  elif command -v sudo >/dev/null 2>&1; then
    sudo install -m 0755 "$tmp/ngrok" /usr/local/bin/ngrok || rc=$?
  else
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$tmp/ngrok" "$HOME/.local/bin/ngrok" || rc=$?
    [[ ":$PATH:" == *":$HOME/.local/bin:"* ]] \
      || warn "ngrok installed to ~/.local/bin, which is not on PATH — add it (e.g. export PATH=\"\$HOME/.local/bin:\$PATH\")."
  fi
  rm -rf "$tmp"
  [[ "$rc" -eq 0 ]] || { warn "ngrok: install step failed (exit $rc)."; return 1; }
  return 0
}

# Ensure the `glab` CLI (GitLab CLI) is installed. The GitLab VCS adapter (scripts/vcs/, used
# for MR/PR ops since vcs.provider is gitlab) drives glab. Best-effort + idempotent: present →
# no-op; otherwise install. NEVER fatal to setup. See https://gitlab.com/gitlab-org/cli/#installation.
# macOS bash 3.2 safe.
ensure_glab() {
  if command -v glab >/dev/null 2>&1; then
    log "glab already installed ($(glab --version 2>/dev/null | head -1))."
    return 0
  fi
  log "glab not found — installing…"
  case "$(uname -s)" in
    Darwin|Linux)
      # Homebrew is glab's canonical cross-platform install (brew is already assumed — setup
      # needs `mani` via brew). Fall back to the official GitLab release tarball if brew is
      # absent or the formula install fails.
      if command -v brew >/dev/null 2>&1; then
        run_glance "glab: brew install" brew install glab \
          || { warn "brew install glab failed — falling back to the release tarball."; install_glab_tarball; }
      else
        warn "Homebrew not found — falling back to the official glab release tarball."
        install_glab_tarball
      fi
      ;;
    *)
      warn "unsupported OS '$(uname -s)' for glab auto-install — install it by hand: https://gitlab.com/gitlab-org/cli/#installation"
      ;;
  esac
  if command -v glab >/dev/null 2>&1; then
    log "glab installed ($(glab --version 2>/dev/null | head -1))."
  else
    warn "glab still not on PATH after install — the GitLab VCS adapter (scripts/vcs/) needs it. Install it by hand: https://gitlab.com/gitlab-org/cli/#installation"
  fi
  return 0
}

# Install glab from the official GitLab release tarball — the cross-distro fallback (and the
# no-Homebrew macOS path). Resolves the latest version from the GitLab API, downloads the
# os/arch tarball (binary at bin/glab), and installs onto PATH: /usr/local/bin when writable
# or via sudo, else ~/.local/bin. Returns non-zero on any failure so ensure_glab's check warns.
install_glab_tarball() {
  local os arch ver url tmp bin rc=0
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *) warn "glab: no release build for '$(uname -s)'."; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) warn "glab: unknown CPU arch '$(uname -m)' — install by hand: https://gitlab.com/gitlab-org/cli/#installation"; return 1 ;;
  esac
  # Resolve the latest release tag from the GitLab API (e.g. "v1.105.0" → "1.105.0").
  ver="$(curl -fsSL "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/permalink/latest" 2>/dev/null \
    | grep -o '"tag_name":"[^"]*"' | head -1 | sed 's/.*:"v\{0,1\}//; s/"//')"
  if [[ -z "$ver" ]]; then warn "glab: could not resolve the latest release version."; return 1; fi
  url="https://gitlab.com/gitlab-org/cli/-/releases/v${ver}/downloads/glab_${ver}_${os}_${arch}.tar.gz"
  tmp="$(mktemp -d 2>/dev/null)" || { warn "glab: mktemp failed."; return 1; }
  if ! run_glance "glab: downloading v${ver}" curl -fL --progress-bar "$url" -o "$tmp/glab.tar.gz" \
     || ! tar -xzf "$tmp/glab.tar.gz" -C "$tmp"; then
    warn "glab: download/extract failed — install by hand: https://gitlab.com/gitlab-org/cli/#installation"
    rm -rf "$tmp"; return 1
  fi
  # The tarball lays the binary at bin/glab; find it as a safety net if that ever changes.
  bin="$tmp/bin/glab"
  [[ -f "$bin" ]] || bin="$(find "$tmp" -type f -name glab 2>/dev/null | head -1)"
  if [[ -z "$bin" || ! -f "$bin" ]]; then warn "glab: binary not found in the tarball."; rm -rf "$tmp"; return 1; fi
  if [[ -w /usr/local/bin ]]; then
    install -m 0755 "$bin" /usr/local/bin/glab || rc=$?
  elif command -v sudo >/dev/null 2>&1; then
    sudo install -m 0755 "$bin" /usr/local/bin/glab || rc=$?
  else
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$bin" "$HOME/.local/bin/glab" || rc=$?
    [[ ":$PATH:" == *":$HOME/.local/bin:"* ]] \
      || warn "glab installed to ~/.local/bin, which is not on PATH — add it (e.g. export PATH=\"\$HOME/.local/bin:\$PATH\")."
  fi
  rm -rf "$tmp"
  [[ "$rc" -eq 0 ]] || { warn "glab: install step failed (exit $rc)."; return 1; }
  return 0
}

# Ensure the `jq` CLI is installed. aiworks itself (the .code-workspace generation and the
# VS Code search-settings merge) and the tracker/notify adapters all drive jq. Best-effort +
# idempotent: present → no-op; otherwise install per OS. NEVER fatal to setup — the steps
# that need jq each warn and carry on. macOS bash 3.2 safe.
ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    log "jq already installed ($(jq --version 2>/dev/null))."
    return 0
  fi
  log "jq not found — installing…"
  case "$(uname -s)" in
    Darwin)
      # Homebrew is the canonical macOS install (brew is already assumed — setup needs
      # `mani` via brew). Fall back to the official static binary if brew is absent.
      if command -v brew >/dev/null 2>&1; then
        run_glance "jq: brew install" brew install jq \
          || { warn "brew install jq failed — falling back to the static binary."; install_jq_binary; }
      else
        warn "Homebrew not found on macOS — falling back to the static jq binary."
        install_jq_binary
      fi
      ;;
    Linux)
      # Debian/Ubuntu: jq ships in the standard repos (needs root/sudo). Anything else, or
      # apt/root missing: the official static binary into /usr/local/bin (or ~/.local/bin).
      if command -v apt-get >/dev/null 2>&1; then
        install_jq_apt || install_jq_binary
      else
        install_jq_binary
      fi
      ;;
    *)
      warn "unsupported OS '$(uname -s)' for jq auto-install — install it by hand: https://jqlang.org/download/"
      ;;
  esac
  if command -v jq >/dev/null 2>&1; then
    log "jq installed ($(jq --version 2>/dev/null))."
  else
    warn "jq still not on PATH after install — aiworks (.code-workspace generation, VS Code settings merge) and the tracker adapter need it. Install it by hand: https://jqlang.org/download/"
  fi
  return 0
}

# Install jq from the standard apt repos (Debian/Ubuntu). Returns non-zero (so the caller
# can fall back to the static binary) when root/sudo is unavailable or any apt step fails.
install_jq_apt() {
  local SUDO=""
  if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
      warn "jq: apt install needs root and 'sudo' is unavailable — trying the static binary."
      return 1
    fi
  fi
  # Prime sudo's credential cache OUTSIDE the glance, so its password prompt isn't tangled in
  # the in-place redraw and the apt steps below then run non-interactively.
  if [[ -n "$SUDO" ]]; then $SUDO -v || { warn "jq: sudo authentication failed."; return 1; }; fi
  run_glance "jq: apt-get install jq" $SUDO apt-get install -y jq || return 1
}

# Install jq from the official static binary (github.com/jqlang/jq releases) — the
# cross-distro fallback (and the no-Homebrew macOS path). Installs onto PATH:
# /usr/local/bin when writable or via sudo, else ~/.local/bin. Returns non-zero on any
# failure so ensure_jq's final PATH check warns.
install_jq_binary() {
  local os arch url tmp rc=0
  case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    *) warn "jq: no static build for '$(uname -s)'."; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) warn "jq: unknown CPU arch '$(uname -m)' — install by hand: https://jqlang.org/download/"; return 1 ;;
  esac
  url="https://github.com/jqlang/jq/releases/latest/download/jq-${os}-${arch}"
  tmp="$(mktemp -d 2>/dev/null)" || { warn "jq: mktemp failed."; return 1; }
  if ! run_glance "jq: downloading the static binary" curl -fL --progress-bar "$url" -o "$tmp/jq"; then
    warn "jq: download failed — install by hand: https://jqlang.org/download/"
    rm -rf "$tmp"; return 1
  fi
  if [[ -w /usr/local/bin ]]; then
    install -m 0755 "$tmp/jq" /usr/local/bin/jq || rc=$?
  elif command -v sudo >/dev/null 2>&1; then
    sudo install -m 0755 "$tmp/jq" /usr/local/bin/jq || rc=$?
  else
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$tmp/jq" "$HOME/.local/bin/jq" || rc=$?
    [[ ":$PATH:" == *":$HOME/.local/bin:"* ]] \
      || warn "jq installed to ~/.local/bin, which is not on PATH — add it (e.g. export PATH=\"\$HOME/.local/bin:\$PATH\")."
  fi
  rm -rf "$tmp"
  [[ "$rc" -eq 0 ]] || { warn "jq: install step failed (exit $rc)."; return 1; }
  return 0
}

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

# Install node deps for one repo (skips repos without package.json). BEST-EFFORT: a single
# repo's install hiccup must NEVER abort the whole multi-repo setup (setup.sh runs under
# `set -e`), so every path returns 0 and surfaces a warn instead of propagating a failure.
node_install() {  # <repo>
  local repo="$1" pm rc=0
  [[ -f "$repo/package.json" ]] || return 0
  pm="$(node_pm "$repo")"
  if ! command -v "$pm" >/dev/null 2>&1; then
    warn "$repo: '$pm' not installed — skipping dependency install."
    return 0
  fi
  log "$repo: $pm install"

  if [[ "$pm" == pnpm ]]; then
    # pnpm 10+ does NOT run dependencies' build scripts by default and EXITS NON-ZERO with
    # ERR_PNPM_IGNORED_BUILDS when some were skipped — even though the install itself SUCCEEDED.
    # Under `set -e` that lone non-zero aborts the entire setup. The deps are installed; we just
    # need to let the (first-party, repo-declared) build scripts run: `pnpm approve-builds --all`
    # is pnpm's own non-interactive remedy (records the approval in pnpm-workspace.yaml + runs
    # the scripts). We then re-run install to CONFIRM green, so a GENUINE failure still surfaces.
    (cd "$repo" && pnpm install) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      warn "$repo: pnpm install exited $rc (likely skipped build scripts) — approving them: pnpm approve-builds --all"
      (cd "$repo" && pnpm approve-builds --all) || true
      if ! (cd "$repo" && pnpm install); then
        warn "$repo: pnpm install STILL failing after approving builds — continuing setup; resolve $repo's deps by hand (cd $repo && pnpm install)."
      fi
    fi
    return 0
  fi

  # npm: a strict install can fail on legacy peer-dep ranges (e.g. cypress plugin peer ranges) — retry once.
  if ! (cd "$repo" && npm install); then
    warn "$repo: npm install failed — retrying with --legacy-peer-deps."
    (cd "$repo" && npm install --legacy-peer-deps) \
      || warn "$repo: npm install STILL failing — continuing setup; resolve $repo's deps by hand (cd $repo && npm install)."
  fi
  return 0
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
# (e.g. an ngrok tunnel a third-party-setup hook starts). No pidfile → nothing to do, so a
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
# Emits one PLAIN progress line per poll (elapsed + attempt count) — call it
# through run_glance (as Phase 5 does) so the poll lines become the live gray
# glance under a titled section instead of raw chatter.
wait_for_http() {  # <url> [tries] [sleep-secs] [label]
  local url="$1" tries="${2:-60}" nap="${3:-5}" label="${4:-$1}" code
  local total="$tries" start="$SECONDS"
  while :; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"
    if [[ -n "$code" && "$code" != "000" ]]; then
      printf '%s is up (HTTP %s, after %ds).\n' "$label" "$code" "$((SECONDS - start))"
      return 0
    fi
    tries=$((tries - 1))
    if [[ "$tries" -le 0 ]]; then
      err "$label did not answer after the wait window: $url"
      return 1
    fi
    printf 'no answer yet from %s — %ds elapsed (poll %d/%d, next in %ds)\n' \
      "$label" "$((SECONDS - start))" "$((total - tries))" "$total" "$nap"
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

# Resolve the default product: exactly ONE real product file in .superset/products/
# (example.sh is the shipped template, never a runnable default). Zero or several →
# fail with guidance, so orchestrators never guess an org's stack.
default_product() {
  local files=() f
  for f in .superset/products/*.sh; do
    [[ -e "$f" && "$(basename "$f")" != "example.sh" ]] && files+=("$f")
  done
  if [[ ${#files[@]} -eq 1 ]]; then
    basename "${files[0]}" .sh
    return 0
  fi
  if [[ ${#files[@]} -eq 0 ]]; then
    err "no product defined — copy .superset/products/example.sh to .superset/products/<product-id>.sh first."
  else
    err "several products defined — name one:"
    for f in "${files[@]}"; do basename "$f" .sh | sed 's/^/  - /' >&2; done
  fi
  return 1
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
