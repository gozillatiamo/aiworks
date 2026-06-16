#!/usr/bin/env bash
# Discover the Jira custom-field ids you need to populate the estimation env keys in
# scripts/tracker/.env — JIRA_EFFORT_FIELD / JIRA_DEV_POINTS_FIELD / JIRA_QA_POINTS_FIELD —
# without guessing customfield ids by hand.
#
# Calls GET /rest/api/3/field and prints "<id>\t<name>" for every field whose name matches
# Story Points / Developer Points / QA Points (case-insensitive). Widen or narrow it with
# --grep <regex>, or dump everything with --all.
#
#   ./discover-fields.sh                 # the estimation point fields (the default)
#   ./discover-fields.sh --grep points   # any field whose name matches /points/i
#   ./discover-fields.sh --all           # every field (id + name)
#
# Jira-specific (talks to the Jira REST API directly); independent of TRACKER_PROVIDER, so
# you can run it while the workspace is still configured for another tracker. Reuses the
# Jira impl's jira_api + config validation and the shared scripts/tracker/.env.
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACKER_DIR="$(cd "$DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: discover-fields.sh [--grep <regex> | --all]

Print Jira field ids + names so you can fill JIRA_EFFORT_FIELD / JIRA_DEV_POINTS_FIELD /
JIRA_QA_POINTS_FIELD in scripts/tracker/.env. Default: the Story/Developer/QA Points
fields. Output is "<id>\t<name>", one per line.

Options:
  --grep <regex>   Match field names against this (case-insensitive) regex instead of the
                   default point-field pattern.
  --all            Print every field (id + name).
  -h, --help       Show this help and exit.

Environment (scripts/tracker/.env): JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

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

# Default pattern matches the three estimation fields and common name variants.
pattern='story point|developer point|dev point|qa point'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --grep) [[ -n "${2:-}" ]] || die "--grep needs a regex"; pattern="$2"; shift 2 ;;
    --all)  pattern=""; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1   (see -h)" ;;
    *)  die "unexpected argument: $1   (see -h)" ;;
  esac
done

resp="$(jira_api GET "/rest/api/3/field")"
out="$(printf '%s' "$resp" | jq -r --arg re "$pattern" '
  .[]
  | select($re == "" or ((.name // "" | ascii_downcase) | test($re)))
  | "\(.id)\t\(.name)"' | sort)"

if [[ -z "$out" ]]; then
  echo "(no fields matched /$pattern/i — try --grep <regex> or --all)" >&2
  exit 0
fi
printf '%s\n' "$out"
