#!/usr/bin/env bash
# Tracker adapter — shared dispatch for the ticket scripts.
# Sourced by the entry scripts (get/upsert/add/get-comments); not meant to run alone.
#
# Selects a provider implementation by TRACKER_PROVIDER (notion | jira) and sources
# scripts/tracker/<provider>/impl.sh, which defines the provider interface that the
# entry scripts call:
#
#   tracker_require_config                  — validate the provider's env, die if missing
#   tracker_get_details   KEY               — print title + properties/fields + body (plain text)
#   tracker_get_comments  DEEP KEY          — print comments (DEEP = 0|1; providers may ignore DEEP)
#   tracker_upsert        KEY DRY FIELDS [BODY_MD]
#                                           — FIELDS = JSON {status,priority,effort,dev_points,
#                                             qa_points,sprint,title,description}; BODY_MD (optional)
#                                             = Markdown spec written to the page BODY / issue
#                                             description (--body / --body-file)
#   tracker_find          OPTS             — OPTS = JSON {query,open,limit,as_json,types:[...]};
#                                             print matching tickets newest-first (the dedup search)
#   tracker_add_comment   KEY DRY TEXT      — add one comment
#   tracker_add_attachment KEY DRY FILE     — upload a local file as an attachment (Jira; Notion dies loud)
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

# Which tracker backs this workspace. Defaults to notion to match the reference setup.
TRACKER_PROVIDER="${TRACKER_PROVIDER:-notion}"
IMPL="$TRACKER_DIR/$TRACKER_PROVIDER/impl.sh"
[[ -f "$IMPL" ]] || die "unknown TRACKER_PROVIDER '$TRACKER_PROVIDER' (no $IMPL) — use 'notion' or 'jira', or add an impl.sh under scripts/tracker/$TRACKER_PROVIDER/"

# shellcheck disable=SC1090
. "$IMPL"
tracker_require_config

# Resolve the workspace output-language policy the SAME way the session hook does
# (.claude/hooks/resolve-language.sh), for write-time enforcement in the adapter.
# Precedence: explicit WORKSPACE_LANGUAGE env > the hook's cached resolution
# (.claude/.resolved-language) > workspace.config.local.yaml > workspace.config.yaml > "en".
# Degrades OPEN: any path that cannot positively resolve `th` returns "en", so the gate
# never blocks a workspace it can't confirm is Thai (e.g. a worktree without the personal
# override). Prints the resolved code (th|en|…) on stdout.
resolve_output_language() {
  if [[ -n "${WORKSPACE_LANGUAGE:-}" ]]; then printf '%s\n' "$WORKSPACE_LANGUAGE"; return; fi

  local root="${CLAUDE_PROJECT_DIR:-}"
  if [[ -z "$root" ]]; then
    # Walk up from the tracker dir to the workspace root (the dir holding the configs).
    local d="$TRACKER_DIR"
    while [[ "$d" != "/" ]]; do
      [[ -f "$d/workspace.config.yaml" || -f "$d/.claude/.resolved-language" ]] && { root="$d"; break; }
      d="$(dirname "$d")"
    done
  fi
  [[ -n "$root" ]] || { echo "en"; return; }

  if [[ -s "$root/.claude/.resolved-language" ]]; then
    head -n1 "$root/.claude/.resolved-language" | tr -d '[:space:]'; return
  fi

  local f lang=""
  for f in "$root/workspace.config.local.yaml" "$root/workspace.config.yaml"; do
    [[ -f "$f" ]] || continue
    lang="$(grep -m1 -E '^language:' "$f" 2>/dev/null \
      | sed -E 's/^language:[[:space:]]*"?'"'"'?([a-zA-Z_-]+)"?'"'"'?.*/\1/')"
    [[ -n "$lang" ]] && { printf '%s\n' "$lang"; return; }
  done
  echo "en"
}

# Write-time language gate: under a `th` policy, a ticket BODY must not be all-English
# prose. Strips fenced/inline code and heading lines (the legitimate English spine), then
# blocks only the stark failure — substantial prose with ZERO Thai characters. A body with
# ANY Thai prose passes, so this never fires on a correctly bilingual (English-spine) ticket;
# a pure-code / heading-only body has no prose to judge and also passes. Dies loud on a
# violation (adapter convention) unless the caller opts out. Args: BODY_MD.
tracker_assert_body_language() {
  local body="$1"
  [[ -n "$body" ]] || return 0
  [[ "${TRACKER_SKIP_LANGUAGE_CHECK:-0}" == "1" ]] && return 0
  [[ "$(resolve_output_language)" == "th" ]] || return 0
  command -v perl >/dev/null || return 0   # no perl → skip rather than false-block

  local counts thai nonspace
  counts="$(printf '%s' "$body" | perl -CS -0777 -e '
    my $b = do { local $/; <STDIN> };
    $b =~ s/```.*?```//gs;                 # fenced code
    $b =~ s/`[^`]*`//g;                    # inline code
    my @l = grep { !/^\s*#{1,6}\s/ } split /\n/, $b;   # heading lines
    my $p = join "\n", @l;
    my $t = () = $p =~ /\p{Thai}/g;
    my $n = () = $p =~ /\S/g;
    print "$t $n\n";
  ' 2>/dev/null)" || return 0
  thai="${counts%% *}"; nonspace="${counts##* }"
  [[ "$thai" =~ ^[0-9]+$ && "$nonspace" =~ ^[0-9]+$ ]] || return 0

  if [[ "$thai" -eq 0 && "$nonspace" -ge 80 ]]; then
    die "language gate: output policy is 'th' but this ticket body is all-English prose ($nonspace prose chars, 0 Thai). Rewrite the prose in Thai (English spine — headings/labels/code/identifiers/versions stay English; see docs/agents/language.md). Override with TRACKER_SKIP_LANGUAGE_CHECK=1 only if this body is genuinely spine-only."
  fi
}

# Write-time PII egress gate. Production-derived data must not leave the prod boundary into a
# ticket (which fans out to Jira/Slack). Blocks external-world PII in value form — phone,
# email, crypto wallet, IBAN/bank account, formatted national-id/passport — via the shared
# scanner (scripts/lib/pii-scan.sh). Inner-system identity (player_code/site_code/*_code,
# internal UUID), reproduce SQL, aggregate stats, and money integers all PASS: those are the
# ground truth a triage summary legitimately needs and identify no real-world person. Dies
# loud on a hit (adapter convention), naming only the matched CATEGORY, never the value (that
# would itself leak PII into the transcript). Break-glass: TRACKER_SKIP_PII_CHECK=1 — human
# only, for a genuine false positive; an agent must instead rewrite as an aggregate. Args: TEXT.
tracker_assert_no_pii() {
  local text="$1"
  [[ -n "$text" ]] || return 0
  [[ "${TRACKER_SKIP_PII_CHECK:-0}" == "1" ]] && return 0
  local scanner="$TRACKER_DIR/../lib/pii-scan.sh"
  [[ -f "$scanner" ]] || return 0   # scanner absent → degrade open, never false-block
  # shellcheck disable=SC1090
  . "$scanner"
  if ! pii_scan_text "$text"; then
    die "PII egress gate: this ticket text carries external-world PII ($(pii_scan_categories)) leaving the prod boundary. De-identify first — quote the inner-system identity (player_code/site_code/UUID), an aggregate (counts / GROUP BY), or the reproduce SQL instead of the raw phone/email/wallet/bank value. Break-glass (human only, genuine false positive): TRACKER_SKIP_PII_CHECK=1."
  fi
}
