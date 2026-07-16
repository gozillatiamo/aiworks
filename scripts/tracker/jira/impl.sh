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
#                     find the ids with jira/discover-fields.sh; when one is unset the
#                     matching flag is WARNed + listed under "Skipped:" (not dropped silently).
#   JIRA_SUBTASK_ISSUETYPE optional sub-task issue type NAME for --subtask (e.g. "Sub-task").
#                     When unset, --subtask resolves the project's sub-task type from the API.
#
# Child issues (ref "new"): --parent <KEY> sets fields.parent; --subtask uses the project's
# sub-task type (or --issuetype <name> for any type); --component <name> (repeatable) sets
# fields.components after validating each against the project; --link <TYPE>:<KEY> (repeatable)
# creates an issue link AFTER create, with the new issue as the outward (subject) side.
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
  fields_q="summary,status,priority,assignee,labels,issuetype,description,parent"
  for f in "$JIRA_DEV_POINTS_FIELD" "$JIRA_QA_POINTS_FIELD" "$JIRA_EFFORT_FIELD"; do
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
    "qa_points|$JIRA_QA_POINTS_FIELD|--qa-points|JIRA_QA_POINTS_FIELD"; do
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

  # --project is not a per-issue field on Jira (a project MOVE is a distinct operation);
  # be honest rather than silently drop it. Create uses JIRA_PROJECT_KEY.
  [[ "$(printf '%s' "$fields" | jq -r '((.project // "") | tostring | length) > 0')" == "true" ]] \
    && echo "WARN: --project ignored on Jira — the project is JIRA_PROJECT_KEY at create; moving an existing issue's project is a separate Jira operation." >&2

  # ref "new" → create a fresh issue in JIRA_PROJECT_KEY (the key is server-assigned,
  # mirroring Notion's auto-id create). Requires --title.
  if [[ "$ticket" =~ ^[Nn][Ee][Ww]$ ]]; then
    jira_create "$dry" "$fields" "$body_md"
    return $?
  fi

  key="$(jira_key "$ticket")"

  # The child-issue flags (parent/issuetype/subtask/component/link) only apply when
  # CREATING (ref "new"). On an update, say so loudly rather than dropping them silently.
  local _createonly
  _createonly="$(printf '%s' "$fields" | jq -r '
    [ (if .parent    then "--parent"    else empty end),
      (if .issuetype then "--issuetype" else empty end),
      (if .subtask   then "--subtask"   else empty end),
      (if (.components // [] | length) > 0 then "--component" else empty end),
      (if (.links      // [] | length) > 0 then "--link"      else empty end)
    ] | join(", ")')"
  [[ -n "$_createonly" ]] && echo "WARN: $_createonly ignored — only applied when creating (ref \"new\"), not on updates" >&2

  # Map the abstract field set (minus status) to a Jira `fields` object. Jira has one
  # rich description field, so the full spec (--body, Markdown→ADF) populates it; a
  # bare --description (no --body) falls back to a plain-text ADF description.
  jfields="$(printf '%s' "$fields" | jq -L "$JIRA_IMPL_DIR" --arg ef "$JIRA_EFFORT_FIELD" \
    --arg dpf "$JIRA_DEV_POINTS_FIELD" --arg qpf "$JIRA_QA_POINTS_FIELD" --arg body "$body_md" '
    include "jira";
    {}
    + (if .title    then {summary: .title} else {} end)
    + (if .priority then {priority: {name: .priority}} else {} end)
    + (if (.labels // [] | length) > 0 then {labels: .labels} else {} end)
    + ( if ($body | length) > 0 then {description: ($body | md_to_adf)}
        elif .description       then {description: (.description | text_to_adf)}
        else {} end )
    + (if (.effort     and ($ef  | length > 0)) then {($ef):  .effort}                else {} end)
    + (if (.dev_points and ($dpf | length > 0)) then {($dpf): (.dev_points | tonumber)} else {} end)
    + (if (.qa_points  and ($qpf | length > 0)) then {($qpf): (.qa_points  | tonumber)} else {} end)
    ')"

  if [[ "$dry" -eq 1 ]]; then
    [[ "$jfields" != "{}" ]] && printf 'DRY RUN — PUT /rest/api/3/issue/%s\n%s\n' "$key" "$(jq -n --argjson f "$jfields" '{fields: $f}')"
    [[ -n "$status" ]] && printf 'DRY RUN — POST /rest/api/3/issue/%s/transitions  (target status: %s)\n' "$key" "$status"
    [[ "$jfields" == "{}" && -z "$status" ]] && printf 'DRY RUN — nothing to change for %s\n' "$key"
    return 0
  fi

  if [[ "$jfields" != "{}" ]]; then
    jira_api PUT "/rest/api/3/issue/$key" "$(jq -n --argjson f "$jfields" '{fields: $f}')" >/dev/null
    printf 'Updated %s\n' "$key"
    printf 'Changed: %s\n' "$(printf '%s' "$jfields" | jq -r 'keys | join(", ")')"
  fi
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
    --arg dpf "$JIRA_DEV_POINTS_FIELD" --arg qpf "$JIRA_QA_POINTS_FIELD" --arg body "$body_md" \
    --arg parent "$parent" --argjson comps "$comp_fields" '
    include "jira";
    { project: {key: $proj}, issuetype: {name: $itype}, summary: .title }
    + (if ($parent | length) > 0 then {parent: {key: $parent}} else {} end)
    + (if ($comps  | length) > 0 then {components: $comps}     else {} end)
    + (if (.labels // [] | length) > 0 then {labels: .labels}  else {} end)
    + (if .priority then {priority: {name: .priority}} else {} end)
    + ( if ($body | length) > 0 then {description: ($body | md_to_adf)}
        elif .description       then {description: (.description | text_to_adf)}
        else {} end )
    + (if (.effort     and ($ef  | length > 0)) then {($ef):  .effort}                else {} end)
    + (if (.dev_points and ($dpf | length > 0)) then {($dpf): (.dev_points | tonumber)} else {} end)
    + (if (.qa_points  and ($qpf | length > 0)) then {($qpf): (.qa_points  | tonumber)} else {} end)
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

# Create each requested issue link with the NEW issue as the outward (subject) side:
# "<new> <type> <other>" (e.g. a new sub-task Implements its parent). The link type name is
# resolved against the project; on no exact match the closest type is used (and reported).
jira_create_links() {
  local child="$1" links_json="$2" n i ltype other resolved types
  n="$(printf '%s' "$links_json" | jq 'length')"
  [[ "$n" -gt 0 ]] || return 0
  types="$(jira_api GET "/rest/api/3/issueLinkType")"
  for (( i = 0; i < n; i++ )); do
    ltype="$(printf '%s' "$links_json" | jq -r --argjson i "$i" '.[$i].type')"
    other="$(printf '%s' "$links_json" | jq -r --argjson i "$i" '.[$i].key')"
    resolved="$(jira_resolve_link_type "$types" "$ltype")"
    jira_api POST "/rest/api/3/issueLink" "$(jq -n --arg t "$resolved" --arg c "$child" --arg o "$other" \
      '{type: {name: $t}, outwardIssue: {key: $c}, inwardIssue: {key: $o}}')" >/dev/null
    if [[ "$resolved" == "$ltype" ]]; then
      printf 'Linked %s —[%s]→ %s\n' "$child" "$resolved" "$other"
    else
      printf 'Linked %s —[%s]→ %s  (requested "%s"; used closest match "%s")\n' "$child" "$resolved" "$other" "$ltype" "$resolved"
    fi
  done
}

# Map a requested link-type name to a real one: exact (case-insensitive) match first, then
# the closest by substring (e.g. "Implements" → "Implement"), preferring the longest name.
# No reasonable match → loud failure listing the available types.
jira_resolve_link_type() {
  local types="$1" want="$2" name
  name="$(printf '%s' "$types" | jq -r --arg w "$want" '
    [.issueLinkTypes[]? | select((.name | ascii_downcase) == ($w | ascii_downcase)) | .name][0] // empty')"
  if [[ -z "$name" ]]; then
    name="$(printf '%s' "$types" | jq -r --arg w "$want" '
      ($w | ascii_downcase) as $lw
      | [ .issueLinkTypes[]?
          | (.name | ascii_downcase) as $ln
          | select(($ln | startswith($lw)) or ($lw | startswith($ln)) or ($ln | inside($lw)) or ($lw | inside($ln)))
          | .name ]
      | sort_by(length) | reverse | (.[0] // empty)')"
  fi
  [[ -n "$name" ]] || die "issue link type '$want' not found in Jira — available: $(printf '%s' "$types" | jq -r '[.issueLinkTypes[]?.name] | join(", ")' 2>/dev/null)"
  printf '%s' "$name"
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
