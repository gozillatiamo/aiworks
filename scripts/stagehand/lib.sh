#!/usr/bin/env bash
#
# stagehand — shared library: gates, config, state, geometry helpers.
#
# WHAT STAGEHAND IS: every tool call the assistant makes also puts the thing it just touched
# ON SCREEN — an edited file in Cursor, a fetched URL in a browser tab — placed in whatever
# screen space is actually free, on whatever display, without stealing keyboard focus.
#
# WHY NOT `computer-use`: Claude Code's built-in computer-use MCP server is the obvious-looking
# answer and is the WRONG engine for this, for four reasons measured against its own docs
# (code.claude.com/docs/en/computer-use):
#   1. it HIDES every other visible app while it works and restores them at end of turn — the
#      exact opposite of "spread live previews across three displays";
#   2. it holds a machine-wide lock until the session EXITS, so a second Claude Code session
#      (a Superset worktree, say) cannot use the machine at all;
#   3. its permission tiers make the two headline asks impossible anyway — browsers are
#      view-only (cannot be told to open a URL) and IDEs are click-only (cannot be told to open
#      a file);
#   4. it screenshots into the model on every action, so "on EVERY tool call" multiplies cost.
# Plus it requires a Pro/Max plan and is not offered on Team/Enterprise, which is what this org
# is on — the server does not even appear in `/mcp` here. So stagehand is deterministic shell:
# `open`, the `cursor` CLI, and AX window placement. No lock, no hiding, no screenshots, no plan
# tier, and it works on every turn including ones the model never thinks about.
#
# ROOT WORKTREE ONLY — the hard scope rule. A Superset worktree runs its own Claude Code session
# against the same physical screen; two sessions racing to place windows would fight over the
# same display space and neither could win. The root/main checkout owns the screen. The gate is
# mechanical, never guessed: `git rev-parse --git-common-dir` points at <main>/.git from inside a
# linked worktree, so STAGE_MAIN_CLONE is non-empty there and empty here. Belt and braces on top:
# SUPERSET_ROOT_PATH must be unset, and .git must be a DIRECTORY (a linked worktree's is a file).
#
# CONFIG — personal-first, exactly like the voice adapter (docs/adr/0003):
#   1. workspace.config.local.yaml        (this checkout; git-ignored, personal)
#   2. <main clone>/workspace.config.local.yaml
#   3. workspace.config.yaml              (committed; ships stagehand.enabled: false)
# The shared file ships the feature OFF, so a teammate who pulls this gets nothing until they
# opt in on their own machine. Every gate failure is exit 0 and silent — a window placer must
# never be the reason a tool call reports failure.
#
# Reads no credentials. Touches no .env. Do not add one.

set -euo pipefail

STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE_ROOT="$(cd "$STAGE_DIR/../.." && pwd)"

