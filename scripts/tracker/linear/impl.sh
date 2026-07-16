#!/usr/bin/env bash
# Linear implementation of the tracker interface (sourced by ../lib.sh).
# Talks to the Linear GraphQL API (https://api.linear.app/graphql) with curl + jq.
#
# Config (env or ../.env):
#   LINEAR_API_KEY    personal API key (required) — linear.app → Settings → Security &
#                     access → API → Personal API keys (starts with "lin_api_"). Sent as-is
#                     in the Authorization header (Linear's personal-key scheme — no "Bearer").
#   LINEAR_TEAM_KEY   the team key that prefixes identifiers, e.g. FM (→ FM-123). Needed to
#                     expand a bare number to an identifier and to CREATE issues (ref "new").
#                     On a full identifier / URL the team key is parsed from it, so reads work
#                     without it.
#   LINEAR_API_URL    override the GraphQL endpoint (default https://api.linear.app/graphql)
#
# Linear specifics (why this differs from Notion/Jira):
#   • Descriptions AND comments are Markdown-native — no ADF/block renderer needed; the
#     Markdown is sent verbatim.
#   • "Status" is a workflow STATE — --status resolves a state NAME → its id within the team
#     (the phase→status mapping lives in docs/agents/issue-tracker.md). Unknown name → loud
#     failure listing the team's states.
#   • Priority is an Int 0–4 — Urgent=1, High=2, Medium=3, Low=4, None=0 (a bare 0–4 also
#     works). Unknown name → WARN + skipped.
#   • There is ONE numeric `estimate` field (no Dev/QA split). Per this workspace's choice
#     --effort / --dev-points / --qa-points are SUMMED and folded into `estimate`.
#   • Linear has no issue "type" field — --issuetype and --component both map to LABELS
#     (label ids resolved by name; a missing label WARNs and is skipped, never invented).
#   • --parent sets parentId (a Linear sub-issue is just a parented issue; --subtask is a
#     no-op note). --link <TYPE>:<KEY> creates an issue RELATION; Linear relation types are
#     related|blocks|duplicate, so any other type (e.g. Implements) maps to `related`.

LINEAR_IMPL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LINEAR_API_KEY="${LINEAR_API_KEY:-}"
LINEAR_TEAM_KEY="${LINEAR_TEAM_KEY:-}"
LINEAR_API_URL="${LINEAR_API_URL:-https://api.linear.app/graphql}"
# Optional default PROJECT for newly-created issues (ref "new"). LINEAR_PROJECT_ID (a UUID)
# wins; else LINEAR_PROJECT is a project NAME resolved to its id. Empty → no project set.
LINEAR_PROJECT_ID="${LINEAR_PROJECT_ID:-}"
LINEAR_PROJECT="${LINEAR_PROJECT:-}"

tracker_require_config() {
  [[ -n "$LINEAR_API_KEY" ]] || die "LINEAR_API_KEY is not set — create a personal API key at linear.app → Settings → Security & access → API, then put it in scripts/tracker/.env"
}

# linear_gql QUERY [VARIABLES_JSON] -> prints the `.data` object; exits on HTTP >= 400 or a
# GraphQL-level `errors` array (Linear returns those with HTTP 200).
linear_gql() {
  local query="$1" vars="${2:-{\}}" body tmp err http attempt=0
  body="$(jq -n --arg q "$query" --argjson v "$vars" '{query: $q, variables: $v}')"
  tmp="$(mktemp)"; err="$(mktemp)"
  local -a args=(
    -sS -X POST
    -H "Authorization: $LINEAR_API_KEY"
    -H "Content-Type: application/json"
    --data "$body"
    -o "$tmp" -w '%{http_code}'
  )
  while :; do
    if ! http="$(curl "${args[@]}" "$LINEAR_API_URL" 2>"$err")"; then
      rm -f "$tmp"; echo "error: request to Linear failed: $(cat "$err")" >&2; rm -f "$err"; exit 1
    fi
    case "${http:-000}" in
      429|500|502|503) if (( attempt < 5 )); then attempt=$((attempt + 1)); sleep "$attempt"; continue; fi ;;
    esac
    break
  done
  rm -f "$err"
  if [[ "${http:-000}" -ge 400 ]]; then
    echo "error: Linear API POST -> HTTP $http" >&2
    jq -r '(.errors // [])[]? | "  - \(.message)"' "$tmp" >&2 2>/dev/null || cat "$tmp" >&2
    rm -f "$tmp"; exit 1
  fi
  if jq -e '(.errors // []) | length > 0' "$tmp" >/dev/null 2>&1; then
    echo "error: Linear GraphQL error:" >&2
    jq -r '.errors[]? | "  - \(.message)"' "$tmp" >&2
    rm -f "$tmp"; exit 1
  fi
  jq -c '.data' "$tmp"; rm -f "$tmp"
}

