#!/usr/bin/env bash
#
# triage-mcp.sh — reconcile the read-only deployed-env triage MCP servers with the workspace's
# `triage` policy, and migrate the pre-0005 `prod_*` registrations away.
#
#   pg_triage          scripts/db/pg_triage_mcp.py                 read-only staging + prod Postgres (MAD + 16 shards)
#   redis_triage       scripts/redis/redis_triage_mcp.py           read-only staging + prod Redis + Streams
#   k8s_triage         scripts/k8s/k8s_triage_mcp.py               read-only staging + prod Kubernetes
#   monitoring_triage  scripts/monitoring/monitoring_triage_mcp.py read-only staging + prod Cloud Monitoring
#
# All four are registered in each selected Harness's **machine-local scope** (`~/.claude.json`,
# `~/.codex/config.toml`, or `~/.cursor/mcp.json`), never in committed `.mcp.json`, so prod
# credentials never enter the shared repo. Registration commands contain paths only; servers read
# their own protected local configuration at runtime.
#
# Registration is ON by default, because STAGING triage needs no authorization and a flag you have
# to flip before you can look at staging is friction with no payer. PRODUCTION is the part that
# needs an opt-in, and that opt-in is enforced INSIDE the servers (scripts/lib/triage_policy.py)
# rather than by withholding the server — a registration-time gate freezes into ~/.claude.json and
# drifts from the config that claims to own it. See docs/adr/0005.
#
#   triage:
#     enabled: true    # registration; set false to keep both servers out of every session
#     prod: false      # per-machine opt-in for PRODUCTION targets (read live by the servers)
#
# Both keys are read LOCAL-FIRST — workspace.config.local.yaml (git-ignored, personal) wins over
# workspace.config.yaml (shared) — because both are per-person decisions and what this writes is a
# per-person file. See docs/adr/0003.
#
# Usage:
#   scripts/triage-mcp.sh              # sync — reconcile registration with the policy
#   scripts/triage-mcp.sh on|off       # force registration, ignoring the policy (config untouched)
#   scripts/triage-mcp.sh status       # report policy + what is registered
#   scripts/triage-mcp.sh sync -n      # preview; change nothing
#
# RUN IT YOURSELF — `aiworks sync` does NOT (docs/adr/0009). Sync onboards repos; it does not
# reach into a deployed environment on your behalf, so it only REPORTS an unregistered server in
# its summary. `aiworks doctor` scores the same gap and `aiworks doctor --fix` runs this script.
# A machine that also wants production adds `triage.prod: true` — no re-registration needed.
set -uo pipefail

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()   { printf '    %s✓ %s%s\n' "$c_ok"   "$*" "$c_off"; }
warn() { printf '    %s! %s%s\n' "$c_warn" "$*" "$c_off"; }
die()  { printf '%serror: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
dim()  { printf '    %s%s%s\n'   "$c_dim"  "$*" "$c_off"; }

ACTION="sync"; DRY=0
for a in "$@"; do
  case "$a" in
    sync|on|off|status) ACTION="$a" ;;
    -n|--dry-run)       DRY=1 ;;
    -h|--help)          sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                  die "unknown argument: $a (use sync|on|off|status [-n])" ;;
  esac
done

# Workspace root: this script lives in <root>/scripts/.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$ROOT/workspace.config.yaml" ]] || die "workspace.config.yaml not found at $ROOT"

# The servers this script owns, as "<name>|<path relative to root>".
SERVERS=(
  "pg_triage|scripts/db/pg_triage_mcp.py"
  "redis_triage|scripts/redis/redis_triage_mcp.py"
  "k8s_triage|scripts/k8s/k8s_triage_mcp.py"
  "monitoring_triage|scripts/monitoring/monitoring_triage_mcp.py"
)

# Pre-0005 names + paths. Registered locally on machines that opted in before the rename; this
# script removes its OWN old entries so nobody is left running two servers over the same fleet.
# These four strings are HISTORICAL literals — they must keep naming the OLD server + file, so
# never sweep them along in a rename; they are what identifies an entry to clean up.
# (They were swept once, into the post-0005 names, which made `status` report every HEALTHY
# registration as a leftover and made `sync` deregister-then-reregister all three every run.)
LEGACY=(
  "prod_pg_triage|scripts/db/prod_pg_mcp.py"
  "prod_redis_triage|scripts/redis/prod_redis_mcp.py"
)

