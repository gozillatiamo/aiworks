#!/usr/bin/env bash
# Jira implementation of the tracker interface (sourced by ../lib.sh).
# Talks to the Jira Cloud REST API v3 with curl + jq; renders ADF via jira.jq.
#
# Config (env or ../.env):
#   JIRA_BASE_URL     e.g. https://acme.atlassian.net   (required)
#   JIRA_EMAIL        Atlassian account email           (required)
#   JIRA_API_TOKEN    API token                         (required)
#                     create at id.atlassian.com/manage-profile/security/api-tokens
#   JIRA_PROJECT_KEY  project key (e.g. APP) — used to expand a bare number to KEY-n
#   JIRA_EFFORT_FIELD optional custom-field id for --effort (e.g. customfield_10016 / story points)
#   JIRA_DEV_POINTS_FIELD optional custom-field id for --dev-points (Developer points; number)
#   JIRA_QA_POINTS_FIELD  optional custom-field id for --qa-points  (QA points; number)
#   JIRA_SPRINT_FIELD     optional custom-field id for --sprint (the Agile "Sprint" field).
#                     Read as the current/last sprint's id+name; written as a bare sprint id
#                     (an integer, not the array GET returns) — e.g. copy an original ticket's
#                     sprint onto a freshly split-off piece.
#                     find the ids with jira/discover-fields.sh; when one is unset the
#                     matching flag is WARNed + listed under "Skipped:" (not dropped silently).
#   JIRA_SUBTASK_ISSUETYPE optional sub-task issue type NAME for --subtask (e.g. "Sub-task").
#                     When unset, --subtask resolves the project's sub-task type from the API.
#
# Child issues (ref "new"): --parent <KEY> sets fields.parent; --subtask uses the project's
# sub-task type (or --issuetype <name> for any type); --component <name> (repeatable) sets
# fields.components after validating each against the project; --link <TYPE>:<KEY> (repeatable)
# creates an issue link. <TYPE> may be a link type's NAME or OUTWARD phrase (e.g. "Blocks" —
# the calling/new issue is the subject: "<this> blocks <KEY>") or its INWARD phrase (e.g.
# "is blocked by" — the calling/new issue is the object: "<KEY> blocks <this>", i.e. "<this>
# is blocked by <KEY>"). jira_resolve_link_type detects which phrasing was used and swaps
# the outward/inward sides accordingly.
#
# --parent and --link also work on an UPDATE (re-parent an existing issue, or add a link to
# one) — Jira's fields.parent is writable via PUT, and an issue link is its own POST
# /issueLink call independent of the issue body, so neither needs the issue to be freshly
# created. --subtask/--issuetype/--component stay create-only (retyping/re-componenting an
# existing issue isn't the same one-field PUT).
#
# Status is set via a Jira transition (Jira moves by transition, not by writing the
# field). --status must name the TARGET status (or the transition name); the impl finds
# the matching transition. The phase→status mapping lives in docs/agents/issue-tracker.md.

JIRA_IMPL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JIRA_BASE_URL="${JIRA_BASE_URL:-}"
JIRA_EMAIL="${JIRA_EMAIL:-}"
JIRA_API_TOKEN="${JIRA_API_TOKEN:-}"
JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-}"
JIRA_EFFORT_FIELD="${JIRA_EFFORT_FIELD:-}"
JIRA_DEV_POINTS_FIELD="${JIRA_DEV_POINTS_FIELD:-}"
JIRA_QA_POINTS_FIELD="${JIRA_QA_POINTS_FIELD:-}"
JIRA_SPRINT_FIELD="${JIRA_SPRINT_FIELD:-}"
JIRA_DEFAULT_ISSUETYPE="${JIRA_DEFAULT_ISSUETYPE:-Task}"
JIRA_SUBTASK_ISSUETYPE="${JIRA_SUBTASK_ISSUETYPE:-}"   # --subtask type; "" → resolve from API

tracker_require_config() {
  [[ -n "$JIRA_BASE_URL" ]]  || die "JIRA_BASE_URL is not set (e.g. https://acme.atlassian.net)"
  [[ -n "$JIRA_EMAIL" ]]     || die "JIRA_EMAIL is not set"
  [[ -n "$JIRA_API_TOKEN" ]] || die "JIRA_API_TOKEN is not set — create one at https://id.atlassian.com/manage-profile/security/api-tokens"
  JIRA_BASE_URL="${JIRA_BASE_URL%/}" # tolerate a trailing slash
}

jira_jqm() { jq -L "$JIRA_IMPL_DIR" -r 'include "jira"; '"$1"; }