# The main clone behind a linked worktree, else empty. Empty means "this IS the main checkout".
stage_main_clone() {
  local common
  command -v git >/dev/null 2>&1 || return 0
  common="$(git -C "$STAGE_ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 0
  [[ -n "$common" ]] || return 0
  case "$common" in
    /*) ;;
    *) common="$STAGE_ROOT/$common" ;;
  esac
  local main; main="$(cd "$(dirname "$common")" 2>/dev/null && pwd)" || return 0
  [[ "$main" != "$STAGE_ROOT" ]] && printf '%s' "$main"
  return 0
}
STAGE_MAIN_CLONE="$(stage_main_clone || true)"

export STAGE_VERBOSE="${STAGE_VERBOSE:-0}"
slog() { [[ "$STAGE_VERBOSE" == "1" ]] && printf 'stagehand: %s\n' "$*" >&2 || true; }

# ── config ────────────────────────────────────────────────────────────────────────
# Block-style YAML only (2-space indent), same parser shape as scripts/voice/lib.sh. Prints
# nothing for an absent path so the caller can tell "absent" from "false" and fall through.
_stage_yaml_get() {
  local f="$1" want="$2"
  [[ -f "$f" ]] || return 0
  awk -v want="$want" '
    function val(s){ sub(/^[^:]*:[ \t]*/,"",s); sub(/[ \t]+#.*$/,"",s);
                     gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
    /^[ \t]*(#|$)/  { next }
    /^[ \t]*-/      { next }
    {
      ind = match($0, /[^ ]/) - 1
      rest = substr($0, ind + 1)
      if (rest !~ /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:/) next
      key = rest; sub(/[ \t]*:.*/, "", key)
      d = int(ind / 2)
      stack[d] = key
      for (i = d + 1; i <= 20; i++) stack[i] = ""
      p = stack[0]
      for (i = 1; i <= d; i++) p = p "." stack[i]
      if (p == want) { v = val(rest); if (v != "") { print v; exit } }
    }
  ' "$f"
}

stage_cfg() {
  local want="$1" def="${2:-}" f v
  for f in \
    "$STAGE_ROOT/workspace.config.local.yaml" \
    ${STAGE_MAIN_CLONE:+"$STAGE_MAIN_CLONE/workspace.config.local.yaml"} \
    "$STAGE_ROOT/workspace.config.yaml"
  do
    v="$(_stage_yaml_get "$f" "$want")"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  done
  printf '%s' "$def"
}

stage_cfg_bool() {
  case "$(stage_cfg "$1" "${2:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1|on) return 0 ;; *) return 1 ;;
  esac
}

# Clamped, for the same reason voice clamps: these are seconds and counts that decide how often
# windows move and how many tabs pile up. A typo'd 0 or 900 should not be reachable.
stage_cfg_int() {
  local v; v="$(stage_cfg "$1" "$2")"
  [[ "$v" =~ ^-?[0-9]+$ ]] || { slog "cfg $1: '$v' not a number — using $2"; v="$2"; }
  if [[ -n "${3:-}" ]] && (( v < $3 )); then v="$3"; fi
  if [[ -n "${4:-}" ]] && (( v > $4 )); then v="$4"; fi
  printf '%s' "$v"
}

# ── the gate ──────────────────────────────────────────────────────────────────────
# Every reason to stay quiet, in one place, cheapest check first. Silent exit 0 throughout.
# STAGEHAND=off silences everything for one command; STAGEHAND=on forces the config switch ON for one
# command. `on` exists so the feature can be tried, and its selftest can RUN, without first editing a
# personal config file — a test suite that only passes on a machine where someone already opted in is
# not a test suite a reviewer can use. It does NOT bypass the other gates: macOS and the
# root-worktree rule still apply, because those protect correctness rather than preference.
stage_gate_or_exit() {
  [[ "${STAGEHAND:-}" == "off" ]] && { slog "STAGEHAND=off"; exit 0; }
  [[ "$(uname -s)" == "Darwin" ]] || { slog "not macOS"; exit 0; }

  # Root worktree only — three independent proofs, all mechanical.
  [[ -z "$STAGE_MAIN_CLONE" ]]        || { slog "linked worktree (main=$STAGE_MAIN_CLONE)"; exit 0; }
  [[ -z "${SUPERSET_ROOT_PATH:-}" ]]  || { slog "under Superset"; exit 0; }
  [[ -d "$STAGE_ROOT/.git" ]]         || { slog ".git is not a directory"; exit 0; }

  if [[ "${STAGEHAND:-}" != "on" ]]; then
    stage_cfg_bool stagehand.enabled false || { slog "stagehand.enabled is false"; exit 0; }
  fi
  [[ "$(stage_cfg stagehand.placement halves)" != "off" ]] || { slog "placement: off"; exit 0; }
  return 0
}

# ── state ─────────────────────────────────────────────────────────────────────────
# Per-checkout, outside the repo: debounce stamps, the browser window id, the tab ring.
STAGE_STATE_DIR="${STAGE_STATE_DIR:-${TMPDIR:-/tmp}/stagehand-$(printf '%s' "$STAGE_ROOT" | shasum -a 256 | cut -c1-12)}"
stage_mkdirs() { mkdir -p "$STAGE_STATE_DIR" 2>/dev/null || true; }