# linear_identifier <ref> -> FM-123 (uppercased). Accepts a full identifier, an issue URL
# (…/issue/FM-123/slug), or a bare number (expanded with LINEAR_TEAM_KEY).
linear_identifier() {
  local raw="$1" seg num
  if [[ "$raw" == *"/issue/"* ]]; then
    seg="${raw##*/issue/}"; seg="${seg%%/*}"; seg="${seg%%\?*}"
    if [[ "$seg" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ ]]; then
      printf '%s' "$(printf '%s' "$seg" | tr '[:lower:]' '[:upper:]')"; return
    fi
  fi
  if [[ "$raw" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ ]]; then
    printf '%s' "$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')"; return
  fi
  num="${raw//[^0-9]/}"
  [[ -n "$num" ]] || die "could not parse a Linear identifier from '$raw' (try FM-123, 123, or an issue URL)"
  [[ -n "$LINEAR_TEAM_KEY" ]] || die "bare number '$raw' needs LINEAR_TEAM_KEY set (e.g. FM) to build the identifier"
  printf '%s-%s' "$(printf '%s' "$LINEAR_TEAM_KEY" | tr '[:lower:]' '[:upper:]')" "$num"
}

# Fetch a single issue node by identifier, selecting the given GraphQL field set.
# Prints the node JSON (compact), or empty if not found.
linear_issue_node() {
  local ident="$1" sel="$2" team num data
  team="${ident%-*}"; num="${ident##*-}"
  data="$(linear_gql \
    'query($team:String!,$number:Float!){issues(filter:{team:{key:{eq:$team}},number:{eq:$number}},first:1){nodes{'"$sel"'}}}' \
    "$(jq -n --arg t "$team" --argjson n "$num" '{team:$t, number:$n}')")"
  printf '%s' "$data" | jq -c '.issues.nodes[0] // empty'
}

# linear_issue_id <identifier> -> the issue UUID (die if not found).
linear_issue_id() {
  local node; node="$(linear_issue_node "$1" 'id')"
  [[ -n "$node" ]] || die "no Linear issue $1"
  printf '%s' "$node" | jq -r '.id'
}

# linear_team_bundle <team-key> -> {id, name, states:{nodes:[{id,name,type}]}} (die if none).
linear_team_bundle() {
  local key="$1" data node
  data="$(linear_gql \
    'query($key:String!){teams(filter:{key:{eq:$key}},first:1){nodes{id name states(first:250){nodes{id name type}}}}}' \
    "$(jq -n --arg k "$key" '{key:$k}')")"
  node="$(printf '%s' "$data" | jq -c '.teams.nodes[0] // empty')"
  [[ -n "$node" ]] || die "no Linear team with key '$key' — check LINEAR_TEAM_KEY / the identifier prefix"
  printf '%s' "$node"
}

