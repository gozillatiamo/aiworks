#!/usr/bin/env bash
# Upsert a ticket's details in the configured tracker — update it, or create it if missing.
#
#   ./upsert-ticket-details.sh FM-9 --status Testing
#   ./upsert-ticket-details.sh APP-123 --status "In Review" --priority High
#   ./upsert-ticket-details.sh FM-9 --title "New title" --description "Some text"
#   ./upsert-ticket-details.sh FM-30 --title "New ticket" --status "Not started"   # missing → created (Notion)
#   ./upsert-ticket-details.sh FM-9 --status Done --dry-run     # preview, don't send
#   ./upsert-ticket-details.sh new --title "New ticket" --body-file spec.md         # full spec in the body
#
# Property flags are ABSTRACT (status/priority/effort/title/description); each provider
# maps them to its own model (Notion properties; Jira fields + a status transition).
# --body / --body-file carry the full clarified spec (Markdown) into the ticket BODY:
# Notion writes page blocks; Jira renders it as the issue description (one rich field).
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: upsert-ticket-details.sh <ticket> [options]

Update a ticket's properties in the configured tracker (TRACKER_PROVIDER), or create
it if missing where the provider supports it. Pass at least one property flag.

Arguments:
  <ticket>             Ticket key (FM-9, APP-123, a number), a page id, or a URL.

Options:
  --status <name>      Set the workflow status. Use the org's real status name (see
                       docs/agents/issue-tracker.md). Jira moves via a transition.
  --priority <name>    Set Priority (e.g. High / Medium / Low).
  --project <name|id>  Assign the ticket to a project. Linear: resolved by name or id and
                       set on create AND update. Jira/Notion: not a per-ticket field —
                       WARNed and skipped (no silent drop).
  --effort <name>      Set the overall effort/size field (provider-dependent; optional).
  --dev-points <n>     Set the Developer-points number field (estimation; optional).
  --qa-points <n>      Set the QA-points number field (estimation; optional).
  --sprint <id>        Set the Sprint field to this sprint id (Jira; optional). Copy the
                       value straight from another ticket's `get-ticket-details.sh` output
                       ("Sprint: <name> (id <id>)") to keep a split-off piece in the same
                       sprint as the ticket it came from.
  --title <text>       Set the ticket title / summary.
  --description <text> Set the one-line description / summary field.
  --parent <KEY>       Set this ticket's parent (Jira: the parent issue / sub-task parent;
                       Notion: the parent-item relation). On the ref "new" it creates the
                       new issue as a CHILD; on an existing ticket it RE-PARENTS that issue
                       (both providers) — e.g. moving a split-off piece under a freshly
                       created epic.
  --issuetype <name>   Create with this issue type (Jira: fields.issuetype; Notion: the
                       Type property). Create-only. Overrides --subtask if both given.
  --subtask            Create the new issue as the project's SUB-TASK type under --parent
                       (resolved from the provider). Create-only; requires --parent.
  --component <name>   Add a component/tag (Jira: project component, validated;
                       Notion: a multi_select option). Repeatable.
  --label <name>       Add a label/tag. Repeatable. Linear: a workspace label (must already
                       exist; missing → WARN+skip). Jira: an issue label. Notion: a
                       multi_select option (same property as --component).
  --link <TYPE>:<KEY>  Link this issue to <KEY>. <TYPE> can be an outward phrase, putting
                       THIS issue as the subject — e.g. --link Implements:APP-123 means
                       "<this> implements APP-123" — or an inward phrase, putting THIS
                       issue as the object — e.g. --link "is blocked by":APP-123 means
                       "<this> is blocked by APP-123" (Jira shows it under APP-123 as
                       "blocks <this>"). Repeatable. Jira: a real issue link (closest type
                       if the exact phrase is missing), works on both create ("new") and
                       an existing ticket. Notion: a relation (no directional types), works
                       the same either way.
  --body <markdown>    Write the full spec (Markdown) into the ticket BODY. Notion
                       appends page blocks; Jira renders it as the issue description.
                       Supports headings, bullet/numbered/to-do lists, quotes,
                       dividers and fenced code blocks.
  --body-file <path>   Same as --body, but read the Markdown from a file ("-" = stdin).
  --no-carry-media     (Jira) Don't re-append images the new body leaves out. By default a
                       body rewrite carries the old description's images across under an
                       "Attachments (carried over)" divider, so a rewrite cannot lose a
                       pasted screenshot. Pass this when you are deliberately REPLACING or
                       dropping an embedded image (e.g. a re-rendered diagram) — otherwise
                       the predecessor keeps coming back, and writing the body again cannot
                       clear it, since the carry-over reads the description it just wrote.
  --dry-run            Print the request body instead of sending it.
  -h, --help           Show this help and exit.

