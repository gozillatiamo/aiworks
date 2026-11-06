#!/usr/bin/env bash
#
# upsert-release-details.sh — the release-description writer, offline.
#
# WHY THIS SUITE EXISTS. A release note lands on ONE Jira version by overwriting its
# description. The failures that matter are silent ones: a note written onto the wrong
# version (a name that matched two), a note truncated by Jira's 16,384-byte cap, or a
# provider with no release concept "succeeding" at nothing. So this asserts: every ref shape
# (release URL, bare id, name) resolves to the same PUT; an ambiguous or unknown name dies
# before any write; an oversized note dies with the byte count; Notion and Linear refuse.
#
# HOW IT IS TESTED. The Jira impl is sourced for real; jira_api is redefined to answer a
# canned version list for the lookup and to echo the PUT it was handed.
#
# Run:  scripts/tracker/release-details-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# No network, no credentials used, no release touched.
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

# jira_put <ref> <text> → what the stubbed transport saw (the GET lookup answers two versions:
# v1.0.0 once, v2.0.0 twice).
jira_put() {
  JIRA_BASE_URL=https://example.atlassian.net JIRA_PROJECT_KEY=PROJ JIRA_EMAIL=x JIRA_API_TOKEN=x \
  TRACKER_PROVIDER=jira bash -c '
    . "$1"/lib.sh; shift
    jira_api() {
      case "$1" in
        GET) printf "[{\"id\":\"10042\",\"name\":\"v1.0.0\"},{\"id\":\"10050\",\"name\":\"v2.0.0\"},{\"id\":\"10051\",\"name\":\"v2.0.0\"}]" ;;
        PUT) printf "PUT %s %s\n" "$2" "$3" >&2; printf "{}" ;;
      esac
    }
    tracker_upsert_release "$1" 0 "$2"
  ' _ "$TDIR" "$@" 2>&1
}

echo "jira — every ref shape lands on the same version"
out="$(jira_put 'https://example.atlassian.net/projects/PROJ/versions/10042/tab/release-report-all-issues' 'สวัสดี')"
has   "a release URL → its numeric id"        'PUT /rest/api/3/version/10042' "$out"
has   "…the description is the text, verbatim" '"description": "สวัสดี"'       "$out"
has   "…and the reply links the release"      'https://example.atlassian.net/projects/PROJ/versions/10042' "$out"
out="$(jira_put 10042 'x')"
has   "a bare id is used as-is"               'PUT /rest/api/3/version/10042' "$out"
out="$(jira_put v1.0.0 'x')"
has   "a name is looked up inside the project" 'PUT /rest/api/3/version/10042' "$out"

echo "jira — a wrong target dies before any write"
out="$(jira_put v2.0.0 'x')"
has   "an ambiguous name dies"                "matched 2 versions"           "$out"
hasnt "…and nothing is written"               'PUT /rest/api/3/version'      "$out"
out="$(jira_put v9.9.9 'x')"
has   "an unknown name dies"                  "matched 0 versions"           "$out"
hasnt "…and nothing is written"               'PUT /rest/api/3/version'      "$out"

echo "jira — the 16,384-byte cap is enforced, never truncated"
big="$(head -c 16385 /dev/zero | tr '\0' a)"
out="$(jira_put 10042 "$big")"
has   "an oversized note dies with its size"  "16385 bytes; Jira allows 16384" "$out"
hasnt "…and nothing is written"               'PUT /rest/api/3/version'      "$out"
out="$(jira_put 10042 "${big%a}")"
has   "exactly 16,384 bytes is still written" 'PUT /rest/api/3/version/10042' "$out"

echo "the entry script"
out="$(cd "$TDIR" && JIRA_BASE_URL=https://example.atlassian.net JIRA_PROJECT_KEY=PROJ JIRA_EMAIL=x JIRA_API_TOKEN=x \
  TRACKER_PROVIDER=jira ./upsert-release-details.sh 10042 --description-file - --dry-run <<<'hello' 2>&1)"
has   "--dry-run prints the PUT instead of sending" 'DRY RUN — PUT /rest/api/3/version/10042' "$out"
has   "…with the stdin text"                  '"description": "hello"'       "$out"
out="$(cd "$TDIR" && JIRA_BASE_URL=https://example.atlassian.net JIRA_EMAIL=x JIRA_API_TOKEN=x \
  TRACKER_PROVIDER=jira ./upsert-release-details.sh 10042 2>&1)"
has   "no --description-file dies"            "--description-file is required" "$out"

echo "providers without a release concept refuse"
for p in notion linear; do
  out="$(NOTION_TOKEN=x NOTION_DB_ID=y LINEAR_API_KEY=x LINEAR_TEAM_KEY=T TRACKER_PROVIDER=$p \
    bash -c '. "$1"/lib.sh; tracker_upsert_release 10042 0 x' _ "$TDIR" 2>&1)"
  has "$p dies instead of pretending" "releases are not supported by the $p provider" "$out"
done

echo
if [[ "$fail" -gt 0 ]]; then printf '%s%d passed, %d FAILED%s\n' "$c_err" "$pass" "$fail" "$c_off"; exit 1; fi
printf '%s%d passed%s\n' "$c_ok" "$pass" "$c_off"