# jira_api METHOD PATH [JSON_BODY] -> prints JSON response; exits on HTTP >= 400.
jira_api() {
  local method="$1" path="$2" body="${3:-}"
  local tmp err http
  tmp="$(mktemp)"; err="$(mktemp)"
  local -a args=(
    -sS -X "$method"
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN"
    -H "Accept: application/json"
    -H "Content-Type: application/json"
    -o "$tmp" -w '%{http_code}'
  )
  [[ -n "$body" ]] && args+=(--data "$body")
  local attempt=0
  while :; do
    if ! http="$(curl "${args[@]}" "$JIRA_BASE_URL$path" 2>"$err")"; then
      rm -f "$tmp"; echo "error: request to $path failed: $(cat "$err")" >&2; rm -f "$err"; exit 1
    fi
    case "${http:-000}" in
      429|502|503) if (( attempt < 5 )); then attempt=$((attempt + 1)); sleep "$attempt"; continue; fi ;;
    esac
    break
  done
  rm -f "$err"
  if [[ "${http:-000}" -ge 400 ]]; then
    echo "error: Jira API $method $path -> HTTP $http" >&2
    jq -r '(.errorMessages // [])[]? , ((.errors // {}) | to_entries[]? | "\(.key): \(.value)")' "$tmp" >&2 2>/dev/null || cat "$tmp" >&2
    rm -f "$tmp"; exit 1
  fi
  cat "$tmp"; rm -f "$tmp"
}

# Normalize a ticket ref to a Jira issue key (PROJ-123). Accepts a full key, a bare
# number (expanded with JIRA_PROJECT_KEY), or a browse URL.
jira_key() {
  local raw="$1" tail num
  # a browse URL like https://x.atlassian.net/browse/APP-12 -> take the last path segment
  tail="${raw##*/}"
  if [[ "$tail" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ ]]; then
    printf '%s' "$(printf '%s' "$tail" | tr '[:lower:]' '[:upper:]')"; return
  fi
  num="${raw//[^0-9]/}"
  [[ -n "$num" ]] || die "could not parse a Jira key from '$raw' (try APP-123 or 123)"
  [[ -n "$JIRA_PROJECT_KEY" ]] || die "bare number '$raw' needs JIRA_PROJECT_KEY set to build the key (e.g. APP)"
  printf '%s-%s' "$JIRA_PROJECT_KEY" "$num"
}

# ── tracker interface ───────────────────────────────────────────────────────

