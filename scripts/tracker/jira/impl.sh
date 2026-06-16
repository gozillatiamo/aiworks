#!/usr/bin/env bash
# Jira implementation of the tracker interface (sourced by ../lib.sh).
# Talks to the Jira Cloud REST API v3 with curl + jq; renders ADF via jira.jq.
#
# Config (env or ../.env):
#   JIRA_BASE_URL     e.g. https://acme.atlassian.net   (required)
#   JIRA_EMAIL        Atlassian account email           (required)
#   JIRA_API_TOKEN    API token                         (required)
#                     create at id.atlassian.com/manage-profile/security/api-tokens
#   JIRA_PROJECT_KEY  project key (e.g. OFB) — used to expand a bare number to KEY-n
#   JIRA_EFFORT_FIELD optional custom-field id for --effort (e.g. customfield_10016 / story points)
#   JIRA_DEV_POINTS_FIELD optional custom-field id for --dev-points (Developer points; number)
#   JIRA_QA_POINTS_FIELD  optional custom-field id for --qa-points  (QA points; number)
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
  # a browse URL like https://x.atlassian.net/browse/OFB-12 -> take the last path segment
  tail="${raw##*/}"
  if [[ "$tail" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ ]]; then
    printf '%s' "$(printf '%s' "$tail" | tr '[:lower:]' '[:upper:]')"; return
  fi
  num="${raw//[^0-9]/}"
  [[ -n "$num" ]] || die "could not parse a Jira key from '$raw' (try OFB-123 or 123)"
  [[ -n "$JIRA_PROJECT_KEY" ]] || die "bare number '$raw' needs JIRA_PROJECT_KEY set to build the key (e.g. OFB)"
  printf '%s-%s' "$JIRA_PROJECT_KEY" "$num"
}

# ── tracker interface ───────────────────────────────────────────────────────

tracker_get_details() {
  local key issue
  key="$(jira_key "$1")"
  issue="$(jira_api GET "/rest/api/3/issue/$key?fields=summary,status,priority,assignee,labels,issuetype,description,parent")"
  printf '%s' "$issue" | jq -L "$JIRA_IMPL_DIR" -r --arg base "$JIRA_BASE_URL" 'include "jira"; issue_details_text($base)'
}

# Jira has a single comment stream (no block-anchored comments), so --deep is ignored.
tracker_comments_for_block() { : ; }

tracker_get_comments() {
  local key resp
  key="$(jira_key "$2")"
  resp="$(jira_api GET "/rest/api/3/issue/$key/comment")"
  printf '%s' "$resp" | jira_jqm 'comments_text'
}

