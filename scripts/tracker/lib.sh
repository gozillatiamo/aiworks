#!/usr/bin/env bash
# Tracker adapter — shared dispatch for the ticket scripts.
# Sourced by the entry scripts (get/upsert/add/get-comments); not meant to run alone.
#
# Selects a provider implementation by TRACKER_PROVIDER (notion | jira | linear) and sources
# scripts/tracker/<provider>/impl.sh, which defines the provider interface that the
# entry scripts call:
#
#   tracker_require_config                  — validate the provider's env, die if missing
#   tracker_get_details   KEY               — print title + properties/fields + body (plain text)
#   tracker_get_comments  DEEP KEY          — print comments (DEEP = 0|1; providers may ignore DEEP)
#   tracker_upsert        KEY DRY FIELDS [BODY_MD]
#                                           — FIELDS = JSON {status,priority,effort,title,description};
#                                             BODY_MD (optional) = Markdown spec written to the page
#                                             BODY / issue description (--body / --body-file)
#   tracker_find          OPTS             — OPTS = JSON {query,open,limit,as_json,types:[...]};
#                                             print matching tickets newest-first (the dedup search)
#   tracker_add_comment   KEY DRY TEXT      — add one comment
#   tracker_add_marked    KEY DRY TEXT      — add a DURABLE MARKED RECORD for the first time (the
#                                             thing tracker_find_comment must be able to find
#                                             again). Defaults to tracker_add_comment, because on
#                                             a provider that can rewrite a comment the record IS
#                                             a comment; Notion overrides it, since there the
#                                             record is a page block (its comments cannot be
#                                             updated at all). Only upsert-ticket-comment.sh
#                                             calls this — a one-off note stays add_comment.
#   tracker_edit_comment  KEY COMMENT_ID DRY TEXT
#                                           — replace an existing comment's body in place
#   tracker_get_attachments KEY             — list a ticket's attachments/images (filename, id, size) —
#                                             CORE input, fetch before treating a ticket as understood
#   tracker_download_attachment KEY REF DEST — download one attachment (REF = filename, id, or URL
#                                             per provider) to a local path DEST, for viewing (e.g. Read)
#   tracker_remove_attachment KEY DRY REF    — DESTRUCTIVE: delete one attachment (REF = filename or id)
#   tracker_delete_ticket KEY DRY SUBTASKS   — DESTRUCTIVE: delete the whole ticket (SUBTASKS = 0|1)
#   tracker_comments_for_block BLOCK_ID     — internal --deep worker (no-op for providers without it)
#
# A ticket KEY is provider-neutral: a full key (FM-9 / APP-123), a bare number, or a
# tracker URL/page id — each impl normalizes it.

set -euo pipefail

TRACKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load a .env sitting next to these scripts, if present (git-ignored local config).
if [[ -f "$TRACKER_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$TRACKER_DIR/.env"
  set +a
fi

die() { echo "error: $*" >&2; exit 1; }
command -v jq   >/dev/null || die "jq is required (brew install jq)"
command -v curl >/dev/null || die "curl is required"

# Write-time PII egress redaction. PRODUCTION-derived personal data must not leave the prod
# boundary into a ticket (which fans out to the tracker / Slack) — but data from local or
# staging is test/mock data and is explicitly fine, and those flows run in PARALLEL with prod
# work all day, so a shape-only gate blocks the wrong things.
#
# So provenance decides, not shape: scripts/lib/pii_provenance.py masks a value if and only if
# a sanctioned prod-read path (the pg-triage MCP, the repro seed) actually saw that value
# and vaulted its keyed hash. A seeded local fixture address is untouched; a real personal
# address is redacted to `<prod-pii:email>` wherever it turns up, in any session or ticket.
#
# It MASKS rather than dies: the write still lands, minus the personal value, and the caller
# is told on stderr what was redacted (category + count — never the value, which would itself
# leak into the transcript). Inner-system identity (any *_code, internal UUID), reproduce SQL,
# aggregates and money integers are never touched — that ground truth is the whole point of a
# triage summary.
#
# Prints the (possibly redacted) text on stdout, so callers use it as:
#     text="$(tracker_redact_prod_pii "$text")"
# Env: PII_GATE=off disables it entirely; PII_GATE=on additionally masks every shape match
# even with no prod provenance (for a hand-written prod incident report).
# TRACKER_SKIP_PII_CHECK=1 stays as the legacy break-glass. Args: TEXT.
tracker_redact_prod_pii() {
  local text="$1"
  [[ -n "$text" ]] || { printf '%s' "$text"; return 0; }
  if [[ "${TRACKER_SKIP_PII_CHECK:-0}" == "1" || "${PII_GATE:-auto}" == "off" ]]; then
    printf '%s' "$text"; return 0
  fi
  local engine="$TRACKER_DIR/../lib/pii_provenance.py"
  if [[ ! -f "$engine" ]] || ! command -v python3 >/dev/null; then
    printf '%s' "$text"; return 0   # engine absent → pass through; the SOFT prompt layer still applies
  fi

  local masked rc=0
  masked="$(printf '%s' "$text" | python3 "$engine" mask -)" || rc=$?
  if [[ $rc -eq 10 ]]; then
    echo "note: production PII was redacted from this ticket text before writing (see the line above). Prefer quoting an entity code / an aggregate / the reproduce SQL instead." >&2
    printf '%s' "$masked"; return 0
  fi
  if [[ $rc -ne 0 ]]; then
    printf '%s' "$text"; return 0   # engine error → never block a legitimate write
  fi
  printf '%s' "$masked"
}

# Which tracker backs this workspace. Defaults to notion to match the reference setup.
TRACKER_PROVIDER="${TRACKER_PROVIDER:-notion}"
IMPL="$TRACKER_DIR/$TRACKER_PROVIDER/impl.sh"
[[ -f "$IMPL" ]] || die "unknown TRACKER_PROVIDER '$TRACKER_PROVIDER' (no $IMPL) — use 'notion', 'jira' or 'linear', or add an impl.sh under scripts/tracker/$TRACKER_PROVIDER/"

# shellcheck disable=SC1090
. "$IMPL"

# Default for the one interface function most providers do not need to think about: where a
# comment can be rewritten, a durable marked record simply IS a comment. Declared AFTER the impl
# so a provider that defines its own wins.
declare -F tracker_add_marked >/dev/null || tracker_add_marked() { tracker_add_comment "$@"; }

tracker_require_config

# ── Section-scoped records ────────────────────────────────────────────────────────────────
# One durable record can be CO-WRITTEN by several agents: one comment for the whole ticket, one
# `### <repo>` section inside it per repo. A writer owns the block under its own heading and must
# leave every other byte alone, so an update is a SPLICE of that block — never a rewrite of the
# whole body, which is how a parallel sibling's section gets silently dropped.
#
# A section runs from its heading line to the next heading at the SAME level or shallower, so a
# writer is free to use deeper headings (`#### Regression`, `#### History`) inside its own block.
# Heading match is exact, ignoring trailing whitespace. Both helpers are pure text.

# tracker_section_extract BODY HEADING — print the section (heading line included), or nothing.
tracker_section_extract() {
  printf '%s\n' "$1" | _TS_HEAD="$2" awk '
    BEGIN { h = ENVIRON["_TS_HEAD"]; sub(/[ \t]+$/, "", h); match(h, /^#+/); lvl = RLENGTH }
    { line = $0; sub(/[ \t]+$/, "", line) }
    !inside && line == h { inside = 1; print; next }
    inside {
      if (match(line, /^#+ /) && RLENGTH - 1 <= lvl) exit
      print
    }'
}

# tracker_section_splice BODY HEADING SECTION — print BODY with HEADING's block replaced by
# SECTION, or with SECTION appended when the heading is not there yet.
tracker_section_splice() {
  printf '%s\n' "$1" | _TS_HEAD="$2" _TS_SECTION="$3" awk '
    BEGIN { h = ENVIRON["_TS_HEAD"]; sub(/[ \t]+$/, "", h); match(h, /^#+/); lvl = RLENGTH
            repl = ENVIRON["_TS_SECTION"] }
    { line = $0; sub(/[ \t]+$/, "", line) }
    !spliced && line == h { inside = 1; spliced = 1; print repl; print ""; next }
    inside { if (match(line, /^#+ /) && RLENGTH - 1 <= lvl) inside = 0; else next }
    { print }
    END { if (!spliced) { print ""; print repl } }'
}
