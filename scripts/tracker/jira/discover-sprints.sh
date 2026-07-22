#!/usr/bin/env bash
# Discover Jira sprint ids so --sprint <id> (upsert-ticket-details.sh) can be filled in
# without guessing. upsert-ticket-details.sh --sprint only ever accepts the Agile field's
# raw numeric sprint id — this script is the one place that resolves a human sprint
# name/number (e.g. "72", matching a sprint named "Sprint 72") to that id.
#
# Calls the Agile API (NOT /rest/api/3/...): GET /rest/agile/1.0/board?projectKeyOrId=...
# to find the board, then GET /rest/agile/1.0/board/<id>/sprint?state=... to list its
# sprints. Prints "<id>\t<name>\t<state>", one per line, newest-first.
#
#   ./discover-sprints.sh              # active + future sprints on the auto-discovered board
#   ./discover-sprints.sh 72           # ...filtered to sprints whose name contains "72"
#   ./discover-sprints.sh --all-states 72
#   ./discover-sprints.sh --board 3 72 # skip board auto-discovery
#
# Jira-specific (talks to the Jira Agile REST API directly); independent of
# TRACKER_PROVIDER. Reuses the Jira impl's jira_api + config validation and the shared
# scripts/tracker/.env. Set JIRA_BOARD_ID there to skip board auto-discovery every run.
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACKER_DIR="$(cd "$DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: discover-sprints.sh [--board <id>] [--all-states] [<name-query>]

Print Jira sprint ids + names so you can pass one to
upsert-ticket-details.sh --sprint <id>. Default: active + future sprints on the
project's board (closed sprints excluded — pass --all-states to include them).
Output is "<id>\t<name>\t<state>", one per line, newest first.

Arguments:
  <name-query>     Case-insensitive substring match against the sprint name
                    (e.g. "72" matches "Sprint 72"). Omit to list all in scope.

Options:
  --board <id>     Use this board id instead of auto-discovering one from
                    JIRA_PROJECT_KEY (or set JIRA_BOARD_ID in scripts/tracker/.env).
  --all-states     Include closed sprints too (default: active, future).
  -h, --help       Show this help and exit.

Environment (scripts/tracker/.env): JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN,
JIRA_PROJECT_KEY (for board auto-discovery), JIRA_BOARD_ID (optional override).
EOF
}

die() { echo "error: $*" >&2; exit 1; }
command -v jq   >/dev/null || die "jq is required (brew install jq)"
command -v curl >/dev/null || die "curl is required"

# Load the shared adapter .env (same file lib.sh reads), then borrow the Jira impl's
# jira_api + tracker_require_config (sourcing it only defines functions/vars).
if [[ -f "$TRACKER_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$TRACKER_DIR/.env"
  set +a
fi
# shellcheck source=impl.sh
. "$DIR/impl.sh"
tracker_require_config

board_id="${JIRA_BOARD_ID:-}"
states="active,future"
query=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --board) [[ -n "${2:-}" ]] || die "--board needs an id"; board_id="$2"; shift 2 ;;
    --all-states) states="active,future,closed"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1   (see -h)" ;;
    *) [[ -z "$query" ]] || die "unexpected extra argument: $1   (see -h)"; query="$1"; shift ;;
  esac
done

# Resolve the board when not given/configured: the Agile board list scoped to the
# project. A project with multiple boards uses the first (id order) and says so —
# pass --board explicitly to pick a different one.
if [[ -z "$board_id" ]]; then
  [[ -n "$JIRA_PROJECT_KEY" ]] || die "no board id and JIRA_PROJECT_KEY is not set — pass --board <id> or set JIRA_PROJECT_KEY/JIRA_BOARD_ID"
  resp="$(jira_api GET "/rest/agile/1.0/board?projectKeyOrId=$JIRA_PROJECT_KEY")"
  boards="$(printf '%s' "$resp" | jq -c '.values // []')"
  n="$(printf '%s' "$boards" | jq 'length')"
  [[ "$n" -gt 0 ]] || die "no Agile board found for project $JIRA_PROJECT_KEY — pass --board <id> explicitly"
  board_id="$(printf '%s' "$boards" | jq -r '.[0].id')"
  if [[ "$n" -gt 1 ]]; then
    echo "note: $n boards found for $JIRA_PROJECT_KEY, using board $board_id ($(printf '%s' "$boards" | jq -r '.[0].name')) — pass --board <id> to pick another:" >&2
    printf '%s' "$boards" | jq -r '.[] | "  \(.id)\t\(.name)"' >&2
  fi
fi

# Agile sprint listing paginates via startAt/maxResults/isLast (not the token-based
# pagination /rest/api/3/search/jql uses).
tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT
start=0
while :; do
  resp="$(jira_api GET "/rest/agile/1.0/board/$board_id/sprint?state=$states&startAt=$start&maxResults=50")"
  printf '%s' "$resp" | jq -c '.values // []' >> "$tmpdir/pages.jsonl"
  got="$(printf '%s' "$resp" | jq '(.values // []) | length')"
  start=$(( start + got ))
  [[ "$(printf '%s' "$resp" | jq -r '.isLast // true')" == "true" ]] && break
  [[ "$got" -gt 0 ]] || break
done

acc="$(jq -s 'add // []' "$tmpdir/pages.jsonl")"
out="$(printf '%s' "$acc" | jq -r --arg q "$query" '
  sort_by(.id) | reverse
  | .[]
  | select(($q | length) == 0 or ((.name // "" | ascii_downcase) | contains($q | ascii_downcase)))
  | "\(.id)\t\(.name)\t\(.state)"')"

if [[ -z "$out" ]]; then
  echo "(no sprints matched on board $board_id — try --all-states, a different --board, or no query to list everything in scope)" >&2
  exit 0
fi
printf '%s\n' "$out"
