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
# Whether a provider can hold a real file on the ticket (Jira). Notion's tracker_add_attachment
# dies and Linear has none, so the description cap falls back to a marked record there.
declare -F tracker_supports_attachments >/dev/null || tracker_supports_attachments() { return 1; }
# The provider's canonical key for a ref (Jira resolves a URL / bare number); default: as given.
declare -F tracker_ticket_key >/dev/null || tracker_ticket_key() { printf '%s' "$1"; }

tracker_require_config

# ── Description size cap ──────────────────────────────────────────────────────────────────
# A description is a short page a human reads in one minute (docs/adr/0044). The cap is
# `tracker.max_description_chars` (default 5000), counted in UTF-16 code units of the Markdown
# source after PII redaction — the unit Jira itself counts in — with inline image tokens
# (`![alt](attachment:…)`) left out, since an image is not text. A body over the cap is SPLIT:
# the part before `## Details` (or, failing that, before the last heading that fits) stays as the
# description with a one-line pointer; the full body lands in ONE `<KEY>-details.md` on the ticket.

# tracker_config_root — the directory holding workspace.config[.example].yaml, walking up from here.
tracker_config_root() {
  local d="$TRACKER_DIR"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/workspace.config.yaml" || -f "$d/workspace.config.example.yaml" ]]; then printf '%s' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# _tracker_yaml_tracker_key FILE KEY — the bare scalar at `tracker:` → `  KEY:`, or nothing.
_tracker_yaml_tracker_key() {
  [[ -f "$1" ]] || return 0
  awk -v k="$2:" '
    /^tracker:/ { inb = 1; next }
    inb && /^[^ \t#]/ { inb = 0 }
    inb && $1 == k { v = $2; gsub(/"/, "", v); print v; exit }' "$1"
}

# tracker_max_description_chars — env TRACKER_MAX_DESCRIPTION_CHARS, else the local override's
# `tracker:` block (shallow per top-level key, ADR 0003: present without the key ⇒ default), else
# the shared config, else 5000. A non-integer or anything under 500 is a WARN and the default.
tracker_max_description_chars() {
  local v="${TRACKER_MAX_DESCRIPTION_CHARS:-}" root
  if [[ -z "$v" ]] && root="$(tracker_config_root)"; then
    if grep -q '^tracker:' "$root/workspace.config.local.yaml" 2>/dev/null; then
      v="$(_tracker_yaml_tracker_key "$root/workspace.config.local.yaml" max_description_chars)"
    else
      v="$(_tracker_yaml_tracker_key "$root/workspace.config.yaml" max_description_chars)"
    fi
  fi
  [[ -n "$v" ]] || { printf '5000'; return 0; }
  if [[ "$v" =~ ^[0-9]+$ && "$v" -ge 500 ]]; then printf '%s' "$v"; return 0; fi
  echo "warn: tracker.max_description_chars '$v' is not an integer of at least 500 — using 5000" >&2
  printf '5000'
}

# tracker_char_count TEXT — UTF-16 code units of TEXT, inline image tokens excluded.
tracker_char_count() {
  [[ -n "${1:-}" ]] || { printf '0'; return 0; }
  printf '%s' "$1" | perl -CS -0777 -ne '
    s/!\[[^\]]*\]\(attachment:[^)]*\)//g;
    my $n = length; $n += () = /[\x{10000}-\x{10FFFF}]/g; print $n'
}

# tracker_split_body LIMIT BODY POINTER — print the core that fits LIMIT: the text before a line
# `## Details`, else before the last heading (outside a ``` fence) that keeps core + blank line +
# POINTER within LIMIT. Exit 3 when no cut fits (the first section alone is over the cap).
tracker_split_body() {
  printf '%s' "$2" | _TS_LIMIT="$1" _TS_POINTER="$3" perl -CS -0777 -ne '
    my ($limit, $pointer) = ($ENV{_TS_LIMIT}, $ENV{_TS_POINTER});
    utf8::decode($pointer); # env is bytes; the record pointer carries a non-ASCII `·`
    sub u16 { my $s = shift; $s =~ s/!\[[^\]]*\]\(attachment:[^)]*\)//g; my $n = length $s; $n += () = $s =~ /[\x{10000}-\x{10FFFF}]/g; $n }
    my @lines = split /\n/, $_, -1;
    my (@cuts, $fence);
    for my $i (0 .. $#lines) {
      my $l = $lines[$i]; $l =~ s/\s+$//;
      if ($l =~ /^```/) { $fence = !$fence; next }
      next if $fence;
      if ($l eq "## Details") { push @cuts, $i; last }
      push @cuts, $i if $i > 0 && $l =~ /^#{1,6} /;
    }
    for my $i (reverse @cuts) {
      my $core = join "\n", @lines[0 .. $i - 1]; $core =~ s/\s+$//;
      my $out = "$core\n\n$pointer";
      if (u16($out) <= $limit) { print $out; exit 0 }
    }
    exit 3'
}

# tracker_upsert_details_file KEY DRY FILE — ONE details file per ticket. With attachments: add
# the new copy first, then remove every older same-name copy by id, so a failed upload never
# loses the old one. Without: the `[details · <KEY>]` durable record (find → edit, else add).
tracker_upsert_details_file() {
  local key="$1" dry="$2" file="$3" name new_id old_id marker text found
  name="$(basename "$file")"
  if tracker_supports_attachments; then
    if [[ "$dry" -eq 1 ]]; then
      printf 'DRY RUN — attach %s to %s, then remove any older copy of the same name\n' "$name" "$key"; return 0
    fi
    new_id="$(tracker_add_attachment "$key" 0 "$file" 1)" || return 1
    [[ -n "$new_id" ]] || die "attached $name to $key but got no attachment id back"
    for old_id in $(tracker_attachment_ids_by_name "$key" "$name"); do
      [[ "$old_id" == "$new_id" ]] && continue
      tracker_remove_attachment "$key" 0 "$old_id" >/dev/null
    done
    printf 'Attached %s to %s  [id %s]\n' "$name" "$key" "$new_id"
    return 0
  fi
  marker="[details · $key]"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — upsert the %s record on %s with the full body\n' "$marker" "$key"; return 0
  fi
  text="**$marker**"$'\n\n'"$(cat "$file")"
  found="$(tracker_find_comment "$key" "$marker" || true)"
  if [[ -n "$found" ]]; then
    tracker_edit_comment "$key" "${found%%$'\n'*}" 0 "$text" "$marker"
  else
    tracker_add_marked "$key" 0 "$text" "$marker"
  fi
}

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
