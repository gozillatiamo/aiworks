#!/usr/bin/env bash
#
# Description size cap — the split-and-attach path, offline (docs/adr/0044).
#
# WHY THIS SUITE EXISTS. A ticket description reached 13k characters and nobody read it. The cap
# (`tracker.max_description_chars`, default 5000) keeps the description a short page: a body over
# the cap is split before `## Details` (else before the last heading that fits), a one-line
# pointer is appended, and the FULL body lands in ONE `<KEY>-details.md` on the ticket — replaced
# on every re-run, never duplicated, and never lost when an upload fails. A provider without
# attachments keeps the full body in the `[details · <KEY>]` durable record instead.
#
# HOW IT IS TESTED. lib.sh and upsert-ticket-details.sh run for real from an ISOLATED COPY; the
# provider is a stub `impl.sh` that logs every call and answers from env-driven fixtures. The
# config root for the cap is the temp dir above the copy (tracker_config_root walks up to it).
#
# Run:  scripts/tracker/description-cap-selftest.sh
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
# The glob skips dotfiles, so no .env is copied or read (see durable-record-selftest.sh).
TDIR="$TMP/tracker"; mkdir -p "$TDIR"; cp -R "$DIR"/* "$TDIR"/ 2>/dev/null
rm -f "$TDIR"/*selftest.sh
CALLS="$TMP/calls"
CFG="$TMP/workspace.config.yaml"; LCFG="$TMP/workspace.config.local.yaml"

# Stub provider: STUB_ATTACH=1 ⇒ holds files (Jira-like); 0 ⇒ record fallback (Notion/Linear).
# STUB_OLD_IDS = ids an existing <KEY>-details.md already has; STUB_UPLOAD_FAIL=1 ⇒ upload dies.
mkdir -p "$TDIR/stub"
cat > "$TDIR/stub/impl.sh" <<'EOF'
tracker_require_config() { :; }
log() { printf '%s\n' "$*" >> "$CALLS"; }
tracker_supports_attachments() { [[ "${STUB_ATTACH:-1}" -eq 1 ]]; }
tracker_upsert() {
  local ticket="$1" dry="$2" fields="$3" body="${4:-}"
  log "UPSERT $ticket dry=$dry fields=$(printf '%s' "$fields" | jq -c .)"
  printf '%s' "$body" > "$CALLS.body"
  [[ "$dry" -eq 1 ]] && { printf 'DRY RUN — write %s\n' "$ticket"; return 0; }
  if [[ "$ticket" == new ]]; then printf 'Created APP-9\n'; else printf 'Updated %s\n' "$ticket"; fi
}
tracker_add_attachment() {
  log "ATTACH $1 $(basename "$3") id_only=${4:-0}"
  cp "$3" "$CALLS.attached"
  [[ "${STUB_UPLOAD_FAIL:-0}" -eq 1 ]] && die "attachment upload to $1 failed: HTTP 500"
  printf 'new-77\n'
}
tracker_attachment_ids_by_name() { log "LIST $1 $2"; printf '%s\n' ${STUB_OLD_IDS:-} new-77; }
tracker_remove_attachment() { log "REMOVE $1 $3"; }
tracker_find_comment() { log "FIND $1 $2"; [[ -n "${STUB_RECORD_ID:-}" ]] && printf '%s\nold body\n' "$STUB_RECORD_ID"; }
tracker_edit_comment() { log "EDIT $1 $2"; printf '%s' "$4" > "$CALLS.record"; }
tracker_add_comment() { log "ADD $1 marker=${4:-}"; printf '%s' "$3" > "$CALLS.record"; }
tracker_get_details() { :; }
EOF

run() { # run [ENV=…] -- <upsert args…>   (stdout+stderr; exit code in $rc)
  : > "$CALLS"; rm -f "$CALLS".*
  local -a envs=(); while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  out="$(env TRACKER_PROVIDER=stub CALLS="$CALLS" "${envs[@]}" bash "$TDIR/upsert-ticket-details.sh" "$@" 2>&1)"; rc=$?
}
lib() { # lib [ENV=…] -- <function> [args…]   — call a lib.sh helper in the isolated copy
  local -a envs=(); while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  env TRACKER_PROVIDER=stub CALLS="$CALLS" "${envs[@]}" bash -c '. "$1"/lib.sh; shift; "$@"' _ "$TDIR" "$@" 2>&1
}
rep() { local i; for ((i = 0; i < $2; i++)); do printf '%s' "$1"; done; }
body="$(cat "$CALLS.body" 2>/dev/null)"; calls() { cat "$CALLS" 2>/dev/null; }

echo "── T1: the cap value"
is "default is 5000 with no config"              "5000" "$(lib -- tracker_max_description_chars)"
printf 'tracker:\n  provider: jira\n  max_description_chars: 900\n' > "$CFG"
is "shared config value wins over the default"   "900"  "$(lib -- tracker_max_description_chars)"
printf 'tracker:\n  max_description_chars: 700\n' > "$LCFG"
is "a personal local override wins over shared"  "700"  "$(lib -- tracker_max_description_chars)"
printf 'tracker:\n  provider: jira\n' > "$LCFG"
is "a local tracker: block without the key ⇒ default (shallow override)" "5000" "$(lib -- tracker_max_description_chars)"
rm -f "$LCFG"
is "env TRACKER_MAX_DESCRIPTION_CHARS wins over config" "600" "$(lib TRACKER_MAX_DESCRIPTION_CHARS=600 -- tracker_max_description_chars)"
out="$(lib TRACKER_MAX_DESCRIPTION_CHARS=12 -- tracker_max_description_chars)"
has "a value under 500 warns"                    "warn:" "$out"
has "…and falls back to 5000"                    "5000"  "$out"
rm -f "$CFG"

echo "── T2: counting"
is "ASCII counts bytes as characters"            "5"  "$(lib -- tracker_char_count hello)"
is "Thai counts one unit per code point"         "3"  "$(lib -- tracker_char_count 'ที่')"
is "an astral emoji counts two UTF-16 units"     "2"  "$(lib -- tracker_char_count '😀')"
is "an inline image token is not counted"        "4"  "$(lib -- tracker_char_count 'abc ![shot.png](attachment:0f1e-2d3c|width=800,height=600)')"

echo "── T3: exactly at the cap, and one over"
big="# Title"$'\n\n'"$(rep x 200)"$'\n\n'"## Details"$'\n\n'"$(rep y 300)"
n="$(lib -- tracker_char_count "$big")"
run TRACKER_MAX_DESCRIPTION_CHARS="$n" -- APP-1 --body "$big"
is "at the cap: exit 0"                          "0" "$rc"
hasnt "at the cap: no split"                     "over the cap" "$out"
hasnt "at the cap: nothing attached"             "ATTACH" "$(calls)"
is "at the cap: the body is written whole"       "$big" "$(cat "$CALLS.body")"
run TRACKER_MAX_DESCRIPTION_CHARS="$((n - 1))" -- APP-1 --body "$big"
is "one over: exit 0"                            "0" "$rc"
has "one over: the note names the split"         "over the cap" "$out"
written="$(cat "$CALLS.body")"
has "one over: the core keeps the first section" "$(rep x 200)" "$written"
hasnt "one over: the core drops ## Details"      "## Details" "$written"
has "one over: the pointer names the file"       "Full details: attached APP-1-details.md" "$written"
is "one over: the pointer is the last line"      "Full details: attached APP-1-details.md" "$(printf '%s' "$written" | tail -n1)"
is "one over: the core itself is inside the cap" "true" "$([[ "$(lib -- tracker_char_count "$written")" -le $((n - 1)) ]] && echo true || echo false)"
is "one over: the full body is the attachment"   "$big" "$(cat "$CALLS.attached")"
has "one over: attached under <KEY>-details.md"  "ATTACH APP-1 APP-1-details.md id_only=1" "$(calls)"

echo "── T4: where the cut lands"
hb="# T"$'\n\n'"$(rep a 100)"$'\n\n'"## Steps"$'\n\n'"$(rep b 100)"$'\n\n'"## More"$'\n\n'"$(rep c 100)"
out="$(lib -- tracker_split_body 320 "$hb" "P")"
has "no ## Details: cut before the LAST heading that fits" "$(rep b 100)" "$out"
hasnt "…dropping the section after it"           "$(rep c 100)" "$out"
out="$(lib -- tracker_split_body 200 "$hb" "P")"
hasnt "a tighter cap moves the cut to an earlier heading" "## Steps" "$out"
has "…keeping the first section"                 "$(rep a 100)" "$out"
fb="# T"$'\n\n'"intro"$'\n\n'"\`\`\`"$'\n'"## not a heading"$'\n'"$(rep q 100)"$'\n'"\`\`\`"$'\n\n'"## Real"$'\n\n'"$(rep r 100)"
out="$(lib -- tracker_split_body 140 "$fb" "P")"
has "a heading inside a code fence is never a cut" "$(rep q 100)" "$out"
hasnt "…the cut lands at the real heading after the fence" "$(rep r 100)" "$out"
lib -- tracker_split_body 50 "$hb" "P" >/dev/null; is "nothing fits: exit 3" "3" "$?"
run TRACKER_MAX_DESCRIPTION_CHARS=500 -- APP-1 --body "# T"$'\n\n'"$(rep z 600)"
is "nothing fits through the script: exit 1"     "1" "$rc"
has "…with a message naming ## Details"          "## Details" "$out"
hasnt "…and nothing was written"                 "UPSERT" "$(calls)"
thai="# หัวข้อ"$'\n\n'"$(rep 'ก' 4000)"$'\n\n'"## Details"$'\n\n'"ท้าย"
run -- APP-1 --body "$thai"
hasnt "4000 Thai characters: not split at the default cap" "over the cap" "$out"
run -- APP-1 --body "# T"$'\n\n'"$(rep 'ก' 4900)"$'\n\n'"## Details"$'\n\n'"$(rep 'ก' 82)"
has "5001 characters: split"                     "over the cap" "$out"
img="# T"$'\n\n'"## Evidence"$'\n\n'"![shot.png](attachment:$(rep 0 400)|width=800,height=600)"$'\n'"Login page after submit."$'\n\n'"$(rep m 300)"$'\n\n'"## Details"$'\n\n'"$(rep n 300)"
run TRACKER_MAX_DESCRIPTION_CHARS=500 -- APP-1 --body "$img"
has "an image token in the core is not counted and survives the split" "![shot.png](attachment:" "$(cat "$CALLS.body")"
has "…with its caption"                          "Login page after submit." "$(cat "$CALLS.body")"
hasnt "…and ## Details still goes to the file"   "$(rep n 300)" "$(cat "$CALLS.body")"

echo "── T5: one attachment per ticket, old copy kept on failure"
run TRACKER_MAX_DESCRIPTION_CHARS=500 STUB_OLD_IDS="old-1 old-2" -- APP-1 --body "$big"
has "the new copy is added first"                "ATTACH APP-1" "$(calls)"
has "then every older same-name copy is removed" "REMOVE APP-1 old-1" "$(calls)"
has "…all of them"                               "REMOVE APP-1 old-2" "$(calls)"
hasnt "…but never the one just added"            "REMOVE APP-1 new-77" "$(calls)"
is "add runs before remove"                      "ATTACH" "$(grep -o 'ATTACH\|REMOVE' "$CALLS" | head -1)"
run TRACKER_MAX_DESCRIPTION_CHARS=500 STUB_OLD_IDS="old-1" STUB_UPLOAD_FAIL=1 -- APP-1 --body "$big"
is "a failed upload fails the run"               "1" "$rc"
hasnt "…and keeps the old copy"                  "REMOVE" "$(calls)"
run TRACKER_MAX_DESCRIPTION_CHARS=500 STUB_OLD_IDS="old-1" -- APP-1 --body "# T"$'\n\n'"short"
has "an under-cap re-run warns about the stale file" "stale" "$out"
hasnt "…and never deletes it"                    "REMOVE" "$(calls)"

echo "── T6: create path"
run TRACKER_MAX_DESCRIPTION_CHARS=500 -- new --title T --body "$big"
is "create: exit 0"                              "0" "$rc"
has "create: the pointer is written with the literal <KEY> before the key exists" "attached <KEY>-details.md" "$(cat "$CALLS.body")"
has "create: the file is attached to the created key" "ATTACH APP-9 APP-9-details.md" "$(calls)"

echo "── T7: a provider without attachments keeps the record"
run TRACKER_MAX_DESCRIPTION_CHARS=500 STUB_ATTACH=0 -- APP-1 --body "$big"
is "record fallback: exit 0"                     "0" "$rc"
has "the pointer names the record, not mojibaked" "see the [details · APP-1] record" "$(cat "$CALLS.body")"
hasnt "nothing attached"                         "ATTACH" "$(calls)"
has "the record is added with its marker"        "ADD APP-1 marker=[details · APP-1]" "$(calls)"
has "…carrying the full body"                    "$(rep y 300)" "$(cat "$CALLS.record")"
run TRACKER_MAX_DESCRIPTION_CHARS=500 STUB_ATTACH=0 STUB_RECORD_ID=rec-1 -- APP-1 --body "$big"
has "an existing record is edited, not added"    "EDIT APP-1 rec-1" "$(calls)"
hasnt "…"                                        "ADD APP-1" "$(calls)"

echo "── T8: --description and --dry-run"
run TRACKER_MAX_DESCRIPTION_CHARS=500 -- APP-1 --description "$(rep d 501)"
is "--description over the cap is refused"       "1" "$rc"
has "…naming the cap"                            "the cap is 500" "$out"
hasnt "…and nothing is written"                  "UPSERT" "$(calls)"
run TRACKER_MAX_DESCRIPTION_CHARS=500 -- APP-1 --body "$big" --dry-run
is "dry run: exit 0"                             "0" "$rc"
has "dry run: says what it would attach"         "DRY RUN — attach APP-1-details.md" "$out"
hasnt "dry run: attaches nothing"                "ATTACH" "$(calls)"
hasnt "dry run: removes nothing"                 "REMOVE" "$(calls)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