tracker_get_details() {
  local key issue fields_q f
  key="$(jira_key "$1")"
  # Append the configured point/effort field ids so the estimate is visible (e.g. for
  # /estimate-ticket re-estimation) — the endpoint returns only the fields requested.
  fields_q="summary,status,priority,assignee,labels,issuetype,description,parent,issuelinks"
  for f in "$JIRA_DEV_POINTS_FIELD" "$JIRA_QA_POINTS_FIELD" "$JIRA_EFFORT_FIELD" "$JIRA_SPRINT_FIELD"; do
    [[ -n "$f" ]] && fields_q="$fields_q,$f"
  done
  issue="$(jira_api GET "/rest/api/3/issue/$key?fields=$fields_q")"
  printf '%s' "$issue" | jq -L "$JIRA_IMPL_DIR" -r --arg base "$JIRA_BASE_URL" 'include "jira"; issue_details_text($base)'
  # Estimate line (only fields that are configured AND set), appended after the body.
  printf '%s' "$issue" | jq -r \
    --arg dpf "$JIRA_DEV_POINTS_FIELD" --arg qpf "$JIRA_QA_POINTS_FIELD" --arg ef "$JIRA_EFFORT_FIELD" '
    [ (if ($dpf|length>0) and (.fields[$dpf]!=null) then "Dev: \(.fields[$dpf])" else empty end),
      (if ($qpf|length>0) and (.fields[$qpf]!=null) then "QA: \(.fields[$qpf])"  else empty end),
      (if ($ef|length>0)  and (.fields[$ef]!=null)  then "Effort: \(.fields[$ef])" else empty end) ]
    | if length>0 then "\nEstimate:  " + join("  ·  ") else empty end'
  # Sprint line — the field GETs as an array of sprint objects; show the last (current) one
  # and its bare id, so a caller can round-trip that id straight into --sprint on another ticket.
  printf '%s' "$issue" | jq -r --arg sf "$JIRA_SPRINT_FIELD" '
    if ($sf|length) > 0 and (.fields[$sf]? // [] | length) > 0
    then (.fields[$sf] | last) as $s | "\nSprint:  \($s.name // "—") (id \($s.id // "—"))"
    else empty end'
}

# Jira has a single comment stream (no block-anchored comments), so --deep is ignored.
tracker_comments_for_block() { : ; }

tracker_get_comments() {
  local key resp
  key="$(jira_key "$2")"
  resp="$(jira_api GET "/rest/api/3/issue/$key/comment")"
  printf '%s' "$resp" | jira_jqm 'comments_text'
}

# Warn LOUDLY when an estimation flag was supplied but its custom-field id env is unset,
# so the value would otherwise be silently dropped from the Jira `fields` object. Prints
# a WARN per offending flag to stderr AND a machine-detectable "Skipped: <flags>" line to
# stdout so callers (e.g. /estimate-ticket) can see the field never persisted instead of
# trusting a success exit. Maps each abstract field → its JIRA_*_FIELD env + the flag.
jira_warn_dropped_fields() {
  local fields="$1" spec key env flag envname present
  local -a skipped=()
  for spec in \
    "effort|$JIRA_EFFORT_FIELD|--effort|JIRA_EFFORT_FIELD" \
    "dev_points|$JIRA_DEV_POINTS_FIELD|--dev-points|JIRA_DEV_POINTS_FIELD" \
    "qa_points|$JIRA_QA_POINTS_FIELD|--qa-points|JIRA_QA_POINTS_FIELD" \
    "sprint|$JIRA_SPRINT_FIELD|--sprint|JIRA_SPRINT_FIELD"; do
    IFS='|' read -r key env flag envname <<<"$spec"
    present="$(printf '%s' "$fields" | jq -r --arg k "$key" '((.[$k] // "") | tostring | length) > 0')"
    if [[ "$present" == "true" && -z "$env" ]]; then
      echo "WARN: $flag ignored — $envname not set in scripts/tracker/.env (run jira/discover-fields.sh to find the id)" >&2
      skipped+=("$flag")
    fi
  done
  if [[ ${#skipped[@]} -gt 0 ]]; then
    local joined; joined="$(printf '%s, ' "${skipped[@]}")"
    printf 'Skipped: %s\n' "${joined%, }"
  fi
  return 0
}

tracker_upsert() {
  local ticket="$1" dry="$2" fields="$3" body_md="${4:-}" key status jfields
  status="$(printf '%s' "$fields" | jq -r '.status // empty')"

  # Surface any estimation flag whose field-id env is unset (loud + a "Skipped:" line)
  # before doing anything — covers both the create ("new") and update paths, dry or not.
  jira_warn_dropped_fields "$fields"

  # ref "new" → create a fresh issue in JIRA_PROJECT_KEY (the key is server-assigned,
  # mirroring Notion's auto-id create). Requires --title.
  if [[ "$ticket" =~ ^[Nn][Ee][Ww]$ ]]; then
    jira_create "$dry" "$fields" "$body_md"
    return $?
  fi

  key="$(jira_key "$ticket")"

  # Most child-issue flags (issuetype/subtask/component) only apply when CREATING (ref
  # "new"). On an update, say so loudly rather than dropping them silently. --parent and
  # --link are the exceptions: Jira's fields.parent is writable via PUT (re-parents an
  # existing issue, e.g. moving a split ticket under a freshly created epic), and issue
  # links are their own POST /issueLink call independent of the issue's other fields — so
  # --link works here too (e.g. wiring an "is blocked by" dependency onto the reused
  # original ticket in a split, which is only ever updated, never created).
  local _createonly links_json
  _createonly="$(printf '%s' "$fields" | jq -r '
    [ (if .issuetype then "--issuetype" else empty end),
      (if .subtask   then "--subtask"   else empty end),
      (if (.components // [] | length) > 0 then "--component" else empty end)
    ] | join(", ")')"
  [[ -n "$_createonly" ]] && echo "WARN: $_createonly ignored — only applied when creating (ref \"new\"), not on updates" >&2
  links_json="$(printf '%s' "$fields" | jq -c '.links // []')"

  # A PUT replaces the whole description field, so any editor-pasted images/attachments
  # already in it must be carried across a rewrite or they are lost for good (APP-1952).
  # Fetch the existing description's media blocks first; re-appended below. Only relevant
  # when we are actually rewriting the body (--body / --body-file).
  local existing_media='[]'
  if [[ -n "$body_md" ]]; then
    local _cur
    _cur="$(jira_api GET "/rest/api/3/issue/$key?fields=description" 2>/dev/null || true)"
    existing_media="$(printf '%s' "$_cur" | jq -L "$JIRA_IMPL_DIR" -c 'include "jira"; ((.fields.description // {}) | adf_media_blocks)' 2>/dev/null || echo '[]')"
    [[ -n "$existing_media" && "$existing_media" != "null" ]] || existing_media='[]'
    local _nm; _nm="$(printf '%s' "$existing_media" | jq 'length' 2>/dev/null || echo 0)"
    [[ "${_nm:-0}" -gt 0 ]] && echo "Carrying over $_nm image/attachment node(s) from the existing description." >&2
  fi

  # Map the abstract field set (minus status) to a Jira `fields` object. Jira has one
  # rich description field, so the full spec (--body, Markdown→ADF) populates it; a
  # bare --description (no --body) falls back to a plain-text ADF description. Any media
  # carried from the previous description is re-appended so images survive the rewrite.
  jfields="$(printf '%s' "$fields" | jq -L "$JIRA_IMPL_DIR" --arg ef "$JIRA_EFFORT_FIELD" \
    --arg dpf "$JIRA_DEV_POINTS_FIELD" --arg qpf "$JIRA_QA_POINTS_FIELD" --arg sf "$JIRA_SPRINT_FIELD" --arg body "$body_md" \
    --argjson media "$existing_media" '
    include "jira";
    {}
    + (if .title    then {summary: .title} else {} end)
    + (if .priority then {priority: {name: .priority}} else {} end)
    + (if .parent   then {parent: {key: .parent}} else {} end)
    + ( if ($body | length) > 0 then {description: ($body | md_to_adf | adf_append_media($media))}
        elif .description       then {description: (.description | text_to_adf)}
        else {} end )
    + (if (.effort     and ($ef  | length > 0)) then {($ef):  .effort}                else {} end)
    + (if (.dev_points and ($dpf | length > 0)) then {($dpf): (.dev_points | tonumber)} else {} end)
    + (if (.qa_points  and ($qpf | length > 0)) then {($qpf): (.qa_points  | tonumber)} else {} end)
    + (if (.sprint     and ($sf  | length > 0)) then {($sf):  (.sprint     | tonumber)} else {} end)
    ')"

  if [[ "$dry" -eq 1 ]]; then
    [[ "$jfields" != "{}" ]] && printf 'DRY RUN — PUT /rest/api/3/issue/%s\n%s\n' "$key" "$(jq -n --argjson f "$jfields" '{fields: $f}')"
    printf '%s' "$links_json" | jq -r --arg k "$key" '.[]? | "DRY RUN — then POST /rest/api/3/issueLink  (\($k) \(.type) \(.key))"'
    [[ -n "$status" ]] && printf 'DRY RUN — POST /rest/api/3/issue/%s/transitions  (target status: %s)\n' "$key" "$status"
    [[ "$jfields" == "{}" && -z "$status" && "$(printf '%s' "$links_json" | jq 'length')" -eq 0 ]] && printf 'DRY RUN — nothing to change for %s\n' "$key"
    return 0
  fi

  if [[ "$jfields" != "{}" ]]; then
    jira_api PUT "/rest/api/3/issue/$key" "$(jq -n --argjson f "$jfields" '{fields: $f}')" >/dev/null
    printf 'Updated %s\n' "$key"
    printf 'Changed: %s\n' "$(printf '%s' "$jfields" | jq -r 'keys | join(", ")')"
  fi
  jira_create_links "$key" "$links_json"
  [[ -n "$status" ]] && jira_transition "$key" "$status"
  return 0
}

# Create a new issue in JIRA_PROJECT_KEY from the abstract field set. Requires a title.
# A status, if given, is applied as a transition right after creation. A --body
# (Markdown) populates the issue description as ADF (the full spec); a bare
# --description falls back to a plain-text ADF description.
#
# Child-issue support: .parent → fields.parent; .subtask/.issuetype pick the issue type
# (sub-task type resolved from the project unless JIRA_SUBTASK_ISSUETYPE is set); .components
# are validated against the project then set on fields.components; .links create issue links
# after the issue exists (the new issue is the outward/subject side).
jira_create() {
  local dry="$1" fields="$2" body_md="${3:-}" title status parent itype subtask comps_json links_json jfields body resp key comp_fields
  title="$(printf '%s' "$fields" | jq -r '.title // empty')"
  status="$(printf '%s' "$fields" | jq -r '.status // empty')"
  parent="$(printf '%s' "$fields" | jq -r '.parent // empty')"
  itype="$(printf '%s' "$fields" | jq -r '.issuetype // empty')"
  subtask="$(printf '%s' "$fields" | jq -r '.subtask // empty')"
  comps_json="$(printf '%s' "$fields" | jq -c '.components // []')"
  links_json="$(printf '%s' "$fields" | jq -c '.links // []')"
  [[ -n "$title" ]]            || die "creating a Jira issue (ref 'new') needs --title"
  [[ -n "$JIRA_PROJECT_KEY" ]] || die "creating a Jira issue needs JIRA_PROJECT_KEY (e.g. APP)"

  # Resolve the issue type: explicit --issuetype wins; --subtask resolves the project's
  # sub-task type (needs a parent); otherwise the configured default.
  if [[ -n "$itype" ]]; then
    :
  elif [[ "$subtask" == "true" ]]; then
    [[ -n "$parent" ]] || die "--subtask needs --parent <KEY> (a Jira sub-task requires a parent issue)"
    if [[ "$dry" -eq 1 ]]; then
      itype="${JIRA_SUBTASK_ISSUETYPE:-<project sub-task type — resolved on a real run>}"
    else
      itype="$(jira_subtask_type_name)"
    fi
  else
    itype="$JIRA_DEFAULT_ISSUETYPE"
  fi

  # Validate the requested components against the project (real run only) and build the
  # canonical-cased fields.components array. An unknown component is a loud failure.
  comp_fields='[]'
  if [[ "$(printf '%s' "$comps_json" | jq 'length')" -gt 0 ]]; then
    if [[ "$dry" -eq 1 ]]; then
      comp_fields="$(printf '%s' "$comps_json" | jq '[.[] | {name: .}]')"   # unvalidated preview
    else
      comp_fields="$(jira_resolve_components "$comps_json")"
    fi
  fi

  jfields="$(printf '%s' "$fields" | jq -L "$JIRA_IMPL_DIR" \
    --arg proj "$JIRA_PROJECT_KEY" --arg itype "$itype" --arg ef "$JIRA_EFFORT_FIELD" \
    --arg dpf "$JIRA_DEV_POINTS_FIELD" --arg qpf "$JIRA_QA_POINTS_FIELD" --arg sf "$JIRA_SPRINT_FIELD" --arg body "$body_md" \
    --arg parent "$parent" --argjson comps "$comp_fields" '
    include "jira";
    { project: {key: $proj}, issuetype: {name: $itype}, summary: .title }
    + (if ($parent | length) > 0 then {parent: {key: $parent}} else {} end)
    + (if ($comps  | length) > 0 then {components: $comps}     else {} end)
    + (if .priority then {priority: {name: .priority}} else {} end)
    + ( if ($body | length) > 0 then {description: ($body | md_to_adf)}
        elif .description       then {description: (.description | text_to_adf)}
        else {} end )
    + (if (.effort     and ($ef  | length > 0)) then {($ef):  .effort}                else {} end)
    + (if (.dev_points and ($dpf | length > 0)) then {($dpf): (.dev_points | tonumber)} else {} end)
    + (if (.qa_points  and ($qpf | length > 0)) then {($qpf): (.qa_points  | tonumber)} else {} end)
    + (if (.sprint     and ($sf  | length > 0)) then {($sf):  (.sprint     | tonumber)} else {} end)
    ')"
  body="$(jq -n --argjson f "$jfields" '{fields: $f}')"

  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — POST /rest/api/3/issue\n%s\n' "$(printf '%s' "$body" | jq .)"
    printf '%s' "$links_json" | jq -r '.[]? | "DRY RUN — then POST /rest/api/3/issueLink  (new \(.type) \(.key))"'
    [[ -n "$status" ]] && printf 'DRY RUN — then transition the new issue → %s\n' "$status"
    return 0
  fi
  resp="$(jira_api POST "/rest/api/3/issue" "$body")"
  key="$(printf '%s' "$resp" | jq -r '.key // empty')"
  [[ -n "$key" ]] || die "issue create did not return a key"
  printf 'Created %s — %s\n' "$key" "$title"
  [[ -n "$parent" ]] && printf 'Parent: %s\n' "$parent"
  [[ "$(printf '%s' "$comp_fields" | jq 'length')" -gt 0 ]] \
    && printf 'Components: %s\n' "$(printf '%s' "$comp_fields" | jq -r '[.[].name] | join(", ")')"
  jira_create_links "$key" "$links_json"
  [[ -n "$status" ]] && jira_transition "$key" "$status"
  return 0
}

# Resolve the project's SUB-TASK issue type name. JIRA_SUBTASK_ISSUETYPE short-circuits the
# lookup; otherwise ask the project's create-meta (the correct, project-scoped source) and
# fall back to the global issue-type catalog. Every entry carries a `subtask` boolean.
jira_subtask_type_name() {
  [[ -n "$JIRA_SUBTASK_ISSUETYPE" ]] && { printf '%s' "$JIRA_SUBTASK_ISSUETYPE"; return; }
  local resp name
  resp="$(jira_api GET "/rest/api/3/issue/createmeta/$JIRA_PROJECT_KEY/issuetypes")"
  name="$(printf '%s' "$resp" | jq -r '
    (.values // .issueTypes // (if type == "array" then . else [] end))
    | map(select(.subtask == true)) | (.[0].name // empty)')"
  if [[ -z "$name" ]]; then
    resp="$(jira_api GET "/rest/api/3/issuetype")"
    name="$(printf '%s' "$resp" | jq -r 'map(select(.subtask == true)) | (.[0].name // empty)')"
  fi
  [[ -n "$name" ]] || die "no sub-task issue type found for project $JIRA_PROJECT_KEY — enable sub-tasks in Jira, or set JIRA_SUBTASK_ISSUETYPE / pass --issuetype <name>"
  printf '%s' "$name"
}

# Validate requested component names against the project (case-insensitive) and echo the
# Jira components field array [{name: <canonical>}] (canonical casing from the project). A
# name with no match is a loud failure — never invent or silently skip a component.
jira_resolve_components() {
  local comps_json="$1" avail out missing
  avail="$(jira_api GET "/rest/api/3/project/$JIRA_PROJECT_KEY/components")"
  out="$(jq -n --argjson req "$comps_json" --argjson have "$avail" '
    ($have | map({k: (.name | ascii_downcase), name: .name})) as $idx
    | ($req | map(. as $r | ($idx | map(select(.k == ($r | ascii_downcase))) | (.[0].name // null)))) as $resolved
    | { missing: ([$req, $resolved] | transpose | map(select(.[1] == null) | .[0])),
        fields:  ($resolved | map(select(. != null) | {name: .})) }')"
  missing="$(printf '%s' "$out" | jq -r '.missing | join(", ")')"
  if [[ -n "$missing" ]]; then
    die "component(s) not in project $JIRA_PROJECT_KEY: $missing — available: $(printf '%s' "$avail" | jq -r '[.[].name] | join(", ")' 2>/dev/null) (add them in Jira or omit --component)"
  fi
  printf '%s' "$out" | jq -c '.fields'
}

# Create each requested issue link so it reads "<child> <requested-phrase> <other>".
#
# ⚠ Jira's POST /issueLink direction is the OPPOSITE of the field names' intuition (verified
# against the live board): the issue placed in the payload's `inwardIssue` performs the
# OUTWARD action, and `outwardIssue` is its object. So for the DEFAULT case — the child is the
# subject of the type's OUTWARD phrase, e.g. a sub-task that "implements" its parent — the
# child goes in `inwardIssue`. When the requested phrase is the type's INWARD phrase
# (swap=true, e.g. "is blocked by"), the child is the object, so it goes in `outwardIssue`
# instead. Getting this backwards makes an intended "F1 blocks F2" render as "F1 is blocked by
# F2" on the board. Do NOT "simplify" by matching the field names to the phrase names — that
# reverses every directional link. jira_resolve_link_type reports <swap>; the link type name is
# resolved against the project (closest match used and reported on no exact hit).
jira_create_links() {
  local child="$1" links_json="$2" n i ltype other resolved rname rswap rkind types outw inw
  n="$(printf '%s' "$links_json" | jq 'length')"
  [[ "$n" -gt 0 ]] || return 0
  types="$(jira_api GET "/rest/api/3/issueLinkType")"
  for (( i = 0; i < n; i++ )); do
    ltype="$(printf '%s' "$links_json" | jq -r --argjson i "$i" '.[$i].type')"
    other="$(printf '%s' "$links_json" | jq -r --argjson i "$i" '.[$i].key')"
    resolved="$(jira_resolve_link_type "$types" "$ltype")"
    IFS='|' read -r rname rswap rkind <<< "$resolved"
    if [[ "$rswap" == "true" ]]; then outw="$child"; inw="$other"; else outw="$other"; inw="$child"; fi
    jira_api POST "/rest/api/3/issueLink" "$(jq -n --arg t "$rname" --arg o "$outw" --arg w "$inw" \
      '{type: {name: $t}, outwardIssue: {key: $o}, inwardIssue: {key: $w}}')" >/dev/null
    if [[ "$rswap" == "true" ]]; then
      printf 'Linked %s ←[%s]— %s  (%s %s %s)\n' "$child" "$rname" "$other" "$child" "$ltype" "$other"
    else
      printf 'Linked %s —[%s]→ %s\n' "$child" "$rname" "$other"
    fi
    # Only warn when the type was actually SUBSTITUTED (fuzzy/generic fallback) — an exact
    # match on a link type's name OR either directional phrase ("is blocked by" == Blocks'
    # inward phrase) is not a substitution, even though the type NAME differs from the phrase.
    [[ "$rkind" != "exact" ]] && printf '  (requested "%s"; used closest match "%s")\n' "$ltype" "$rname"
  done
  # Explicit success: the loop's last statement is a short-circuit test that leaves a
  # non-zero status on an "exact" match — without this the function returns 1 and, under
  # `set -e`, the whole upsert is treated as failed even though every link was created.
  return 0
}

# Resolve a requested link-type phrase against Jira's real link types — matching the type
# NAME or either directional phrase (outward, e.g. "Blocks"; inward, e.g. "is blocked by"),
# case-insensitive, exact first then closest substring. Prints "<type-name>|<swap>|<kind>":
#   swap — "true" when the requested phrase was the INWARD one, telling jira_create_links the
#          calling issue is the OBJECT of the relation (e.g. "<child> is blocked by <other>")
#          rather than the default SUBJECT ("<child> <outward-phrase> <other>"). See the
#          field-mapping ⚠ note above jira_create_links — the payload fields do NOT match
#          these names.
#   kind — "exact" when the phrase matched a type's name/outward/inward exactly (NOT a
#          substitution — the caller stays quiet); "closest" when it only matched by substring
#          or fell through to the generic Relates fallback (the caller reports the substitution).
# No reasonable match on either → generic fallback to a "Relates"-named type (kind "closest",
# per decompose-ticket's documented "closest existing type" promise for phrases like "Split
# from" that have no dedicated Jira link type). Only a project with no Relates-like type at all
# reaches loud failure listing the available types.
jira_resolve_link_type() {
  local types="$1" want="$2" out
  out="$(printf '%s' "$types" | jq -r --arg w "$want" '
    ($w | ascii_downcase) as $lw
    | (.issueLinkTypes // []) as $lt
    | ( [$lt[] | select((.name|ascii_downcase)==$lw)    | {name, swap:false}]
      + [$lt[] | select((.outward|ascii_downcase)==$lw) | {name, swap:false}]
      + [$lt[] | select((.inward|ascii_downcase)==$lw)  | {name, swap:true}]
      ) as $exact
    | if ($exact | length) > 0 then ($exact[0] + {kind: "exact"})
      else
        ( [ $lt[]
            | . as $t
            | ($t.name|ascii_downcase) as $ln | ($t.outward|ascii_downcase) as $lo | ($t.inward|ascii_downcase) as $li
            | select(($ln|startswith($lw)) or ($lw|startswith($ln)) or ($ln|inside($lw)) or ($lw|inside($ln))
                     or ($lo|startswith($lw)) or ($lw|startswith($lo)) or ($lo|inside($lw)) or ($lw|inside($lo))
                     or ($li|startswith($lw)) or ($lw|startswith($li)) or ($li|inside($lw)) or ($lw|inside($li)))
            | {name: $t.name,
               swap: (($li|startswith($lw)) or ($lw|startswith($li)) or ($li|inside($lw)) or ($lw|inside($li)))}
          ] | sort_by(.name | length) | reverse | (.[0] // null) ) as $fuzzy
        | if $fuzzy != null then ($fuzzy + {kind: "closest"})
          else
            ([$lt[] | select((.name|ascii_downcase)=="relates")] | .[0]) as $rel
            | if $rel != null then {name: $rel.name, swap: false, kind: "closest"} else null end
          end
      end
    | if . != null then "\(.name)|\(.swap)|\(.kind)" else empty end')"
  [[ -n "$out" ]] || die "issue link type '$want' not found in Jira — available: $(printf '%s' "$types" | jq -r '[.issueLinkTypes[]? | "\(.name) (\(.outward) / \(.inward))"] | join(", ")' 2>/dev/null)"
  printf '%s' "$out"
}

# Move an issue to a target status by finding+posting the matching transition.
jira_transition() {
  local key="$1" target="$2" trs id
  trs="$(jira_api GET "/rest/api/3/issue/$key/transitions")"
  id="$(printf '%s' "$trs" | jq -r --arg t "$target" '
    .transitions[]
    | select((.to.name // "" | ascii_downcase) == ($t | ascii_downcase)
             or (.name // "" | ascii_downcase) == ($t | ascii_downcase))
    | .id' | head -n1)"
  [[ -n "$id" ]] || die "no transition to status '$target' on $key — available targets: $(printf '%s' "$trs" | jq -r '[.transitions[].to.name] | join(", ")')"
  jira_api POST "/rest/api/3/issue/$key/transitions" "$(jq -n --arg id "$id" '{transition: {id: $id}}')" >/dev/null
  printf 'Transitioned %s → %s\n' "$key" "$target"
}

tracker_add_comment() {
  local ticket="$1" dry="$2" text="$3" key body cid
  key="$(jira_key "$ticket")"
  # Render the Markdown to ADF (headings, lists, tables, code, inline marks) — a Jira
  # comment body is a full ADF doc, so it renders natively like the issue description.
  body="$(jq -n -L "$JIRA_IMPL_DIR" --arg t "$text" 'include "jira"; {body: ($t | md_to_adf)}')"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — POST /rest/api/3/issue/%s/comment\n%s\n' "$key" "$(printf '%s' "$body" | jq .)"
    return 0
  fi
  resp="$(jira_api POST "/rest/api/3/issue/$key/comment" "$body")"
  cid="$(printf '%s' "$resp" | jq -r '.id // empty')"
  printf 'Added comment to %s (id %s)\n' "$key" "${cid:-?}"
}

# Upload a local file as an issue attachment. Jira's attachments endpoint takes
# multipart/form-data (not JSON), so this bypasses jira_api and curls directly;
# "X-Atlassian-Token: no-check" is required to skip Jira's XSRF check on this endpoint.
tracker_add_attachment() {
  local ticket="$1" dry="$2" file="$3" key tmp err http filename
  [[ -f "$file" ]] || die "no such file: $file"
  key="$(jira_key "$ticket")"
  filename="$(basename "$file")"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — POST /rest/api/3/issue/%s/attachments  (file: %s)\n' "$key" "$file"
    return 0
  fi
  tmp="$(mktemp)"; err="$(mktemp)"
  http="$(curl -sS -X POST \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "X-Atlassian-Token: no-check" \
    -H "Accept: application/json" \
    -F "file=@$file;filename=$filename" \
    -o "$tmp" -w '%{http_code}' \
    "$JIRA_BASE_URL/rest/api/3/issue/$key/attachments" 2>"$err")" || {
      rm -f "$tmp"; die "attachment upload to $key failed: $(cat "$err")"; rm -f "$err"
    }
  rm -f "$err"
  if [[ "$http" -ge 400 ]]; then
    echo "error: Jira API POST /rest/api/3/issue/$key/attachments -> HTTP $http" >&2
    jq -r '(.errorMessages // [])[]? , ((.errors // {}) | to_entries[]? | "\(.key): \(.value)")' "$tmp" >&2 2>/dev/null || cat "$tmp" >&2
    rm -f "$tmp"; exit 1
  fi
  printf 'Attached %s to %s\n' "$filename" "$key"
  rm -f "$tmp"
}

# tracker_find OPTS_JSON — OPTS = {query, open, limit, as_json, types:[...]}.
# Search the project via JQL and print one compact line per match (newest first):
#   "<KEY> | <Status> | <Type> | <Summary>  ::  <Description>", or raw issues JSON.
# The dedup lookup behind /clarifying-ticket. NOTE: Jira's `summary ~` is a word/text
# match (not a raw substring); pick a distinctive whole token.
#
# Uses POST /rest/api/3/search/jql — the enhanced search Atlassian migrated to after
# REMOVING the classic POST /rest/api/3/search (changelog CHANGE-2046; the old endpoint
# now returns HTTP 410). Differences this loop accounts for: pagination is TOKEN-based
# (response carries `nextPageToken` + `isLast`, not `startAt`/`total`); `fields` MUST be
# requested explicitly or the endpoint returns only `id`; and there is no `total` (use
# /rest/api/3/search/approximate-count if a count is ever needed). Pages accumulate into
# a temp file and are combined via stdin slurp (`jq -s`) — never on argv, which would
# blow ARG_MAX once the result set grows. A positive --limit STOPS paging as soon as
# enough issues are collected (only --limit 0 / "all" pages the whole board); the final
# slice trims any overshoot from the last page.
tracker_find() {
  local opts="$1" query open done_only estimated limit as_json types_json jql token acc resp body count tmpdir
  query="$(printf '%s' "$opts" | jq -r '.query // ""')"
  open="$(printf '%s' "$opts" | jq -r '.open // false')"
  done_only="$(printf '%s' "$opts" | jq -r '.done // false')"
  estimated="$(printf '%s' "$opts" | jq -r '.estimated // false')"
  limit="$(printf '%s' "$opts" | jq -r '.limit // 50')"
  as_json="$(printf '%s' "$opts" | jq -r '.as_json // false')"
  types_json="$(printf '%s' "$opts" | jq -c '.types // []')"

  # --estimated → "(<devField> is not EMPTY OR <qaField> is not EMPTY OR <effortField> ...)",
  # built from whichever point/effort field ids are configured. Empty (a no-op) if none are.
  local est_clause="" f; local -a est_parts=()
  if [[ "$estimated" == "true" ]]; then
    for f in "$JIRA_DEV_POINTS_FIELD" "$JIRA_QA_POINTS_FIELD" "$JIRA_EFFORT_FIELD"; do
      [[ -n "$f" ]] && est_parts+=("$f is not EMPTY")
    done
    if [[ ${#est_parts[@]} -gt 0 ]]; then
      est_clause="${est_parts[0]}"
      local i; for ((i=1; i<${#est_parts[@]}; i++)); do est_clause="$est_clause OR ${est_parts[i]}"; done
      est_clause="($est_clause)"
    fi
  fi

  # Point/effort field ids to REQUEST (the /search/jql endpoint returns only what is asked
  # for) so callers like /estimate-ticket can read prior estimates. Base fields + configured.
  local fields_json='["summary","status","issuetype","priority","description"]'
  for f in "$JIRA_DEV_POINTS_FIELD" "$JIRA_QA_POINTS_FIELD" "$JIRA_EFFORT_FIELD"; do
    [[ -n "$f" ]] && fields_json="$(jq -c --arg f "$f" '. + [$f]' <<<"$fields_json")"
  done

  jql="$(jq -rn --arg proj "$JIRA_PROJECT_KEY" --arg q "$query" --argjson open "$open" \
      --argjson done "$done_only" --arg est "$est_clause" --argjson types "$types_json" '
    ( [ (if ($proj|length) > 0 then "project = " + $proj else empty end),
        (if ($q|length)    > 0 then "summary ~ " + ($q | @json) else empty end),
        (if $open              then "statusCategory != Done" else empty end),
        (if $done              then "statusCategory = Done"  else empty end),
        (if ($est|length)  > 0 then $est else empty end),
        (if ($types|length)> 0 then "issuetype in (" + ($types | map(@json) | join(", ")) + ")" else empty end)
      ] )
    | (if length > 0 then join(" AND ") + " " else "" end) + "ORDER BY created DESC"
  ')"

  tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' RETURN
  token=""; count=0
  while :; do
    body="$(jq -n --arg jql "$jql" --arg tok "$token" --argjson fields "$fields_json" \
      '{jql: $jql, maxResults: 100, fields: $fields}
       + (if $tok != "" then {nextPageToken: $tok} else {} end)')"
    resp="$(jira_api POST "/rest/api/3/search/jql" "$body")"
    # Append this page's issues array to the accumulator file (one JSON doc per line).
    # The growing result set never touches argv — it is combined via stdin slurp below.
    printf '%s' "$resp" | jq -c '.issues // []' >> "$tmpdir/pages.jsonl"
    count=$(( count + $(printf '%s' "$resp" | jq '(.issues // []) | length') ))
    # Honor a positive --limit DURING paging: once we have enough issues, stop fetching
    # (only --limit 0 / "all" keeps paging the whole board into memory).
    [[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 && "$count" -ge "$limit" ]] && break
    # Token-based pagination: stop when the page is flagged last, or no continuation
    # token is returned. There is no startAt/total to compare against.
    [[ "$(printf '%s' "$resp" | jq -r '.isLast // false')" == "true" ]] && break
    token="$(printf '%s' "$resp" | jq -r '.nextPageToken // empty')"
    [[ -n "$token" ]] || break
  done

  # Combine the per-page arrays via slurp over the file's contents (stdin), not argv.
  acc="$(jq -s 'add // []' "$tmpdir/pages.jsonl")"

  if [[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 ]]; then
    acc="$(printf '%s' "$acc" | jq --argjson n "$limit" '.[0:$n]')"
  fi

  if [[ "$as_json" == "true" ]]; then
    printf '%s\n' "$acc"; return 0
  fi

  if [[ "$(printf '%s' "$acc" | jq 'length')" -eq 0 ]]; then echo "(no matching tickets)"; return 0; fi

  printf '%s' "$acc" | jq -L "$JIRA_IMPL_DIR" -r \
    --arg dpf "$JIRA_DEV_POINTS_FIELD" --arg qpf "$JIRA_QA_POINTS_FIELD" --arg ef "$JIRA_EFFORT_FIELD" '
    include "jira";
    .[]
    | (.key) as $k
    | (.fields.status.name    // "—")          as $st
    | (.fields.issuetype.name // "—")          as $tt
    | (.fields.summary        // "(untitled)") as $title
    | ((.fields.description | adf_to_text) | gsub("\n+"; " ") | .[0:140]) as $desc
    | ( [ (if ($dpf|length>0) and (.fields[$dpf]!=null) then "Dev \(.fields[$dpf])" else empty end),
          (if ($qpf|length>0) and (.fields[$qpf]!=null) then "QA \(.fields[$qpf])"  else empty end),
          (if ($ef|length>0)  and (.fields[$ef]!=null)  then "Effort \(.fields[$ef])" else empty end) ]
        | if length>0 then "  [" + join(" · ") + "]" else "" end ) as $est
    | "\($k) | \($st) | \($tt) | \($title)\($est)"
      + (if (($desc | gsub("\\s"; "")) | length) > 0 then "  ::  " + $desc else "" end)
  '
}