tracker_upsert() {
  local ticket="$1" dry="$2" fields="$3" body_md="${4:-}" key status jfields
  status="$(printf '%s' "$fields" | jq -r '.status // empty')"

  # ref "new" → create a fresh issue in JIRA_PROJECT_KEY (the key is server-assigned,
  # mirroring Notion's auto-id create). Requires --title.
  if [[ "$ticket" =~ ^[Nn][Ee][Ww]$ ]]; then
    jira_create "$dry" "$fields" "$body_md"
    return $?
  fi

  key="$(jira_key "$ticket")"

  # Map the abstract field set (minus status) to a Jira `fields` object. Jira has one
  # rich description field, so the full spec (--body, Markdown→ADF) populates it; a
  # bare --description (no --body) falls back to a plain-text ADF description.
  jfields="$(printf '%s' "$fields" | jq -L "$JIRA_IMPL_DIR" --arg ef "$JIRA_EFFORT_FIELD" \
    --arg dpf "$JIRA_DEV_POINTS_FIELD" --arg qpf "$JIRA_QA_POINTS_FIELD" --arg body "$body_md" '
    include "jira";
    {}
    + (if .title    then {summary: .title} else {} end)
    + (if .priority then {priority: {name: .priority}} else {} end)
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
jira_create() {
  local dry="$1" fields="$2" body_md="${3:-}" title status jfields body resp key
  title="$(printf '%s' "$fields" | jq -r '.title // empty')"
  status="$(printf '%s' "$fields" | jq -r '.status // empty')"
  [[ -n "$title" ]]            || die "creating a Jira issue (ref 'new') needs --title"
  [[ -n "$JIRA_PROJECT_KEY" ]] || die "creating a Jira issue needs JIRA_PROJECT_KEY (e.g. OFB)"

  jfields="$(printf '%s' "$fields" | jq -L "$JIRA_IMPL_DIR" \
    --arg proj "$JIRA_PROJECT_KEY" --arg itype "$JIRA_DEFAULT_ISSUETYPE" --arg ef "$JIRA_EFFORT_FIELD" \
    --arg dpf "$JIRA_DEV_POINTS_FIELD" --arg qpf "$JIRA_QA_POINTS_FIELD" --arg body "$body_md" '
    include "jira";
    { project: {key: $proj}, issuetype: {name: $itype}, summary: .title }
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
    [[ -n "$status" ]] && printf 'DRY RUN — then transition the new issue → %s\n' "$status"
    return 0
  fi
  resp="$(jira_api POST "/rest/api/3/issue" "$body")"
  key="$(printf '%s' "$resp" | jq -r '.key // empty')"
  [[ -n "$key" ]] || die "issue create did not return a key"
  printf 'Created %s — %s\n' "$key" "$title"
  [[ -n "$status" ]] && jira_transition "$key" "$status"
  return 0
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
# match (not a raw substring); pick a distinctive whole token. Uses the classic
# POST /rest/api/3/search; newer Cloud sites may need /rest/api/3/search/jql instead.
tracker_find() {
  local opts="$1" query open limit as_json types_json jql startAt acc resp total got
  query="$(printf '%s' "$opts" | jq -r '.query // ""')"
  open="$(printf '%s' "$opts" | jq -r '.open // false')"
  limit="$(printf '%s' "$opts" | jq -r '.limit // 50')"
  as_json="$(printf '%s' "$opts" | jq -r '.as_json // false')"
  types_json="$(printf '%s' "$opts" | jq -c '.types // []')"

  jql="$(jq -rn --arg proj "$JIRA_PROJECT_KEY" --arg q "$query" --argjson open "$open" --argjson types "$types_json" '
    ( [ (if ($proj|length) > 0 then "project = " + $proj else empty end),
        (if ($q|length)    > 0 then "summary ~ " + ($q | @json) else empty end),
        (if $open              then "statusCategory != Done" else empty end),
        (if ($types|length)> 0 then "issuetype in (" + ($types | map(@json) | join(", ")) + ")" else empty end)
      ] )
    | (if length > 0 then join(" AND ") + " " else "" end) + "ORDER BY created DESC"
  ')"

  startAt=0; acc="[]"
  while :; do
    body="$(jq -n --arg jql "$jql" --argjson sa "$startAt" \
      '{jql: $jql, startAt: $sa, maxResults: 100, fields: ["summary","status","issuetype","priority","description"]}')"
    resp="$(jira_api POST "/rest/api/3/search" "$body")"
    acc="$(jq -n --argjson a "$acc" --argjson b "$(printf '%s' "$resp" | jq '.issues // []')" '$a + $b')"
    total="$(printf '%s' "$resp" | jq -r '.total // 0')"
    got="$(printf '%s' "$acc" | jq 'length')"
    [[ "$got" -lt "$total" && "$got" -gt 0 ]] || break
    startAt="$got"
  done

  if [[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 ]]; then
    acc="$(printf '%s' "$acc" | jq --argjson n "$limit" '.[0:$n]')"
  fi

  if [[ "$as_json" == "true" ]]; then
    printf '%s\n' "$acc"; return 0
  fi

  if [[ "$(printf '%s' "$acc" | jq 'length')" -eq 0 ]]; then echo "(no matching tickets)"; return 0; fi

  printf '%s' "$acc" | jq -L "$JIRA_IMPL_DIR" -r '
    include "jira";
    .[]
    | (.key) as $k
    | (.fields.status.name    // "—")          as $st
    | (.fields.issuetype.name // "—")          as $tt
    | (.fields.summary        // "(untitled)") as $title
    | ((.fields.description | adf_to_text) | gsub("\n+"; " ") | .[0:140]) as $desc
    | "\($k) | \($st) | \($tt) | \($title)"
      + (if (($desc | gsub("\\s"; "")) | length) > 0 then "  ::  " + $desc else "" end)
  '
}
