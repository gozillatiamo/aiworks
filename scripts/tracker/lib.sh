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

# Write-time PII egress gate. Production-derived data must not leave the prod boundary into a
# ticket (which fans out to the tracker / Slack). Blocks external-world PII in value form —
# phone, email, crypto wallet, IBAN/bank account, formatted national-id/passport — via the
# shared scanner (scripts/lib/pii-scan.sh). Inner-system identity (any *_code, internal UUID),
# reproduce SQL, aggregate stats, and money integers all PASS: those are the ground truth a
# triage summary legitimately needs and identify no real-world person. Dies loud on a hit
# (adapter convention), naming only the matched CATEGORY, never the value (that would itself
# leak PII into the transcript). Break-glass: TRACKER_SKIP_PII_CHECK=1 — human only, for a
# genuine false positive; an agent must instead rewrite as an aggregate. Args: TEXT.
tracker_assert_no_pii() {
  local text="$1"
  [[ -n "$text" ]] || return 0
  [[ "${TRACKER_SKIP_PII_CHECK:-0}" == "1" ]] && return 0
  local scanner="$TRACKER_DIR/../lib/pii-scan.sh"
  [[ -f "$scanner" ]] || return 0   # scanner absent → degrade open, never false-block
  # shellcheck disable=SC1090
  . "$scanner"
  if ! pii_scan_text "$text"; then
    die "PII egress gate: this ticket text carries external-world PII ($(pii_scan_categories)) leaving the prod boundary. De-identify first — quote the inner-system identity (a *_code / UUID), an aggregate (counts / GROUP BY), or the reproduce SQL instead of the raw phone/email/wallet/bank value. Break-glass (human only, genuine false positive): TRACKER_SKIP_PII_CHECK=1."
  fi
}

# Which tracker backs this workspace. Defaults to notion to match the reference setup.
TRACKER_PROVIDER="${TRACKER_PROVIDER:-notion}"
IMPL="$TRACKER_DIR/$TRACKER_PROVIDER/impl.sh"
[[ -f "$IMPL" ]] || die "unknown TRACKER_PROVIDER '$TRACKER_PROVIDER' (no $IMPL) — use 'notion', 'jira' or 'linear', or add an impl.sh under scripts/tracker/$TRACKER_PROVIDER/"

# shellcheck disable=SC1090
. "$IMPL"
tracker_require_config
