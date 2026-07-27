#!/usr/bin/env bash
#
# prod-triage-mcp.sh — reconcile the read-only PRODUCTION-triage MCP servers with the
# workspace's `prod_triage.enabled` policy.
#
#   prod_pg_triage     scripts/db/prod_pg_mcp.py       read-only prod Postgres (MAD + 16 shards)
#   prod_redis_triage  scripts/redis/prod_redis_mcp.py read-only prod/staging Redis + Streams
#
# Both are registered in **local scope** (`~/.claude.json` → projects[<workspace>].mcpServers),
# never in the committed `.mcp.json`. Claude Code spawns every enabled stdio server at session
# start, and prod triage is occasional work: a shared entry would cost every teammate an idle
# process and a screenful of tool names in every session. Nothing about the spawn is dangerous
# (both servers connect lazily and hold nothing until a tool is called) — it is cost with no
# payer. So the machines doing prod triage are the ones that carry the servers.
#
# `enabled` is read LOCAL-FIRST — workspace.config.local.yaml (git-ignored, personal) wins over
# workspace.config.yaml (shared) — because who does prod triage is a per-person decision and
# what this writes is a per-person file. See docs/adr/0003.
#
#   prod_triage:
#     enabled: true
#
# Usage:
#   scripts/prod-triage-mcp.sh              # sync — reconcile registration with the policy
#   scripts/prod-triage-mcp.sh on|off       # force, ignoring the policy (config is not edited)
#   scripts/prod-triage-mcp.sh status       # report policy + what is registered
#   scripts/prod-triage-mcp.sh sync -n      # preview; change nothing
#
# `aiworks sync` (and therefore `aiworks setup`) runs the sync form, so flipping the flag and
# re-running setup is the whole teammate-facing story.
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
    -h|--help)          sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                  die "unknown argument: $a (use sync|on|off|status [-n])" ;;
  esac
done

# Workspace root: this script lives in <root>/scripts/.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$ROOT/workspace.config.yaml" ]] || die "workspace.config.yaml not found at $ROOT"

# The servers this script owns, as "<name>|<path relative to root>".
SERVERS=(
  "prod_pg_triage|scripts/db/prod_pg_mcp.py"
  "prod_redis_triage|scripts/redis/prod_redis_mcp.py"
)

# ── policy ────────────────────────────────────────────────────────────────────────
# Read `prod_triage.enabled` out of one YAML file. Prints nothing when the key is absent, so
# the caller can tell "absent" from "false" and fall through to the next file.
read_flag() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk '
    function val(s){ sub(/^[^:]*:[ \t]*/,"",s); sub(/[ \t]+#.*$/,"",s);
                     gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { sec=$0; sub(/:.*/,"",sec) }
    sec=="prod_triage" && /^  enabled:/ { print tolower(val($0)); exit }
  ' "$f"
}

# Sets FLAG + POLICY_SRC. Assigns rather than prints: a `$(…)` call would resolve the source in
# a subshell and lose it, which is exactly what the status line needs to report.
FLAG=""; POLICY_SRC=""
resolve_policy() {
  local v
  v="$(read_flag "$ROOT/workspace.config.local.yaml")"
  if [[ -n "$v" ]]; then FLAG="$v"; POLICY_SRC="workspace.config.local.yaml"; return 0; fi
  v="$(read_flag "$ROOT/workspace.config.yaml")"
  if [[ -n "$v" ]]; then FLAG="$v"; POLICY_SRC="workspace.config.yaml"; return 0; fi
  FLAG="false"; POLICY_SRC="default (key absent)"
}
resolve_policy
case "$FLAG" in true|yes|1) WANT=1 ;; *) WANT=0 ;; esac
case "$ACTION" in on) WANT=1; POLICY_SRC="--on (forced)" ;; off) WANT=0; POLICY_SRC="--off (forced)" ;; esac

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
  printf '  prod_triage.enabled = %s  (%s)\n' "$FLAG" "$POLICY_SRC"
  for entry in "${SERVERS[@]}"; do
    name="${entry%%|*}"; rel="${entry#*|}"
    have="$(registered_args "$name")"
    if [[ -z "$have" ]]; then dim "$name — not registered"
    elif [[ "$have" == "$(expected_args "$rel")" ]]; then ok "$name — registered (local scope)"
    else warn "$name — registered with a DIFFERENT command: $have"; fi
  done
  exit 0
fi

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"
if ! command -v claude >/dev/null 2>&1; then
  warn "the claude CLI is not on PATH — skipping prod-triage MCP registration"
  exit 0
fi

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
    if [[ "$DRY" -eq 1 ]]; then dim "would deregister $name (prod_triage.enabled is off)"; changed=1; continue; fi
    if (cd "$ROOT" && claude mcp remove "$name" --scope local >/dev/null 2>&1); then
      ok "$name — deregistered (prod_triage.enabled is off)"
      changed=1
    else
      warn "$name — 'claude mcp remove' failed; remove by hand: claude mcp remove $name --scope local"
    fi
  fi
done

if [[ "$WANT" -eq 0 && "$changed" -eq 0 ]]; then
  ok "Prod triage MCPs DISABLED (prod_triage.enabled is off — the default; source: $POLICY_SRC). Nothing registered, nothing spawns. Set prod_triage.enabled: true in workspace.config.local.yaml and re-run to opt in."
fi
exit 0
