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
#                                           — FIELDS = JSON {status,priority,effort,dev_points,
#                                             qa_points,sprint,title,description}; BODY_MD (optional)
#                                             = Markdown spec written to the page BODY / issue
#                                             description (--body / --body-file)
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
#   tracker_add_attachment KEY DRY FILE     — upload a local file as an attachment (Jira; Notion dies loud)
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
# boundary into a ticket (which fans out to the tracker / Slack) — but data from local or
# staging is test/mock data and is explicitly fine, and those flows run in PARALLEL with prod
# work all day, so a shape-only gate blocks the wrong things.
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
# writer is free to use deeper headings (`#### Status`, `#### Regression`) inside its own block.
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