stage_sha() { printf '%s' "$1" | shasum -a 256 | cut -c1-40; }
stage_now() { date +%s; }

# stage_debounce <key> — 0 (go ahead) when this target has not been shown within the window.
# Why: a single Edit fires one hook, but a multi-hunk refactor fires a dozen on the same file
# within a second. Without this the window would be re-placed a dozen times and visibly jitter.
stage_debounce() {
  local key win stamp now last
  key="$STAGE_STATE_DIR/db-$(stage_sha "$1")"
  win="$(stage_cfg_int stagehand.debounce_seconds 2 0 120)"
  now="$(stage_now)"
  last="$(cat "$key" 2>/dev/null || printf 0)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - last < win )); then slog "debounced: $1"; return 1; fi
  printf '%s' "$now" > "$key" 2>/dev/null || true
  return 0
}

# ── which display each ROLE last used ─────────────────────────────────────────────
# The spread objective needs memory: to keep the editor and the browser on different screens, a
# placement has to know where the OTHER one already is. Storing the display index per role is enough
# and is stable across runs, which matters because each placement is a separate short-lived process.
# Stored as "<display>:<half-name>" — the SLOT, not just the display. A display index alone was enough
# while the scorer picked from nine differently-shaped slots, but with two halves per display the thing
# a sibling occupies is a specific half, and that is what the next role has to steer around.
stage_role_slot_set() { printf '%s' "${2:-}" > "$STAGE_STATE_DIR/disp-$1" 2>/dev/null || true; }

# stage_sibling_slots <role> → comma-separated "<display>:<half>" owned by every OTHER role
stage_sibling_slots() {
  local me="$1" out="" f r v
  for f in "$STAGE_STATE_DIR"/disp-*; do
    [[ -e "$f" ]] || continue
    r="$(basename "$f")"; r="${r#disp-}"
    [[ "$r" == "$me" ]] && continue
    v="$(cat "$f" 2>/dev/null)"
    [[ "$v" =~ ^[0-9]+:[a-z-]+$ ]] || continue
    case ",$out," in *",$v,"*) continue ;; esac
    out="${out:+$out,}$v"
  done
  printf '%s' "$out"
}

# ── browser profile ───────────────────────────────────────────────────────────────
# Which Chrome PROFILE the tabs open in. This is a correctness problem, not a preference: a work
# Jira/GitLab URL opened in a personal profile lands on a login wall, so stagehand showed
# "Log in to continue" instead of the ticket. Chrome's `make new window` uses the LAST-USED
# profile, which is whatever the human last clicked — not something to leave to chance.
#
# Resolved by ACCOUNT EMAIL, not by directory name: the directory names ("Default", "Profile 1")
# are assigned in the order profiles were created on that machine and mean nothing portable —
# here the work account is "Default" and the personal one is "Profile 1", which is the reverse of
# what the names suggest. The mapping lives in Chrome's own `Local State` (profile metadata; no
# tokens, no passwords). stagehand.browser_profile stays as a raw-directory escape hatch.
_stage_chrome_local_state="$HOME/Library/Application Support/Google/Chrome/Local State"

# stage_chrome_profile → the profile DIRECTORY for stagehand.browser_account ("" when unresolved)
stage_chrome_profile() {
  local want; want="$(stage_cfg stagehand.browser_account)"
  if [[ -z "$want" ]]; then stage_cfg stagehand.browser_profile; return 0; fi
  [[ -f "$_stage_chrome_local_state" ]] || { stage_cfg stagehand.browser_profile; return 0; }
  python3 - "$_stage_chrome_local_state" "$want" <<'PY' 2>/dev/null
import json, sys
try:
    cache = (json.load(open(sys.argv[1])).get('profile') or {}).get('info_cache') or {}
except Exception:
    sys.exit(0)
want = sys.argv[2].strip().lower()
for d, info in cache.items():
    if (info.get('user_name') or '').strip().lower() == want:
        print(d); break
PY
}

