#!/usr/bin/env bash
#
# upsert-release-details.sh — the release-note writer, offline.
#
# WHY THIS SUITE EXISTS. A release note lands on ONE Jira version: into the rich-text
# section of its release page, with the plain description cleared. The failures that matter
# are silent ones: a note written onto the wrong version (a name that matched two, an id that
# exists nowhere), a how-to that falls out of its bullet, a description left behind in the
# releases list, or a provider with no release concept "succeeding" at nothing. So this
# asserts: every ref shape (release URL, bare id, name) lands on the same version ARI; the
# section mutation carries a real list with the how-to inside its item and the description
# PUT follows; an ambiguous or unknown name, or an unknown id, dies before any write; Notion
# and Linear refuse.
#
# HOW IT IS TESTED. The Jira impl is sourced for real; jira_api is redefined to answer the
# version lookup, the tenant and the GraphQL reads from canned data, and to echo every write
# (GraphQL mutation or REST PUT) it was handed.
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

# jira_write <ref> <text> → what the stubbed transport saw. The version lookup answers
# v1.0.0 once and v2.0.0 twice; the GraphQL read-back knows only version 10042.
jira_write() {
  JIRA_BASE_URL=https://example.atlassian.net JIRA_PROJECT_KEY=PROJ JIRA_EMAIL=x JIRA_API_TOKEN=x \
  TRACKER_PROVIDER=jira bash -c '
    . "$1"/lib.sh; shift
    jira_api() {
      case "$1 $2" in
        "GET /_edge/tenant_info") printf "{\"cloudId\":\"cloud-1\"}" ;;
        "GET /rest/api/3/project/PROJ/versions")
          printf "[{\"id\":\"10042\",\"name\":\"v1.0.0\"},{\"id\":\"10050\",\"name\":\"v2.0.0\"},{\"id\":\"10051\",\"name\":\"v2.0.0\"}]" ;;
        "POST /gateway/api/graphql")
          case "$3" in
            *VersionAri*)   printf "{\"data\":{\"jira\":{\"versionSearch\":{\"edges\":[{\"node\":{\"id\":\"ari:cloud:jira:cloud-1:version/activation/act-1/10240\"}}]}}}}" ;;
            *VersionCheck*) case "$3" in *\"id\":\"ari:cloud:jira:cloud-1:version/activation/act-1/10042\"*)
                              printf "{\"data\":{\"jira\":{\"version\":{\"versionId\":\"10042\"}}}}" ;;
                            *) printf "{\"data\":{\"jira\":{\"version\":null}}}" ;; esac ;;
            *) printf "GQL %s\n" "$3" >&2
               printf "{\"data\":{\"jira\":{\"t\":{\"success\":true,\"errors\":[]},\"c\":{\"success\":true,\"errors\":[]}}}}" ;;
          esac ;;
        "PUT "*) printf "PUT %s %s\n" "$2" "$3" >&2; printf "{}" ;;
      esac
    }
    tracker_upsert_release "$1" 0 "$2"
  ' _ "$TDIR" "$@" 2>&1
}

note=$'สวัสดี\n\n• ข้อแรก\n  ทำแบบนี้\n  แล้วแบบนี้\n\nด้านเทคนิค\n• เร็วขึ้น'
ARI='"id":"ari:cloud:jira:cloud-1:version/activation/act-1/10042"'

echo "jira — every ref shape lands on the same version"
out="$(jira_write 'https://example.atlassian.net/projects/PROJ/versions/10042/tab/release-report-all-issues' "$note")"
has   "a release URL → its version ARI"       "$ARI"                           "$out"
has   "…through the section mutation"         'updateJiraVersionRichTextSectionContent' "$out"
has   "…titled for the page"                  '"title":"Release note"'         "$out"
has   "…then the description is cleared"      'PUT /rest/api/3/version/10042 {"description": ""}' "$out"
has   "…and the reply links the release"      'https://example.atlassian.net/projects/PROJ/versions/10042' "$out"
out="$(jira_write 10042 "$note")"
has   "a bare id is used as-is"               "$ARI"                           "$out"
out="$(jira_write v1.0.0 "$note")"
has   "a name is looked up inside the project" "$ARI"                          "$out"

echo "jira — the note becomes a list, the how-to inside its bullet"
adf="$(printf '%s' "$out" | sed -n 's/^GQL //p' | jq -c '.variables.content')"
has   "the opening is a paragraph"            '{"type":"paragraph","content":[{"type":"text","text":"สวัสดี"}]}' "$adf"
has   "a • line is a list item"               '"bulletList"'                   "$adf"
has   "…its indented lines are hard breaks inside it" '{"type":"text","text":"ข้อแรก"},{"type":"hardBreak"},{"type":"text","text":"ทำแบบนี้"},{"type":"hardBreak"},{"type":"text","text":"แล้วแบบนี้"}' "$adf"
has   "a label line between lists is a paragraph" '{"type":"paragraph","content":[{"type":"text","text":"ด้านเทคนิค"}]}' "$adf"
[[ "$(printf '%s' "$adf" | jq '[.content[] | select(.type == "bulletList")] | length')" == 2 ]] \
  && ok "a blank line ends a list (two lists)" || bad "a blank line ends a list (two lists)" "2 bulletLists" "$adf"

echo "jira — a wrong target dies before any write"
out="$(jira_write v2.0.0 "$note")"
has   "an ambiguous name dies"                "matched 2 versions"             "$out"
hasnt "…and nothing is written"               'GQL'                            "$out"
hasnt "…not even the description"             'PUT /rest/api/3/version'        "$out"
out="$(jira_write v9.9.9 "$note")"
has   "an unknown name dies"                  "matched 0 versions"             "$out"
hasnt "…and nothing is written"               'GQL'                            "$out"
out="$(jira_write 99999 "$note")"
has   "an id the site does not know dies"     "version 99999 does not exist"   "$out"
hasnt "…and nothing is written"               'GQL'                            "$out"
hasnt "…not even the description"             'PUT /rest/api/3/version'        "$out"

echo "the entry script"
out="$(cd "$TDIR" && JIRA_BASE_URL=https://example.atlassian.net JIRA_PROJECT_KEY=PROJ JIRA_EMAIL=x JIRA_API_TOKEN=x \
  TRACKER_PROVIDER=jira ./upsert-release-details.sh 10042 --description-file - --dry-run <<<'hello' 2>&1)"
has   "--dry-run prints the mutation instead of sending" 'DRY RUN — updateJiraVersionRichTextSectionContent on version 10042' "$out"
has   "…with the stdin text as ADF"           '{"type":"text","text":"hello"}' "$out"
has   "…and the description clear it would send" 'DRY RUN — PUT /rest/api/3/version/10042 {"description": ""}' "$out"
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
