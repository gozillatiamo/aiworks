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
#   tracker_edit_comment  KEY COMMENT_ID DRY TEXT
#                                           — replace an existing comment's body (Jira; Notion/Linear die loud)
#   tracker_get_attachments KEY             — list a ticket's attachments/images (filename, id, size) —
#                                             CORE input, fetch before treating a ticket as understood
#   tracker_download_attachment KEY REF DEST — download one attachment (REF = filename, id, or URL
#                                             per provider) to a local path DEST, for viewing (e.g. Read)
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
tracker_require_config