# ── policy ────────────────────────────────────────────────────────────────────────
# Read one `<section>.<key>` out of one YAML file. Prints nothing when the key is absent, so the
# caller can tell "absent" from "false" and fall through to the next file. This mirrors
# scripts/lib/triage_policy.py, which the servers use for the same two keys.
read_flag() {
  local f="$1" section="$2" key="$3"
  [[ -f "$f" ]] || return 0
  awk -v want_sec="$section" -v want_key="$key" '
    function val(s){ sub(/^[^:]*:[ \t]*/,"",s); sub(/[ \t]+#.*$/,"",s);
                     gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { sec=$0; sub(/:.*/,"",sec) }
    sec==want_sec && $0 ~ "^  "want_key":" { print tolower(val($0)); exit }
  ' "$f"
}

# Sets <VAR> + <VAR>_SRC for one policy key. Assigns rather than prints: a `$(…)` call would
# resolve the source in a subshell and lose it, which is what the status line needs to report.
resolve_key() {
  local section="$1" key="$2" default="$3" out_var="$4" v
  v="$(read_flag "$ROOT/workspace.config.local.yaml" "$section" "$key")"
  if [[ -n "$v" ]]; then
    printf -v "$out_var" '%s' "$v"
    printf -v "${out_var}_SRC" '%s' "workspace.config.local.yaml"
    return 0
  fi
  v="$(read_flag "$ROOT/workspace.config.yaml" "$section" "$key")"
  if [[ -n "$v" ]]; then
    printf -v "$out_var" '%s' "$v"
    printf -v "${out_var}_SRC" '%s' "workspace.config.yaml"
    return 0
  fi
  printf -v "$out_var" '%s' "$default"
  printf -v "${out_var}_SRC" '%s' "default ($section.$key absent)"
}

ENABLED=""; ENABLED_SRC=""; PROD=""; PROD_SRC=""
resolve_key triage enabled true  ENABLED
resolve_key triage prod    false PROD
case "$ENABLED" in true|yes|1|on) WANT=1 ;; *) WANT=0 ;; esac
case "$ACTION" in
  on)  WANT=1; ENABLED_SRC="--on (forced)" ;;
  off) WANT=0; ENABLED_SRC="--off (forced)" ;;
esac

# The removed key. Never honoured — that would let a stale file decide production access — but a
# machine still carrying it would otherwise silently lose prod, so say so loudly.
dead_key_file() {
  local f
  for f in "$ROOT/workspace.config.local.yaml" "$ROOT/workspace.config.yaml"; do
    if [[ -n "$(read_flag "$f" prod_triage enabled)" ]]; then basename "$f"; return 0; fi
  done
  return 0
}
DEAD_KEY="$(dead_key_file)"
dead_key_warning() {
  [[ -z "$DEAD_KEY" ]] && return 0
  warn "$DEAD_KEY still sets the REMOVED key 'prod_triage.enabled' — it is IGNORED. Rename it to 'triage.prod' or production stays off (docs/adr/0005)."
}

# ── registration state ────────────────────────────────────────────────────────────
CLAUDE_JSON="$HOME/.claude.json"

# The args of a locally-registered server, joined — empty when it is not registered. Read from
# ~/.claude.json rather than `claude mcp list`, whose output format is not a contract.
registered_args() {
  local name="$1"
  [[ -f "$CLAUDE_JSON" ]] || return 0
  jq -r --arg p "$ROOT" --arg n "$name" \
    '(.projects[$p].mcpServers[$n] // empty) | ((.command // "") + " " + ((.args // []) | join(" ")))' \
    "$CLAUDE_JSON" 2>/dev/null
}

expected_args() { printf 'uv run --quiet %s/%s' "$ROOT" "$1"; }

if [[ "$ACTION" == "status" ]]; then
  printf '  triage.enabled = %-5s (%s)\n' "$ENABLED" "$ENABLED_SRC"
  printf '  triage.prod    = %-5s (%s)   [enforced in-process by the servers]\n' "$PROD" "$PROD_SRC"
  dead_key_warning
  for entry in "${SERVERS[@]}"; do
    name="${entry%%|*}"; rel="${entry#*|}"
    have="$(registered_args "$name")"
    if [[ -z "$have" ]]; then dim "$name — not registered"
    elif [[ "$have" == "$(expected_args "$rel")" ]]; then ok "$name — registered (local scope)"
    else warn "$name — registered with a DIFFERENT command: $have"; fi
  done
  for entry in "${LEGACY[@]}"; do
    name="${entry%%|*}"
    if [[ -n "$(registered_args "$name")" ]]; then
      warn "$name — LEGACY registration still present; run 'scripts/triage-mcp.sh sync' to remove it"
    fi
  done
  python3 "$ROOT/scripts/harnesses/triage_mcp.py" --root "$ROOT" --action status --want "$WANT" 2>/dev/null || true
  exit 0
