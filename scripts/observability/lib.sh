#!/usr/bin/env bash
# Observability adapter — shared dispatch for the tracing/logging scripts.
# Sourced by entry scripts (get-trace.sh, get-logs.sh); not meant to run alone.
#
# Selects a provider implementation by OBSERVABILITY_PROVIDER (signoz) and sources
# scripts/observability/<provider>/impl.sh, which defines the provider interface:
#
#   obs_require_config                                    — validate the provider's env (base url/key), die if missing
#   obs_get_trace TRACE_ID [SPAN_ID]                       — print the trace's span waterfall; SPAN_ID (optional) highlights one span
#   obs_query_logs FILTERS_JSON FROM_MS TO_MS [LIMIT] [RAW] — print log lines matching a semantic filter object in [FROM_MS, TO_MS).
#                                                            FILTERS_JSON is provider-agnostic (any subset of service/severity/env/
#                                                            body_contains/trace_id); the provider impl translates it. RAW=1 -> raw JSON.
#
# Like the vcs/tracker/notify adapters, this reads a git-ignored scripts/observability/.env
# for the provider + secrets (already covered by the workspace's blanket .env / .env.* gitignore
# rule — nothing extra to add there).

set -euo pipefail

OBSERVABILITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load a .env sitting next to these scripts, if present (git-ignored local config).
if [[ -f "$OBSERVABILITY_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$OBSERVABILITY_DIR/.env"
  set +a
fi

die() { echo "error: $*" >&2; exit 1; }
command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required (brew install jq)"

# obs_epoch_ms WHEN -> epoch milliseconds. Accepts `now`, a relative offset (-30m/-2h/-7d),
# epoch seconds or milliseconds, and ISO-8601 **carrying its own offset** (`…Z`, `…+07:00`,
# `…+0700`).
#
# A bare `2026-08-11T15:52:41` is REFUSED, on purpose. `date` would read it in the shell's
# timezone, so under Asia/Bangkok the window silently moved seven hours and the query returned
# a confident, well-formed answer about the wrong hours — the quietest possible bug, and the
# one that made every caller hand-convert with python3 first. Refusing costs one retry with an
# offset; guessing costs a wrong verdict nobody can see is wrong. This lives here, not in each
# entry script, because two copies of a time parser is how one of them stays broken.
obs_epoch_ms() {
  local w="$1" secs norm
  case "$w" in
    now)
      echo "$(( $(date +%s) * 1000 ))"; return ;;
    -*)
      local n unit; n="${w%[mhd]}"; n="${n#-}"; unit="${w: -1}"
      case "$unit" in
        m) secs=$(( $(date +%s) - n*60 )) ;;
        h) secs=$(( $(date +%s) - n*3600 )) ;;
        d) secs=$(( $(date +%s) - n*86400 )) ;;
        *) die "unrecognized relative offset: $w (use -30m / -2h / -7d)" ;;
      esac ;;
    ''|*[!0-9]*)
      norm=""
      case "$w" in
        *Z)                         norm="${w%Z}+0000" ;;
        *[+-][0-9][0-9]:[0-9][0-9]) norm="${w%??:??}${w: -5:2}${w: -2}" ;;
        *[+-][0-9][0-9][0-9][0-9])  norm="$w" ;;
        *)
          echo "refusing an ambiguous time: $w" >&2
          echo "  It names no timezone, and reading it as local time would query the wrong" >&2
          echo "  hours without failing. Pass epoch ms, or add an offset:" >&2
          echo "    '${w}+07:00'   (Asia/Bangkok)      '${w}Z'   (UTC)" >&2
          exit 1 ;;
      esac
      # BSD date wants %z as +0700; GNU date reads the original string, colon and all.
      secs="$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$norm" +%s 2>/dev/null || date -d "$w" +%s 2>/dev/null)" \
        || die "unrecognized time: $w" ;;
    *)
      # All digits: epoch already. 13+ digits is milliseconds, anything shorter is seconds.
      if [[ ${#w} -ge 13 ]]; then printf '%s' "$w"; return 0; fi
      secs="$w" ;;
  esac
  echo "$(( secs * 1000 ))"
}

# obs_duration_s DURATION -> seconds. Accepts 30s / 5m / 2h / 1d.
obs_duration_s() {
  local d="$1" n="${1%[smhd]}" unit="${1: -1}"
  case "$unit" in
    s) echo "$n" ;;
    m) echo $(( n*60 )) ;;
    h) echo $(( n*3600 )) ;;
    d) echo $(( n*86400 )) ;;
    *) die "unrecognized duration: $d (use 30s / 5m / 2h / 1d)" ;;
  esac
}

# Which observability backend this workspace uses. Defaults to signoz (the only provider today).
OBSERVABILITY_PROVIDER="${OBSERVABILITY_PROVIDER:-signoz}"
IMPL="$OBSERVABILITY_DIR/$OBSERVABILITY_PROVIDER/impl.sh"
[[ -f "$IMPL" ]] || die "unknown OBSERVABILITY_PROVIDER '$OBSERVABILITY_PROVIDER' (no $IMPL) — use 'signoz', or add an impl.sh under scripts/observability/$OBSERVABILITY_PROVIDER/"

# shellcheck disable=SC1090
. "$IMPL"
obs_require_config