# linear_resolve_state <states-json> <name> -> state id (die listing the team's states on miss).
linear_resolve_state() {
  local states="$1" want="$2" id
  id="$(printf '%s' "$states" | jq -r --arg w "$want" '
    [ .[] | select((.name // "" | ascii_downcase) == ($w | ascii_downcase)) | .id ][0] // empty')"
  [[ -n "$id" ]] || die "no workflow state named '$want' in the team — available: $(printf '%s' "$states" | jq -r '[.[].name] | join(", ")')"
  printf '%s' "$id"
}

# linear_priority_int <name> -> 0..4, or the literal "null" for an unknown name (caller warns).
linear_priority_int() {
  local p; p="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | xargs 2>/dev/null || true)"
  case "$p" in
    urgent)              echo 1 ;;
    high)                echo 2 ;;
    medium|med|normal)   echo 3 ;;
    low)                 echo 4 ;;
    none|"no priority")  echo 0 ;;
    0|1|2|3|4)           echo "$p" ;;
    *)                   echo "null" ;;
  esac
}

# linear_relation_type <requested> -> a valid Linear relation type (related|blocks|duplicate).
linear_relation_type() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    block|blocks|blocking|blocked) echo blocks ;;
    dup|duplicate|duplicates)      echo duplicate ;;
    *)                             echo related ;;
  esac
}

