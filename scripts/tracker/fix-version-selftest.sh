#!/usr/bin/env bash
#
# --fix-version — the release filter on find-tickets.sh, offline.
#
# WHY THIS SUITE EXISTS. A release report / announcement is built from "every ticket in one
# fix version". Before this flag the adapter could not ask that question at all: `--query` is a
# summary word match, not a JQL passthrough. The failure mode that matters is not an error but a
# SILENTLY unfiltered list — an announcement built from the whole board. So this asserts two
# things: Jira builds the exact `fixVersion` clause (bare numeric ID, quoted name), and a
# provider with no release concept refuses the flag instead of ignoring it.
#
# HOW IT IS TESTED. Each impl is sourced for real; its HTTP helper is redefined to capture the
# JQL it was asked to run and answer an empty page.
#
# Run:  scripts/tracker/fix-version-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# No network, no credentials used, no ticket touched.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

c_ok=$'\033[1;32m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_ok=; c_err=; c_off=; }
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  %s✓%s %s\n' "$c_ok" "$c_off" "$1"; }
bad()  { fail=$((fail+1)); printf '  %s✗%s %s\n     want %s\n     got  %s\n' "$c_err" "$c_off" "$1" "$2" "$3"; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1" "must NOT contain: $2" "$3" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Isolated copy of the adapter so a real sibling .env can never pick the provider for us.
# The glob deliberately does not match dotfiles, so no .env is copied or read.
TDIR="$TMP/tracker"; mkdir -p "$TDIR"; cp -R "$DIR"/* "$TDIR"/ 2>/dev/null
rm -f "$TDIR"/*selftest.sh

# jira_jql <find-tickets args…> → the JQL string the stubbed transport was handed.
jira_jql() {
  JIRA_BASE_URL=https://example.atlassian.net JIRA_PROJECT_KEY=PROJ JIRA_EMAIL=x JIRA_API_TOKEN=x \
  TRACKER_PROVIDER=jira bash -c '
    . "$1"/lib.sh; shift
    jira_api() { printf "%s" "$3" | jq -r .jql >&2; printf "{\"issues\":[],\"isLast\":true}"; }
    opts="$(jq -n --arg fv "$1" "{query:\"\", fix_version:\$fv, limit:50, types:[]}")"
    tracker_find "$opts" >/dev/null
  ' _ "$TDIR" "$@" 2>&1
}

echo "jira"
out="$(jira_jql 10042)"
has   "a numeric id lands bare in the clause"   "fixVersion = 10042"           "$out"
hasnt "…not quoted (Jira would read it as a name)" 'fixVersion = "10042"'     "$out"
has   "…ANDed with the project scope"           "project = PROJ AND fixVersion = 10042 ORDER BY" "$out"
out="$(jira_jql '2026.09 Release')"
has   "a version name is quoted"                'fixVersion = "2026.09 Release"' "$out"
out="$(jira_jql '')"
hasnt "no flag → no clause"                      "fixVersion"                  "$out"

echo "providers without a release concept refuse the flag"
for p in notion linear; do
  out="$(NOTION_TOKEN=x NOTION_DB_ID=y LINEAR_API_KEY=x LINEAR_TEAM_KEY=T TRACKER_PROVIDER=$p \
    bash -c '. "$1"/lib.sh; tracker_find "{\"fix_version\":\"10042\",\"types\":[]}"' _ "$TDIR" 2>&1)"
  has "$p dies instead of returning an unfiltered list" "--fix-version is not supported by the $p provider" "$out"
done

echo
if [[ "$fail" -gt 0 ]]; then printf '%s%d passed, %d FAILED%s\n' "$c_err" "$pass" "$fail" "$c_off"; exit 1; fi
printf '%s%d passed%s\n' "$c_ok" "$pass" "$c_off"