# stage_chrome_profile_name → that profile's DISPLAY name, which Chrome appends to every window
# title ("… - Google Chrome - You (work-account)"). That is the only way to tell from the
# outside which profile an existing window belongs to — Chrome's AppleScript dictionary exposes no
# profile property at all — so it is how a remembered window is checked before being reused.
stage_chrome_profile_name() {
  local want; want="$(stage_cfg stagehand.browser_account)"
  [[ -n "$want" && -f "$_stage_chrome_local_state" ]] || return 0
  python3 - "$_stage_chrome_local_state" "$want" <<'PY' 2>/dev/null
import json, sys
try:
    cache = (json.load(open(sys.argv[1])).get('profile') or {}).get('info_cache') or {}
except Exception:
    sys.exit(0)
want = sys.argv[2].strip().lower()
for d, info in cache.items():
    if (info.get('user_name') or '').strip().lower() == want:
        print(info.get('name') or ''); break
PY
}

# stage_chrome_js_ok — 0 when Chrome will run JavaScript sent over Apple Events.
#
# OFF by default in Chrome, and deliberately never turned on from here: with it on, ANY AppleScript
# on the machine can execute JavaScript in any of the user's logged-in tabs. That is a security
# decision for the person at the keyboard. Probed once per state dir and cached, because the probe
# costs an AppleScript round trip and the answer only changes when a human flips a menu item.
# The cache is ASYMMETRIC on purpose. "Off" is re-probed after a short TTL, because the moment someone
# ticks the box they expect the feature to start working; a permanently cached "off" meant enabling it
# changed nothing until the state dir was deleted by hand — a footgun, not a cache.
#
# "On" used to be cached indefinitely on the reasoning that only a human can untick the menu item. That
# was wrong in practice and was caught with the cache file in hand: it held "1", written minutes
# earlier, while the real call came back "Executing JavaScript through AppleScript is turned off". So a
# stale "on" is possible, and stage_chrome_js_invalidate below exists for the caller to say so the
# moment a real call proves it.
#
# PROBE THE WINDOW THE CALL WILL USE. Passing no id probes `window 1`, i.e. whichever Chrome window is
# frontmost — which is not necessarily the window the caller is about to script. Probing one window and
# then scripting another is unsound on its face, and it is the leading suspect for the mismatch above
# (Chrome had not restarted between the two — verified from its process start time — so the toggle
# either differs per window/profile or was changed by hand).
stage_chrome_js_ok() {
  local win="${1:-}" c="$STAGE_STATE_DIR/chrome-js" ttl=300 age
  if [[ -f "$c" ]]; then
    if [[ "$(cat "$c" 2>/dev/null)" == "1" ]]; then return 0; fi
    age=$(( $(stage_now) - $(stat -f %m "$c" 2>/dev/null || printf 0) ))
    (( age < ttl )) && return 1
  fi
  local target="window 1"
  [[ -n "$win" ]] && target="window id $win"
  local out
  out="$(osascript -e "tell application \"Google Chrome\" to execute (active tab of $target) javascript \"1\"" 2>&1)"
  if [[ "$out" == *"turned off"* || "$out" == *"error"* ]]; then
    printf '0' > "$c" 2>/dev/null; return 1
  fi
  printf '1' > "$c" 2>/dev/null; return 0
}

# Forget a cached "on" — call this when a real execute proves the capability is gone, so the next run
# re-probes instead of failing again on stale state.
stage_chrome_js_invalidate() { rm -f "$STAGE_STATE_DIR/chrome-js" 2>/dev/null || true; }

# ── geometry ──────────────────────────────────────────────────────────────────────
# Rectangle's own gap, so a stagehand-placed window sits on the same grid as one the user
# snapped by hand. Unset in Rectangle means no gaps, which is this machine's setting.
stage_gap() {
  local g
  g="$(defaults read com.knollsoft.Rectangle gapSize 2>/dev/null || printf '')"
  [[ "$g" =~ ^[0-9]+$ ]] || g=0
  printf '%s' "$g"
}