fi

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"
HARNESS_SET="$(python3 "$ROOT/scripts/harnesses/config.py" list --config "$ROOT/workspace.config.yaml" --registry "$ROOT/scripts/harnesses/registry.json" --fallback 2>/dev/null || printf 'claude\ncursor\n')"
CLAUDE_AVAILABLE=0
if printf '%s\n' "$HARNESS_SET" | grep -qx claude && command -v claude >/dev/null 2>&1; then
  CLAUDE_AVAILABLE=1
elif printf '%s\n' "$HARNESS_SET" | grep -qx claude; then
  warn "the claude CLI is not on PATH — skipping Claude triage MCP registration"
fi

dead_key_warning

# ── migrate the pre-0005 names away ───────────────────────────────────────────────
if [[ "$CLAUDE_AVAILABLE" -eq 1 ]]; then
for entry in "${LEGACY[@]}"; do
  name="${entry%%|*}"; rel="${entry#*|}"
  have="$(registered_args "$name")"
  [[ -z "$have" ]] && continue
  if [[ "$have" != "$(expected_args "$rel")" ]]; then
    warn "$name — legacy entry with a command this script does not own; leaving it alone: $have"
    continue
  fi
  if [[ "$DRY" -eq 1 ]]; then dim "would deregister legacy $name (renamed in docs/adr/0005)"; continue; fi
  if (cd "$ROOT" && claude mcp remove "$name" --scope local >/dev/null 2>&1); then
    ok "$name — legacy registration removed (renamed; see docs/adr/0005)"
  else
    warn "$name — could not remove the legacy entry; by hand: claude mcp remove $name --scope local"
  fi
done

changed=0
for entry in "${SERVERS[@]}"; do
  name="${entry%%|*}"; rel="${entry#*|}"
  abs="$ROOT/$rel"
  have="$(registered_args "$name")"
  want_args="$(expected_args "$rel")"

  if [[ "$WANT" -eq 1 ]]; then
    if [[ ! -f "$abs" ]]; then warn "$name — $rel is missing; not registering"; continue; fi
    if [[ "$have" == "$want_args" ]]; then ok "$name — already registered (local scope)"; continue; fi
    if [[ -n "$have" ]]; then
      # Someone registered this name with a different command (a custom path or flags). Their
      # entry wins: silently replacing it would break whatever they set up on purpose.
      warn "$name — registered with a different command; leaving it alone: $have"
      continue
    fi
    if [[ "$DRY" -eq 1 ]]; then dim "would register $name (local scope) → $want_args"; changed=1; continue; fi
    if (cd "$ROOT" && claude mcp add "$name" --scope local -- uv run --quiet "$abs" >/dev/null 2>&1); then
      ok "$name — registered (local scope); restart the session for its tools to appear"
      changed=1
    else
      warn "$name — 'claude mcp add' failed; register by hand (see scripts/${rel%%/*}/README.md)"
    fi
  else
    if [[ -z "$have" ]]; then continue; fi
    if [[ "$have" != "$want_args" ]]; then
      warn "$name — registered with a command this script does not own; leaving it alone: $have"
      continue
    fi
    if [[ "$DRY" -eq 1 ]]; then dim "would deregister $name (triage.enabled is off)"; changed=1; continue; fi
    if (cd "$ROOT" && claude mcp remove "$name" --scope local >/dev/null 2>&1); then
      ok "$name — deregistered (triage.enabled is off)"
      changed=1
    else
      warn "$name — 'claude mcp remove' failed; remove by hand: claude mcp remove $name --scope local"
    fi
  fi
done
fi

python3 "$ROOT/scripts/harnesses/triage_mcp.py" --root "$ROOT" --action "$ACTION" --want "$WANT" \
  $([[ "$DRY" -eq 1 ]] && printf '%s' '--dry-run') || warn "Cursor/Codex triage MCP reconciliation reported a failure"

if [[ "$WANT" -eq 0 ]]; then
  ok "Triage MCPs DISABLED (triage.enabled is off; source: $ENABLED_SRC). Nothing registered, nothing spawns. Drop that line — the default is ON — to get staging triage back."
else
  case "$PROD" in
    true|yes|1|on) dim "production targets are ENABLED on this machine (triage.prod, $PROD_SRC)" ;;
    *)             dim "staging only — production is refused in-process until triage.prod: true ($PROD_SRC)" ;;
  esac
fi
exit 0