Behavior:
  Pass the ref "new" (or any ref that does not resolve, on Notion) with --title to
  CREATE a ticket — its number/key is auto-assigned. Pass at least one property flag
  or --body.

Size cap:
  A description is a short page: at most tracker.max_description_chars (default 5000,
  UTF-16 units, image tokens not counted). A --body over the cap keeps the part before
  "## Details" (else before the last heading that fits) plus one pointer line; the full
  body is attached as <KEY>-details.md (Jira) or kept in the "[details · <KEY>]" record
  (Notion, Linear) — one per ticket, replaced on every write. A --description over the
  cap is refused. Env TRACKER_MAX_DESCRIPTION_CHARS overrides the config.

Environment:
  TRACKER_PROVIDER     notion | jira | linear (default: notion). Provider creds live in .env.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

# Accumulate the ABSTRACT field set; the provider impl maps it to its own request.
fields='{}'
setf() { fields="$(jq -n --argjson cur "$fields" --arg k "$1" --arg v "$2" '$cur + {($k): $v}')"; }
need() { [[ -n "${1:-}" ]] || die "$2"; }

# Repeatable child-issue relations accumulate into arrays (merged into $fields below).
components_json='[]'; links_json='[]'; labels_json='[]'
addcomp() { components_json="$(jq -n --argjson cur "$components_json" --arg v "$1" '$cur + [$v]')"; }
addlabel() { labels_json="$(jq -n --argjson cur "$labels_json" --arg v "$1" '$cur + [$v]')"; }
addlink() { links_json="$(jq -n --argjson cur "$links_json" --arg t "$1" --arg k "$2" '$cur + [{type: $t, key: $k}]')"; }

ticket=""; dry=0; body_md=""; have_body=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)      need "${2:-}" "--status needs a value";      setf status      "$2"; shift 2 ;;
    --priority)    need "${2:-}" "--priority needs a value";    setf priority    "$2"; shift 2 ;;
    --project)     need "${2:-}" "--project needs a value";     setf project     "$2"; shift 2 ;;
    --effort)      need "${2:-}" "--effort needs a value";      setf effort      "$2"; shift 2 ;;
    --dev-points)  need "${2:-}" "--dev-points needs a number"; setf dev_points  "$2"; shift 2 ;;
    --qa-points)   need "${2:-}" "--qa-points needs a number";  setf qa_points   "$2"; shift 2 ;;
    --sprint)      need "${2:-}" "--sprint needs a sprint id";  setf sprint      "$2"; shift 2 ;;
    --title)       need "${2:-}" "--title needs a value";       setf title       "$2"; shift 2 ;;
    --description) need "${2:-}" "--description needs a value"; setf description "$2"; shift 2 ;;
    --parent)      need "${2:-}" "--parent needs a ticket key"; setf parent      "$2"; shift 2 ;;
    --issuetype)   need "${2:-}" "--issuetype needs a value";   setf issuetype   "$2"; shift 2 ;;
    --subtask)     setf subtask true; shift ;;
    --component)   need "${2:-}" "--component needs a value";   addcomp "$2"; shift 2 ;;
    --label)       need "${2:-}" "--label needs a value";       addlabel "$2"; shift 2 ;;
    --link)        need "${2:-}" "--link needs <TYPE>:<KEY>";
                   _lt="${2%%:*}"; _lk="${2#*:}"
                   [[ "$2" == *:* && -n "$_lt" && -n "$_lk" ]] \
                     || die "--link must be TYPE:KEY (e.g. Implements:APP-123)"
                   addlink "$_lt" "$_lk"; shift 2 ;;
    --body)        need "${2:-}" "--body needs a value";        body_md="$2"; have_body=1; shift 2 ;;
    --body-file)   need "${2:-}" "--body-file needs a path";
                   if [[ "$2" == "-" ]]; then body_md="$(cat)"; else [[ -f "$2" ]] || die "--body-file: no such file: $2"; body_md="$(cat "$2")"; fi
                   have_body=1; shift 2 ;;
    --no-carry-media) setf no_carry_media true; shift ;;
    --dry-run)     dry=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "unknown option: $1   (see -h)" ;;
    *)             ticket="$1"; shift ;;
  esac