# linear_resolve_labels <names-json> -> {ids:[...], applied:[...], missing:[...]}.
# Matches requested names (case-insensitive) against the workspace's labels (first 250).
linear_resolve_labels() {
  local names="$1" data
  data="$(linear_gql 'query{issueLabels(first:250){nodes{id name}}}')"
  printf '%s' "$data" | jq -c --argjson req "$names" '
    (.issueLabels.nodes // []) as $have
    | ($have | map({k: (.name | ascii_downcase), id: .id, name: .name})) as $idx
    | reduce $req[] as $r ({ids:[], applied:[], missing:[]};
        ($idx | map(select(.k == ($r | ascii_downcase))) | .[0]) as $m
        | if $m == null
          then .missing += [$r]
          else .ids += [$m.id] | .applied += [$m.name] end)'
}

# Sum whichever of effort/dev_points/qa_points are present into ONE estimate (this
# workspace folds the split, since Linear has a single numeric estimate). Prints a JSON
# number, or the literal "null" when none was supplied.
linear_estimate() {
  printf '%s' "$1" | jq -c '
    [ (.effort // empty), (.dev_points // empty), (.qa_points // empty) ]
    | map(select(. != null and . != "") | tonumber)
    | if length > 0 then add else null end'
}

# linear_project_id -> the configured default project's UUID, or empty when none is set.
# LINEAR_PROJECT_ID (a raw UUID) wins; otherwise LINEAR_PROJECT is resolved by name
# (exact, case-insensitive). A name with no exact match is a loud failure listing candidates.
linear_project_id() {
  [[ -n "$LINEAR_PROJECT_ID" ]] && { printf '%s' "$LINEAR_PROJECT_ID"; return; }
  [[ -n "$LINEAR_PROJECT" ]] || return 0
  local data id
  data="$(linear_gql 'query($q:String!){projects(filter:{name:{containsIgnoreCase:$q}},first:50){nodes{id name}}}' \
    "$(jq -n --arg q "$LINEAR_PROJECT" '{q:$q}')")"
  id="$(printf '%s' "$data" | jq -r --arg n "$LINEAR_PROJECT" '
    [ .projects.nodes[] | select((.name | ascii_downcase) == ($n | ascii_downcase)) | .id ][0] // empty')"
  [[ -n "$id" ]] || die "no Linear project named '$LINEAR_PROJECT' — candidates: $(printf '%s' "$data" | jq -r '[.projects.nodes[].name] | join(", ")')"
  printf '%s' "$id"
}

# linear_resolve_project <name-or-id> -> project UUID for an EXPLICIT --project value.
# A raw UUID (8-4-4-4-12) is used verbatim; anything else is resolved by exact
# (case-insensitive) NAME. Empty arg -> empty. No name match -> loud failure with candidates.
linear_resolve_project() {
  local q="$1"; [[ -n "$q" ]] || return 0
  if [[ "$q" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    printf '%s' "$q"; return
  fi
  local data id
  data="$(linear_gql 'query($q:String!){projects(filter:{name:{containsIgnoreCase:$q}},first:50){nodes{id name}}}' \
    "$(jq -n --arg q "$q" '{q:$q}')")"
  id="$(printf '%s' "$data" | jq -r --arg n "$q" '
    [ .projects.nodes[] | select((.name | ascii_downcase) == ($n | ascii_downcase)) | .id ][0] // empty')"
  [[ -n "$id" ]] || die "no Linear project named '$q' — candidates: $(printf '%s' "$data" | jq -r '[.projects.nodes[].name] | join(", ")')"
  printf '%s' "$id"
}

# ── tracker interface ─────────────────────────────────────────────────────────

tracker_get_details() {
  local ident node desc
  ident="$(linear_identifier "$1")"
  node="$(linear_issue_node "$ident" \
    'identifier title url description priority priorityLabel estimate state{name type} project{name} assignee{name} labels{nodes{name}} parent{identifier title}')"
  [[ -n "$node" ]] || die "no Linear issue $ident"

  printf '%s' "$node" | jq -r '
    "\(.identifier) — \(.title // "Untitled")",
    (.url // empty),
    "",
    ( [ "Status:    \(.state.name // "—")",
        "Priority:  \(.priorityLabel // "—")",
        (if .project then "Project:   \(.project.name)" else empty end),
        (if .estimate != null then "Estimate:  \(.estimate)" else empty end),
        (if .assignee then "Assignee:  \(.assignee.name)" else empty end),
        (if (.labels.nodes | length) > 0 then "Labels:    \([.labels.nodes[].name] | join(", "))" else empty end),
        (if .parent then "Parent:    \(.parent.identifier) — \(.parent.title)" else empty end)
      ] | .[] )'

  desc="$(printf '%s' "$node" | jq -r '.description // ""')"
  if [[ -n "$desc" ]]; then
    printf '\n%s\n\n%s\n' "------------------------------------------------------------" "$desc"
  fi
}

# Linear has a single comment stream (threaded, but flattened here); --deep is a no-op.
tracker_comments_for_block() { : ; }

tracker_get_comments() {
  local ident node comments count
  ident="$(linear_identifier "$2")"
  node="$(linear_issue_node "$ident" 'comments(first:250){nodes{body createdAt user{name}}}')"
  [[ -n "$node" ]] || die "no Linear issue $ident"
  comments="$(printf '%s' "$node" | jq -c '.comments.nodes // []')"
  count="$(printf '%s' "$comments" | jq 'length')"

  printf 'Comments (%s)\n' "$count"
  if [[ "$count" -eq 0 ]]; then
    printf '\nNo comments on this ticket.\n'
    return 0
  fi
  printf '\n%s\n' "$(printf '%s' "$comments" | jq -r '
    sort_by(.createdAt)
    | map( "\(.user.name // "Unknown")  \(.createdAt // "")"
           + "\n" + ((.body // "") | split("\n") | map("  " + .) | join("\n")) )
    | join("\n\n")')"
}

tracker_upsert() {
  local ticket="$1" dry="$2" fields="$3" body_md="${4:-}"
  local status priority title description parent subtask issuetype project
  status="$(printf '%s' "$fields"      | jq -r '.status // empty')"
  priority="$(printf '%s' "$fields"    | jq -r '.priority // empty')"
  title="$(printf '%s' "$fields"       | jq -r '.title // empty')"
  description="$(printf '%s' "$fields" | jq -r '.description // empty')"
  parent="$(printf '%s' "$fields"      | jq -r '.parent // empty')"
  subtask="$(printf '%s' "$fields"     | jq -r '.subtask // empty')"
  issuetype="$(printf '%s' "$fields"   | jq -r '.issuetype // empty')"
  project="$(printf '%s' "$fields"     | jq -r '.project // empty')"

  # --issuetype + --component + --label all become LABELS (Linear has no issue-type field).
  local label_names estimate desc_field
  label_names="$(printf '%s' "$fields" | jq -c \
    --arg it "$issuetype" '(.components // []) + (.labels // []) + (if ($it | length) > 0 then [$it] else [] end)')"
  estimate="$(linear_estimate "$fields")"
  # The full spec (--body) is the description; a bare --description is the fallback text.
  desc_field="$body_md"; [[ -z "$desc_field" && -n "$description" ]] && desc_field="$description"

  [[ "$subtask" == "true" ]] && echo "NOTE: --subtask is a no-op on Linear — a sub-issue is just an issue with --parent set." >&2

  # Priority name → int (warn + skip an unknown name so it isn't silently coerced).
  local prio_int="null"
  if [[ -n "$priority" ]]; then
    prio_int="$(linear_priority_int "$priority")"
    [[ "$prio_int" == "null" ]] && echo "WARN: --priority '$priority' not recognised — skipped (use Urgent/High/Medium/Low/None or 0–4)" >&2
  fi

  local links_json; links_json="$(printf '%s' "$fields" | jq -c '.links // []')"

  # ── DRY RUN — stay offline; describe the intent by NAME (ids resolve on a real run). ──
  if [[ "$dry" -eq 1 ]]; then
    if [[ "$ticket" =~ ^[Nn][Ee][Ww]$ ]]; then
      printf 'DRY RUN — issueCreate in team %s\n' "${LINEAR_TEAM_KEY:-<LINEAR_TEAM_KEY unset>}"
    else
      printf 'DRY RUN — issueUpdate %s\n' "$(linear_identifier "$ticket")"
    fi
    [[ -n "$title" ]]        && printf '  title: %s\n' "$title"
    [[ -n "$status" ]]       && printf '  status (state): %s\n' "$status"
    [[ "$prio_int" != "null" ]] && printf '  priority: %s (%s)\n' "$priority" "$prio_int"
    [[ "$estimate" != "null" ]] && printf '  estimate: %s  (folded from effort/dev/qa)\n' "$estimate"
    [[ "$(printf '%s' "$label_names" | jq 'length')" -gt 0 ]] \
      && printf '  labels: %s\n' "$(printf '%s' "$label_names" | jq -r 'join(", ")')"
    [[ -n "$parent" ]]       && printf '  parent: %s\n' "$parent"
    if [[ "$ticket" =~ ^[Nn][Ee][Ww]$ ]]; then
      _proj_show="${project:-${LINEAR_PROJECT_ID:-$LINEAR_PROJECT}}"
      [[ -n "$_proj_show" ]] && printf '  project: %s\n' "$_proj_show"
    else
      [[ -n "$project" ]] && printf '  project: %s\n' "$project"
    fi
    [[ -n "$desc_field" ]]   && printf '  description: %s char(s) of Markdown\n' "${#desc_field}"
    printf '%s' "$links_json" | jq -r '.[]? | "  then issueRelationCreate — \(.type) → \(.key)"'
    return 0
  fi

  # ── REAL RUN ────────────────────────────────────────────────────────────────
  local team_key state_id="" label_ids="[]" parent_id="" issue_id="" ident

  # Resolve labels once (workspace-wide); a missing label warns and is skipped.
  if [[ "$(printf '%s' "$label_names" | jq 'length')" -gt 0 ]]; then
    local lres; lres="$(linear_resolve_labels "$label_names")"
    label_ids="$(printf '%s' "$lres" | jq -c '.ids')"
    local missing; missing="$(printf '%s' "$lres" | jq -r '.missing | join(", ")')"
    [[ -n "$missing" ]] && echo "WARN: label(s) not found, skipped: $missing (create them in Linear or check spelling)" >&2
  fi
  [[ -n "$parent" ]] && parent_id="$(linear_issue_id "$(linear_identifier "$parent")")"

  if [[ "$ticket" =~ ^[Nn][Ee][Ww]$ ]]; then
    # CREATE — needs a title and the team.
    [[ -n "$title" ]] || die "creating a Linear issue (ref 'new') needs --title"
    [[ -n "$LINEAR_TEAM_KEY" ]] || die "creating a Linear issue needs LINEAR_TEAM_KEY (e.g. FM)"
    team_key="$LINEAR_TEAM_KEY"
    local bundle team_id states project_id
    bundle="$(linear_team_bundle "$team_key")"
    team_id="$(printf '%s' "$bundle" | jq -r '.id')"
    states="$(printf '%s' "$bundle" | jq -c '.states.nodes')"
    [[ -n "$status" ]] && state_id="$(linear_resolve_state "$states" "$status")"
    # Explicit --project wins; otherwise the env default (LINEAR_PROJECT_ID/LINEAR_PROJECT).
    if [[ -n "$project" ]]; then project_id="$(linear_resolve_project "$project")"; else project_id="$(linear_project_id)"; fi

    local input resp created_ident created_id
    input="$(jq -n --arg teamId "$team_id" --arg title "$title" --arg desc "$desc_field" \
      --arg stateId "$state_id" --argjson prio "$prio_int" --argjson est "$estimate" \
      --argjson labelIds "$label_ids" --arg parentId "$parent_id" --arg projectId "$project_id" '
      { teamId: $teamId, title: $title }
      + (if ($desc | length) > 0    then {description: $desc}    else {} end)
      + (if ($stateId | length) > 0 then {stateId: $stateId}     else {} end)
      + (if $prio != null           then {priority: $prio}       else {} end)
      + (if $est != null            then {estimate: $est}        else {} end)
      + (if ($labelIds | length) > 0 then {labelIds: $labelIds}  else {} end)
      + (if ($parentId | length) > 0 then {parentId: $parentId}  else {} end)
      + (if ($projectId | length) > 0 then {projectId: $projectId} else {} end)')"
    resp="$(linear_gql 'mutation($input:IssueCreateInput!){issueCreate(input:$input){success issue{identifier title url project{name}}}}' \
      "$(jq -n --argjson i "$input" '{input:$i}')")"
    created_ident="$(printf '%s' "$resp" | jq -r '.issueCreate.issue.identifier // empty')"
    created_id="$(printf '%s' "$resp" | jq -r '.issueCreate.issue.id // empty')"
    [[ -n "$created_ident" ]] || die "Linear issueCreate did not return an identifier"
    printf 'Created %s — %s\n' "$created_ident" "$title"
    local created_project; created_project="$(printf '%s' "$resp" | jq -r '.issueCreate.issue.project.name // empty')"
    [[ -n "$created_project" ]] && printf 'Project: %s\n' "$created_project"
    [[ -n "$parent_id" ]] && printf 'Parent: %s\n' "$parent"
    linear_create_relations "$created_id" "$created_ident" "$links_json"
    return 0
  fi

  # UPDATE — resolve the issue + (if a status is given) the team's states.
  ident="$(linear_identifier "$ticket")"
  team_key="${ident%-*}"
  issue_id="$(linear_issue_id "$ident")"
  if [[ -n "$status" ]]; then
    local bundle states
    bundle="$(linear_team_bundle "$team_key")"
    states="$(printf '%s' "$bundle" | jq -c '.states.nodes')"
    state_id="$(linear_resolve_state "$states" "$status")"
  fi

  # --project on an existing issue: resolve the name/id → projectId (the create path
  # already handles project; this closes the update-path gap).
  local project_upd_id=""
  [[ -n "$project" ]] && project_upd_id="$(linear_resolve_project "$project")"

  local input
  input="$(jq -n --arg title "$title" --arg desc "$desc_field" --arg stateId "$state_id" \
    --argjson prio "$prio_int" --argjson est "$estimate" --argjson labelIds "$label_ids" \
    --arg parentId "$parent_id" --arg projectId "$project_upd_id" '
    {}
    + (if ($title | length) > 0    then {title: $title}       else {} end)
    + (if ($desc | length) > 0     then {description: $desc}  else {} end)
    + (if ($stateId | length) > 0  then {stateId: $stateId}   else {} end)
    + (if $prio != null            then {priority: $prio}     else {} end)
    + (if $est != null             then {estimate: $est}      else {} end)
    + (if ($labelIds | length) > 0 then {labelIds: $labelIds} else {} end)
    + (if ($parentId | length) > 0 then {parentId: $parentId} else {} end)
    + (if ($projectId | length) > 0 then {projectId: $projectId} else {} end)')"

  if [[ "$input" != "{}" ]]; then
    linear_gql 'mutation($id:String!,$input:IssueUpdateInput!){issueUpdate(id:$id,input:$input){success issue{identifier}}}' \
      "$(jq -n --arg id "$issue_id" --argjson i "$input" '{id:$id, input:$i}')" >/dev/null
    printf 'Updated %s\n' "$ident"
    printf 'Changed: %s\n' "$(printf '%s' "$input" | jq -r 'keys | join(", ")')"
  fi
  linear_create_relations "$issue_id" "$ident" "$links_json"
}

# Create each requested relation with the subject issue as the source: "<issue> <type> <other>".
# Linear relation types are related|blocks|duplicate; any other requested type maps to related.
linear_create_relations() {
  local issue_id="$1" ident="$2" links_json="$3" n i want other other_id rtype
  n="$(printf '%s' "$links_json" | jq 'length')"
  [[ "$n" -gt 0 ]] || return 0
  for (( i = 0; i < n; i++ )); do
    want="$(printf '%s' "$links_json" | jq -r --argjson i "$i" '.[$i].type')"
    other="$(printf '%s' "$links_json" | jq -r --argjson i "$i" '.[$i].key')"
    rtype="$(linear_relation_type "$want")"
    other_id="$(linear_issue_id "$(linear_identifier "$other")")"
    linear_gql 'mutation($input:IssueRelationCreateInput!){issueRelationCreate(input:$input){success}}' \
      "$(jq -n --arg iss "$issue_id" --arg rel "$other_id" --arg t "$rtype" \
         '{input:{issueId:$iss, relatedIssueId:$rel, type:$t}}')" >/dev/null
    if [[ "$rtype" == "$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')" ]]; then
      printf 'Linked %s —[%s]→ %s\n' "$ident" "$rtype" "$other"
    else
      printf 'Linked %s —[%s]→ %s  (requested "%s"; Linear supports related|blocks|duplicate)\n' "$ident" "$rtype" "$other" "$want"
    fi
  done
}

tracker_add_comment() {
  local ticket="$1" dry="$2" text="$3" ident issue_id resp cid
  ident="$(linear_identifier "$ticket")"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — commentCreate on %s\n%s\n' "$ident" \
      "$(jq -n --arg t "$text" '{input:{body:$t}}')"
    return 0
  fi
  issue_id="$(linear_issue_id "$ident")"
  # Comment body is Markdown-native — send it verbatim.
  resp="$(linear_gql 'mutation($input:CommentCreateInput!){commentCreate(input:$input){success comment{id url}}}' \
    "$(jq -n --arg id "$issue_id" --arg body "$text" '{input:{issueId:$id, body:$body}}')")"
  cid="$(printf '%s' "$resp" | jq -r '.commentCreate.comment.id // empty')"
  printf 'Added comment to %s (id %s)\n' "$ident" "${cid:-?}"
}

# tracker_find OPTS_JSON — OPTS = {query, open, done, estimated, limit, as_json, types:[...]}.
# Query issues (scoped to LINEAR_TEAM_KEY when set) and print one compact line per match,
# newest first: "<IDENT> | <State> | <Labels> | <Title>  ::  <Description>", or raw JSON.
# The dedup lookup behind /clarifying-ticket. Title match is case-insensitive substring.
tracker_find() {
  local opts="$1" query open done_only estimated limit as_json types_json filter
  query="$(printf '%s' "$opts" | jq -r '.query // ""')"
  open="$(printf '%s' "$opts" | jq -r '.open // false')"
  done_only="$(printf '%s' "$opts" | jq -r '.done // false')"
  estimated="$(printf '%s' "$opts" | jq -r '.estimated // false')"
  limit="$(printf '%s' "$opts" | jq -r '.limit // 50')"
  as_json="$(printf '%s' "$opts" | jq -r '.as_json // false')"
  types_json="$(printf '%s' "$opts" | jq -c '.types // []')"

  # Build an IssueFilter (AND of the supplied constraints). "Done" == a completed workflow
  # state (state.type == "completed"); --open excludes that. --type names map to labels.
  filter="$(jq -n \
    --arg team "$LINEAR_TEAM_KEY" --arg q "$query" --argjson open "$open" \
    --argjson done "$done_only" --argjson est "$estimated" --argjson types "$types_json" '
    {}
    + (if ($team | length) > 0 then {team: {key: {eq: $team}}} else {} end)
    + (if ($q | length) > 0    then {title: {containsIgnoreCase: $q}} else {} end)
    + (if $open then {state: {type: {neq: "completed"}}} else {} end)
    + (if $done then {state: {type: {eq: "completed"}}} else {} end)
    + (if $est  then {estimate: {null: false}} else {} end)
    + (if ($types | length) > 0 then {labels: {some: {name: {in: $types}}}} else {} end)')"

  local cursor="" acc="[]" data page has_next
  while :; do
    data="$(linear_gql \
      'query($filter:IssueFilter,$first:Int,$after:String){issues(filter:$filter,first:$first,after:$after){pageInfo{hasNextPage endCursor} nodes{identifier title description createdAt state{name} labels{nodes{name}}}}}' \
      "$(jq -n --argjson f "$filter" --arg after "$cursor" \
         '{filter:$f, first:100} + (if $after != "" then {after:$after} else {} end)')")"
    page="$(printf '%s' "$data" | jq -c '.issues.nodes // []')"
    acc="$(jq -n --argjson a "$acc" --argjson b "$page" '$a + $b')"
    has_next="$(printf '%s' "$data" | jq -r '.issues.pageInfo.hasNextPage // false')"
    # Stop early once a positive --limit is satisfied (0/"all" pages the whole board).
    [[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 && "$(printf '%s' "$acc" | jq 'length')" -ge "$limit" ]] && break
    [[ "$has_next" == "true" ]] || break
    cursor="$(printf '%s' "$data" | jq -r '.issues.pageInfo.endCursor // empty')"
    [[ -n "$cursor" ]] || break
  done

  # Newest-first (sort client-side; the connection has no direction arg), then trim.
  acc="$(printf '%s' "$acc" | jq 'sort_by(.createdAt) | reverse')"
  if [[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 ]]; then
    acc="$(printf '%s' "$acc" | jq --argjson n "$limit" '.[0:$n]')"
  fi

  if [[ "$as_json" == "true" ]]; then
    printf '%s\n' "$acc"; return 0
  fi
  if [[ "$(printf '%s' "$acc" | jq 'length')" -eq 0 ]]; then echo "(no matching tickets)"; return 0; fi

  printf '%s' "$acc" | jq -r '
    .[]
    | (.identifier)                              as $k
    | (.state.name // "—")                       as $st
    | ( if (.labels.nodes | length) > 0 then [.labels.nodes[].name] | join(", ") else "—" end) as $tt
    | (.title // "(untitled)")                   as $title
    | ((.description // "") | gsub("\n+"; " ") | .[0:140]) as $desc
    | "\($k) | \($st) | \($tt) | \($title)"
      + (if (($desc | gsub("\\s"; "")) | length) > 0 then "  ::  " + $desc else "" end)'
}
