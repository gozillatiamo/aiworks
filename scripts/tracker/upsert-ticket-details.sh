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
  --estimate-reason <text>       The calibration + comparables that justify the story
                       points. REQUIRED whenever --dev-points/--qa-points is set (and only
                       valid with them): points and their reasoning are committed together
                       in this one call — the reason is posted as a comment, then the point
                       fields are written. See /estimate-ticket for the comment shape.
  --estimate-reason-file <path>  Same, read from a file ("-" = stdin).
  --dry-run            Print the request body instead of sending it.
  --skip-language-check  Bypass the write-time language gate (see below). Use only when a
                       body is genuinely spine-only (all code/identifiers, no prose).
  -h, --help           Show this help and exit.

Behavior:
  Pass the ref "new" (or any ref that does not resolve, on Notion) with --title to
  CREATE a ticket — its number/key is auto-assigned. Pass at least one property flag
  or --body.

Environment:
  TRACKER_PROVIDER     notion | jira | linear (default: notion). Provider creds live in .env.
  WORKSPACE_LANGUAGE   Override the resolved output-language policy for the gate below.
  TRACKER_SKIP_LANGUAGE_CHECK=1   Same as --skip-language-check.

Language gate:
  When the resolved output policy is 'th' (WORKSPACE_LANGUAGE, else the session's cached
  .claude/.resolved-language, else workspace.config[.local].yaml), a ticket BODY that is
  all-English prose is REJECTED before it reaches the tracker — the ticket must be Thai
  prose on an English spine (headings/labels/code/identifiers/versions stay English; see
  docs/agents/language.md). A body with any Thai prose, or a pure-spine body with no prose,
  passes. Degrades open: if 'th' can't be positively confirmed, the gate is a no-op.
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

ticket=""; dry=0; body_md=""; have_body=0; estimate_reason=""; have_estimate_reason=0
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
    --estimate-reason) need "${2:-}" "--estimate-reason needs a value"; estimate_reason="$2"; have_estimate_reason=1; shift 2 ;;
    --estimate-reason-file) need "${2:-}" "--estimate-reason-file needs a path";
                   if [[ "$2" == "-" ]]; then estimate_reason="$(cat)"; else [[ -f "$2" ]] || die "--estimate-reason-file: no such file: $2"; estimate_reason="$(cat "$2")"; fi
                   have_estimate_reason=1; shift 2 ;;
    --dry-run)     dry=1; shift ;;
    --skip-language-check) TRACKER_SKIP_LANGUAGE_CHECK=1; shift ;;
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

# Estimation coupling: story points and their justification travel TOGETHER through this one
# call — you cannot set points without recording the reasoning that a human reads when they
# challenge the estimate. Setting points via a bare --dev-points/--qa-points and posting the
# reason as a separate (skippable) add-ticket-comment call was the seam that let calibrated
# numbers land with no recorded basis; requiring --estimate-reason here closes it structurally.
points_set=0
printf '%s' "$fields" | jq -e 'has("dev_points") or has("qa_points")' >/dev/null 2>&1 && points_set=1
if [[ "$points_set" -eq 1 && "$have_estimate_reason" -eq 0 ]]; then
  die "setting story points requires --estimate-reason (or --estimate-reason-file): the calibration + comparables that justify Dev/QA points. An estimate with no recorded reasoning is the inconsistency this guards — see /estimate-ticket for the comment shape."
fi
if [[ "$have_estimate_reason" -eq 1 && "$points_set" -eq 0 ]]; then
  die "--estimate-reason justifies an estimate — pass it together with --dev-points/--qa-points, or use add-ticket-comment.sh for a plain comment."
fi

[[ "$fields" != "{}" || "$have_body" -eq 1 ]] \
  || die "nothing to update — pass at least one property flag or --body (see -h)"

# Under a `th` output policy, refuse all-English prose (see lib.sh). This upsert is the single
# choke point every ticket body flows through, so the gate catches the failure regardless of
# which agent/workflow/model composed it. The estimation reason is posted prose too — gate it.
[[ "$have_body" -eq 1 ]] && tracker_assert_body_language "$body_md"
[[ "$have_estimate_reason" -eq 1 ]] && tracker_assert_body_language "$estimate_reason"

# Same choke point, second gate: PRODUCTION-derived personal values (phone/email/wallet/bank/
# national-id, and shapeless ones like a name) are redacted to <prod-pii:…> before the body
# leaves the prod boundary. Local/staging test data is untouched — provenance decides, not
# shape. Inner-system identity, aggregates, money integers and reproduce SQL always pass
# (see tracker_redact_prod_pii in lib.sh).
[[ "$have_body" -eq 1 ]] && body_md="$(tracker_redact_prod_pii "$body_md")"
[[ "$have_estimate_reason" -eq 1 ]] && estimate_reason="$(tracker_redact_prod_pii "$estimate_reason")"

# Post the reason FIRST, then commit the numbers: if the reason can't be posted we abort
# before writing any point field, so the recoverable failure mode is "reason without number"
# (the reason block itself names the numbers) rather than the silent "number without reason".
[[ "$have_estimate_reason" -eq 1 ]] && tracker_add_comment "$ticket" "$dry" "$estimate_reason"

tracker_upsert "$ticket" "$dry" "$fields" "$body_md"
