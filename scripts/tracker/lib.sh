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

# Write-time PII egress redaction. PRODUCTION-derived personal data must not leave the prod
# boundary into a ticket (which fans out to Jira/Slack) — but data from local or staging is
# test/mock data and is explicitly fine, and those flows run in PARALLEL with prod work all
# day, so a shape-only gate blocks the wrong things.
#
# So provenance decides, not shape: scripts/lib/pii_provenance.py masks a value if and only if
# a sanctioned prod-read path (the pg-triage MCP, `--env prod` observability, the repro
# seed) actually saw that value and vaulted its keyed hash. A seeded local `player1@test.com`
# is untouched; the real player's address is redacted to `<prod-pii:email>` wherever it turns
# up, in any session or ticket.
#
# It MASKS rather than dies: the write still lands, minus the personal value, and the caller
# is told on stderr what was redacted (category + count — never the value, which would itself
# leak into the transcript). Inner-system identity (player_code/site_code/*_code, internal
# UUID), reproduce SQL, aggregates and money integers are never touched — that ground truth is
# the whole point of a triage summary.
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
    echo "note: production PII was redacted from this ticket text before writing (see the line above). Prefer quoting player_code / an aggregate / the reproduce SQL instead." >&2
    printf '%s' "$masked"; return 0
  fi
  if [[ $rc -ne 0 ]]; then
    printf '%s' "$text"; return 0   # engine error → never block a legitimate write
  fi
  printf '%s' "$masked"
}
