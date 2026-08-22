#!/usr/bin/env bash
#
# Durable marked records — the upsert path every provider must honour, offline.
#
# WHY THIS SUITE EXISTS. A run posts the same kinds of thing onto a ticket over and over: a
# per-repo test report, a dev status, a regression scope, a QA plan. Each is meant to be ONE
# record, rewritten. Two providers used to answer `tracker_find_comment` with "nothing" —
# unconditionally, by design, because their comment APIs could not rewrite a body and reporting a
# hit would only send the caller to a `tracker_edit_comment` that died.
#
# The visible cost was a ticket turning into a stack of near-identical reports. The invisible cost
# was larger: `dev-cycle` proves its cross-repo test-suite gate really ran by having a second agent
# FIND this run's result on the ticket, through this exact call. A find that always answers
# "nothing" means that gate can never be verified — it was recorded as NOT RUN on every ticket, on
# the workspace's own default provider. A find that cannot find is not a missing nicety; it is a
# gate that cannot pass.
#
# So: Jira rewrites the comment; Linear rewrites it via `commentUpdate`; Notion, whose comment API
# genuinely has no update endpoint, keeps the record as ONE callout BLOCK on the page — marker in
# the callout's own text, record in its children — and an update archives that block and appends a
# fresh one.
#
# HOW IT IS TESTED. The transport is replaced, not the logic: each impl is sourced for real, then
# its HTTP helper (`notion_api` / `notion_collect_pages` / `linear_gql`) is redefined to answer from
# canned JSON and append every call to a log. The assertions read both what the function printed
# and — the half that matters — what it actually asked the API to do.
#
# Run:  scripts/tracker/durable-record-selftest.sh
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
is()   { [[ "$3" == "$2" ]] && ok "$1" || bad "$1" "$2" "$3"; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1" "must NOT contain: $2" "$3" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MARKER='[test-report · e2e-suite]'

# Source the adapter from an ISOLATED COPY, never from scripts/tracker itself. lib.sh loads a
# sibling .env with `set -a`, so a real one would override TRACKER_PROVIDER and every case below
# would silently run against whichever provider this workspace happens to be configured for —
# measured: the linear cases ran as notion and reported a live "no ticket with Task ID" error.
# The glob deliberately does not match dotfiles, so no .env is copied or read.
TDIR="$TMP/tracker"; mkdir -p "$TDIR"; cp -R "$DIR"/* "$TDIR"/ 2>/dev/null
rm -f "$TDIR"/*selftest.sh

# ── notion ────────────────────────────────────────────────────────────────────────
# FIXTURE=fresh  → the page has no marked record yet
# FIXTURE=exists → the page already carries one, plus a decoy a human wrote
notion() { # notion <fixture> <function> [args…]
  local fixture="$1"; shift
  CALLS="$TMP/calls"; : > "$CALLS"
  NOTION_TOKEN=x NOTION_DB_ID=y TRACKER_PROVIDER=notion FIXTURE="$fixture" CALLS="$CALLS" \
  MARKER="$MARKER" bash -c '
    . "$1"/lib.sh
    shift
    # Transport stubs, defined AFTER the impl so they win. Everything under test — the block
    # search, the callout builder, the archive-then-append update — is the real code.
    notion_resolve_page_id() { printf "page-1"; }
    notion_api() {
      printf "%s %s\n" "$1" "$2" >> "$CALLS"
      [[ -n "${3:-}" ]] && printf "BODY %s\n" "$(printf "%s" "$3" | jq -c . 2>/dev/null || printf "%s" "$3")" >> "$CALLS"
      case "$1 $2" in
        "PATCH /blocks/page-1/children") printf "{\"results\":[{\"id\":\"new-callout\"}]}\n" ;;
        *) printf "{}\n" ;;
      esac
    }
    notion_collect_pages() {
      printf "%s %s\n" "$1" "$2" >> "$CALLS"
      case "$2" in
        "/blocks/page-1/children")
          if [[ "$FIXTURE" == exists ]]; then
            jq -n --arg m "$MARKER" "[
              {id:\"human-1\", type:\"paragraph\", paragraph:{rich_text:[{plain_text:\"a note a person wrote\"}]}},
              {id:\"rec-1\", type:\"callout\", callout:{rich_text:[{plain_text:\$m}]}},
              {id:\"other-1\", type:\"callout\", callout:{rich_text:[{plain_text:\"[test-report · api-suite]\"}]}}
            ]"
          else
            printf "[]\n"
          fi ;;
        "/blocks/rec-1/children")
          jq -n "[{type:\"paragraph\", paragraph:{rich_text:[{plain_text:\"run r5 · 0/4 red\"}]}}]" ;;
        *) printf "[]\n" ;;
      esac
    }
    "$@"
  ' _ "$TDIR" "$@" 2>&1
}
calls() { cat "$TMP/calls" 2>/dev/null; }

echo "── notion: find"
out="$(notion fresh tracker_find_comment APP-1 "$MARKER")"
is  "no record yet -> prints nothing"              ""             "$out"
hasnt "…and does NOT warn that it cannot update"   "cannot update" "$out"

out="$(notion exists tracker_find_comment APP-1 "$MARKER")"
has "an existing record is found by its marker"    "rec-1"         "$out"
has "…and its BODY comes back, not just an id"     "run r5 · 0/4 red" "$out"
is  "the id is the FIRST line (the impl contract)" "rec-1"         "$(printf '%s' "$out" | head -1)"
hasnt "a sibling record's marker is not matched"   "other-1"       "$out"
hasnt "…nor a paragraph a human wrote"             "human-1"       "$out"

echo "── notion: first write"
out="$(notion fresh tracker_add_marked APP-1 0 "**$MARKER**"$'\n''fresh body' "$MARKER")"
has "the record is APPENDED to the page"           "PATCH /blocks/page-1/children" "$(calls)"
hasnt "…and NOT posted to the comment feed"        "POST /comments"                "$(calls)"
has "it is one callout container, not loose blocks" "\"type\":\"callout\""         "$(calls)"
# The marker MUST sit in the callout's own rich_text. A block payload from /blocks/{id}/children
# does not carry its children, so a marker only in the body is invisible to the next run's find —
# which would post a second record every time, i.e. the exact bug this path exists to remove.
has "the marker is the callout's OWN text, not just body content" "$MARKER" \
    "$(calls | sed -n 's/^BODY //p' | jq -r '.children[0].callout.rich_text[0].text.content // ""' 2>/dev/null)"

echo "── notion: update in place"
out="$(notion exists tracker_edit_comment APP-1 rec-1 0 "**$MARKER**"$'\n''r6 body' "$MARKER")"
has "the OLD block is archived"                    "DELETE /blocks/rec-1"          "$(calls)"
has "…and a fresh one appended"                    "PATCH /blocks/page-1/children" "$(calls)"
has "the caller is told it was an update"           "Updated the marked record"     "$out"

echo "── notion: a record can never be left unfindable"
out="$(notion fresh tracker_add_marked APP-1 0 "" "")"
has "an empty marker AND empty body is refused"    "needs a marker"                "$out"
out="$(notion fresh tracker_add_marked APP-1 0 "**$MARKER**"$'\n''body' "")"
has "…but a first line stands in for a missing marker" "PATCH /blocks/page-1/children" "$(calls)"

echo "── notion: --dry-run writes nothing"
out="$(notion exists tracker_edit_comment APP-1 rec-1 1 "**$MARKER**"$'\n''x' "$MARKER")"
has "it says what it would do"                     "DRY RUN"                       "$out"
hasnt "…and archives nothing"                      "DELETE"                        "$(calls)"

# ── linear ────────────────────────────────────────────────────────────────────────
linear() { # linear <fixture> <function> [args…]
  local fixture="$1"; shift
  CALLS="$TMP/calls"; : > "$CALLS"
  LINEAR_API_KEY=x TRACKER_PROVIDER=linear FIXTURE="$fixture" CALLS="$CALLS" MARKER="$MARKER" bash -c '
    . "$1"/lib.sh
    shift
    linear_identifier() { printf "APP-1"; }
    linear_gql() {
      printf "%s\n" "$1" >> "$CALLS"
      case "$1" in
        *comments*)
          if [[ "$FIXTURE" == exists ]]; then
            jq -n --arg m "$MARKER" "{issue:{comments:{nodes:[
              {id:\"c-old\", body:(\$m + \"\nrun r5\"), createdAt:\"2026-01-01\"},
              {id:\"c-new\", body:(\$m + \"\nrun r6\"), createdAt:\"2026-02-01\"},
              {id:\"c-other\", body:\"just a human comment\", createdAt:\"2026-03-01\"}
            ]}}}"
          else
            printf "{\"issue\":{\"comments\":{\"nodes\":[]}}}\n"
          fi ;;
        *commentUpdate*) printf "{\"commentUpdate\":{\"success\":true,\"comment\":{\"id\":\"c-new\"}}}\n" ;;
        *) printf "{}\n" ;;
      esac
    }
    "$@"
  ' _ "$TDIR" "$@" 2>&1
}

echo "── linear: find"
out="$(linear fresh tracker_find_comment APP-1 "$MARKER")"
is  "no record yet -> prints nothing"                ""        "$out"
hasnt "…and no 'cannot update' warning any more"     "cannot update" "$out"
out="$(linear exists tracker_find_comment APP-1 "$MARKER")"
is  "the NEWEST marked comment wins"                 "c-new"   "$(printf '%s' "$out" | head -1)"
hasnt "an unmarked human comment is never matched"   "c-other" "$out"

echo "── linear: update in place"
out="$(linear exists tracker_edit_comment APP-1 c-new 0 "$MARKER"$'\n''r7')"
has "commentUpdate is what gets called"              "commentUpdate" "$(calls)"
has "…and the caller is told it updated"             "Updated comment c-new" "$out"
out="$(linear exists tracker_edit_comment APP-1 c-new 1 "$MARKER"$'\n''r7')"
has "--dry-run says what it would do"                "DRY RUN"       "$out"
hasnt "…and calls no mutation"                       "commentUpdate" "$(calls)"

# ── the wrapper's own refusal ──────────────────────────────────────────────────────
echo "── upsert-ticket-comment.sh"
out="$(NOTION_TOKEN=x NOTION_DB_ID=y TRACKER_PROVIDER=notion \
        bash "$TDIR/upsert-ticket-comment.sh" APP-1 --marker "$MARKER" "a body with no marker in it" 2>&1)"
has "a body missing its own marker is refused" "does not contain the marker" "$out"
out="$(NOTION_TOKEN=x NOTION_DB_ID=y TRACKER_PROVIDER=notion \
        bash "$TDIR/upsert-ticket-comment.sh" APP-1 "some text" 2>&1)"
has "…and --marker is mandatory"               "--marker is required"        "$out"

echo
if [[ "$fail" -gt 0 ]]; then printf '%s%d passed, %d FAILED%s\n' "$c_err" "$pass" "$fail" "$c_off"; exit 1; fi
printf '%s%d passed%s\n' "$c_ok" "$pass" "$c_off"
