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
  --effort <name>      Set the overall effort/size field (provider-dependent; optional).
  --dev-points <n>     Set the Developer-points number field (estimation; optional).
  --qa-points <n>      Set the QA-points number field (estimation; optional).
  --title <text>       Set the ticket title / summary.
  --description <text> Set the one-line description / summary field.
  --parent <KEY>       Create the new issue as a CHILD of this parent ticket (Jira: the
                       parent issue / sub-task parent; Notion: the parent-item relation).
                       Create-only — use with the ref "new".
  --issuetype <name>   Create with this issue type (Jira: fields.issuetype; Notion: the
                       Type property). Create-only. Overrides --subtask if both given.
  --subtask            Create the new issue as the project's SUB-TASK type under --parent
                       (resolved from the provider). Create-only; requires --parent.
  --component <name>   Add a component/tag (Jira: project component, validated;
                       Notion: a multi_select option). Repeatable.
  --link <TYPE>:<KEY>  Link the new issue to <KEY> as the outward subject — e.g.
                       --link Implements:APP-123 means "<new> implements APP-123".
                       Repeatable. Jira: an issue link (closest type if exact missing);
                       Notion: a relation. Create-only.
  --body <markdown>    Write the full spec (Markdown) into the ticket BODY. Notion
                       appends page blocks; Jira renders it as the issue description.
                       Supports headings, bullet/numbered/to-do lists, quotes,
                       dividers and fenced code blocks.
  --body-file <path>   Same as --body, but read the Markdown from a file ("-" = stdin).
  --dry-run            Print the request body instead of sending it.
  -h, --help           Show this help and exit.

Behavior:
  Pass the ref "new" (or any ref that does not resolve, on Notion) with --title to
  CREATE a ticket — its number/key is auto-assigned. Pass at least one property flag
  or --body.

Environment:
  TRACKER_PROVIDER     notion | jira (default: notion). Provider creds live in .env.
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
components_json='[]'; links_json='[]'
addcomp() { components_json="$(jq -n --argjson cur "$components_json" --arg v "$1" '$cur + [$v]')"; }
addlink() { links_json="$(jq -n --argjson cur "$links_json" --arg t "$1" --arg k "$2" '$cur + [{type: $t, key: $k}]')"; }

ticket=""; dry=0; body_md=""; have_body=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)      need "${2:-}" "--status needs a value";      setf status      "$2"; shift 2 ;;
    --priority)    need "${2:-}" "--priority needs a value";    setf priority    "$2"; shift 2 ;;
    --effort)      need "${2:-}" "--effort needs a value";      setf effort      "$2"; shift 2 ;;
    --dev-points)  need "${2:-}" "--dev-points needs a number"; setf dev_points  "$2"; shift 2 ;;
    --qa-points)   need "${2:-}" "--qa-points needs a number";  setf qa_points   "$2"; shift 2 ;;
    --title)       need "${2:-}" "--title needs a value";       setf title       "$2"; shift 2 ;;
    --description) need "${2:-}" "--description needs a value"; setf description "$2"; shift 2 ;;
    --parent)      need "${2:-}" "--parent needs a ticket key"; setf parent      "$2"; shift 2 ;;
    --issuetype)   need "${2:-}" "--issuetype needs a value";   setf issuetype   "$2"; shift 2 ;;
    --subtask)     setf subtask true; shift ;;
    --component)   need "${2:-}" "--component needs a value";   addcomp "$2"; shift 2 ;;
    --link)        need "${2:-}" "--link needs <TYPE>:<KEY>";
                   _lt="${2%%:*}"; _lk="${2#*:}"
                   [[ "$2" == *:* && -n "$_lt" && -n "$_lk" ]] \
                     || die "--link must be TYPE:KEY (e.g. Implements:APP-123)"
                   addlink "$_lt" "$_lk"; shift 2 ;;
    --body)        need "${2:-}" "--body needs a value";        body_md="$2"; have_body=1; shift 2 ;;
    --body-file)   need "${2:-}" "--body-file needs a path";
                   if [[ "$2" == "-" ]]; then body_md="$(cat)"; else [[ -f "$2" ]] || die "--body-file: no such file: $2"; body_md="$(cat "$2")"; fi
                   have_body=1; shift 2 ;;
    --dry-run)     dry=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "unknown option: $1   (see -h)" ;;
    *)             ticket="$1"; shift ;;
  esac
done

# Fold the repeatable relations into the abstract field set (omit when empty).
fields="$(jq -n --argjson cur "$fields" --argjson comps "$components_json" --argjson links "$links_json" \
  '$cur
   + (if ($comps | length) > 0 then {components: $comps} else {} end)
   + (if ($links | length) > 0 then {links: $links}      else {} end)')"

[[ -n "$ticket" ]] || die "usage: $(basename "$0") <ticket> [options]   (see -h)"
[[ "$fields" != "{}" || "$have_body" -eq 1 ]] \
  || die "nothing to update — pass at least one property flag or --body (see -h)"

tracker_upsert "$ticket" "$dry" "$fields" "$body_md"