done

# Fold the repeatable relations into the abstract field set (omit when empty).
fields="$(jq -n --argjson cur "$fields" --argjson comps "$components_json" --argjson links "$links_json" --argjson labels "$labels_json" \
  '$cur
   + (if ($comps | length) > 0 then {components: $comps} else {} end)
   + (if ($labels | length) > 0 then {labels: $labels}   else {} end)
   + (if ($links | length) > 0 then {links: $links}      else {} end)')"

[[ -n "$ticket" ]] || die "usage: $(basename "$0") <ticket> [options]   (see -h)"
[[ "$fields" != "{}" || "$have_body" -eq 1 ]] \
  || die "nothing to update — pass at least one property flag or --body (see -h)"

# PII egress redaction: PRODUCTION-derived personal values (phone/email/wallet/bank/
# national-id, and shapeless ones like a name) are redacted to <prod-pii:…> before the body
# leaves the prod boundary. Local/staging test data is untouched — provenance decides, not
# shape. Inner-system identity, aggregates, money integers and reproduce SQL always pass
# (see tracker_redact_prod_pii in lib.sh).
[[ "$have_body" -eq 1 ]] && body_md="$(tracker_redact_prod_pii "$body_md")"

# Size cap (docs/adr/0044): a description is a short page. --description is a one-line field
# and is refused over the cap; a --body over the cap is split into a core plus a pointer, and
# the full body goes to ONE <KEY>-details.md (or the [details · <KEY>] record) after the write.
cap="$(tracker_max_description_chars)"
desc="$(jq -r '.description // ""' <<<"$fields")"
if [[ -n "$desc" ]]; then
  n="$(tracker_char_count "$desc")"
  [[ "$n" -le "$cap" ]] || die "--description is $n characters; the cap is $cap (tracker.max_description_chars). Put the detail in --body under '## Details' instead."
fi
details_file=""; key=""
if [[ "$have_body" -eq 1 ]]; then
  [[ "$ticket" == new ]] || key="$(tracker_ticket_key "$ticket")"
  n="$(tracker_char_count "$body_md")"
  if [[ "$n" -gt "$cap" ]]; then
    if tracker_supports_attachments; then
      pointer="Full details: attached ${key:-<KEY>}-details.md"
    else
      pointer="Full details: see the [details · ${key:-<KEY>}] record on this ticket"
    fi
    core="$(tracker_split_body "$cap" "$body_md" "$pointer")" \
      || die "body is $n characters, the cap is $cap, and no heading boundary keeps the first section under it — put the detail under '## Details' (tracker.max_description_chars)"
    details_file="$(mktemp -d)/${key:-new}-details.md"
    printf '%s\n' "$body_md" > "$details_file"
    echo "note: body is $n characters, over the cap of $cap — the description keeps the first $(tracker_char_count "$core") characters plus a pointer; the full body goes to $(basename "$details_file")" >&2
    body_md="$core"
  elif [[ -n "$key" && "$dry" -eq 0 ]] && tracker_supports_attachments \
       && [[ -n "$(tracker_attachment_ids_by_name "$key" "$key-details.md")" ]]; then
    echo "warn: $key still carries $key-details.md from an earlier over-cap write; this body is under the cap, so that file is now stale — remove it with remove-ticket-attachment.sh if it no longer applies (never deleted automatically)" >&2
  fi
fi

if [[ -z "$details_file" ]]; then
  tracker_upsert "$ticket" "$dry" "$fields" "$body_md"
  exit 0
fi

out="$(tracker_upsert "$ticket" "$dry" "$fields" "$body_md")"
printf '%s\n' "$out"
if [[ -z "$key" ]]; then
  key="$(printf '%s\n' "$out" | sed -n 's/^Created \([A-Za-z][A-Za-z0-9]*-[0-9][0-9]*\).*/\1/p' | head -n1)"
  if [[ -z "$key" ]]; then
    [[ "$dry" -eq 1 ]] && { echo "DRY RUN — attach <KEY>-details.md to the created ticket" >&2; exit 0; }
    die "the body was written with a details pointer, but no created key was found to attach $details_file to — attach it by hand"
  fi
  mv "$details_file" "$(dirname "$details_file")/$key-details.md"; details_file="$(dirname "$details_file")/$key-details.md"
fi
tracker_upsert_details_file "$key" "$dry" "$details_file"
