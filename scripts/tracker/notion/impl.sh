#!/usr/bin/env bash
# Notion implementation of the tracker interface (sourced by ../lib.sh).
# Talks to the Notion REST API with curl + jq; renders via notion.jq.
#
# Config (env or ../.env):
#   NOTION_TOKEN     internal integration token (required)
#   NOTION_DB_ID     the tasks database id (required to create/resolve by number)
#   NOTION_ID_PROP   unique-id property holding the ticket number (default "Task ID")
#   NOTION_VERSION   API version (default 2022-06-28)
#   NOTION_PROP_*    property NAMES this workspace uses (defaults match the reference schema)

NOTION_IMPL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NOTION_TOKEN="${NOTION_TOKEN:-}"
NOTION_DB_ID="${NOTION_DB_ID:-}"
NOTION_ID_PROP="${NOTION_ID_PROP:-Task ID}"
NOTION_VERSION="${NOTION_VERSION:-2022-06-28}"
NOTION_API="https://api.notion.com/v1"

# Property names — override per workspace; defaults are the reference schema.
NOTION_PROP_STATUS="${NOTION_PROP_STATUS:-Status}"
NOTION_PROP_PRIORITY="${NOTION_PROP_PRIORITY:-Priority}"
NOTION_PROP_EFFORT="${NOTION_PROP_EFFORT:-Effort level}"
NOTION_PROP_DEV_POINTS="${NOTION_PROP_DEV_POINTS:-Developer Points}"   # number; estimation Dev split
NOTION_PROP_QA_POINTS="${NOTION_PROP_QA_POINTS:-QA Points}"            # number; estimation QA split
NOTION_PROP_TITLE="${NOTION_PROP_TITLE:-Task name}"
NOTION_PROP_DESCRIPTION="${NOTION_PROP_DESCRIPTION:-Description}"
NOTION_PROP_TYPE="${NOTION_PROP_TYPE:-Task type}"   # multi_select used by find-tickets --type / --issuetype
NOTION_STATUS_DONE="${NOTION_STATUS_DONE:-Done}"    # the "done" status name, for find-tickets --open
# Child-issue mapping for the provider-agnostic --parent/--component/--link flags. Parent
# and links are RELATION properties (they point at other pages); component is a multi_select.
# Override per workspace; leave a name EMPTY to disable that flag for Notion (it then warns
# instead of dropping silently). Links default OFF — Notion has no typed issue links, so the
# parent relation already models the QA "Implements parent" case.
NOTION_PROP_PARENT="${NOTION_PROP_PARENT:-Parent item}"      # relation → the parent (sub-item)
NOTION_PROP_COMPONENT="${NOTION_PROP_COMPONENT:-Component}"  # multi_select → --component
NOTION_PROP_LINKS="${NOTION_PROP_LINKS:-}"                   # relation → --link targets (off by default)

tracker_require_config() {
  [[ -n "$NOTION_TOKEN" ]] || die "NOTION_TOKEN is not set — copy .env.example to .env and fill it in"
  [[ -n "$NOTION_DB_ID" ]] || die "NOTION_DB_ID is not set — the tasks database id (see .env.example)"
}

notion_jqm() { jq -L "$NOTION_IMPL_DIR" -r 'include "notion"; '"$1"; }

# notion_api METHOD PATH [JSON_BODY] -> prints JSON response; exits on HTTP >= 400.
notion_api() {
  local method="$1" path="$2" body="${3:-}"
  local tmp err http
  tmp="$(mktemp)"; err="$(mktemp)"
  local -a args=(
    -sS -X "$method"
    -H "Authorization: Bearer $NOTION_TOKEN"
    -H "Notion-Version: $NOTION_VERSION"
    -H "Content-Type: application/json"
    -o "$tmp" -w '%{http_code}'
  )
  [[ -n "$body" ]] && args+=(--data "$body")
  local attempt=0
  while :; do
    if ! http="$(curl "${args[@]}" "$NOTION_API$path" 2>"$err")"; then
      rm -f "$tmp"; echo "error: request to $path failed: $(cat "$err")" >&2; rm -f "$err"; exit 1
    fi
    case "${http:-000}" in
      429|502|503) if (( attempt < 5 )); then attempt=$((attempt + 1)); sleep "$attempt"; continue; fi ;;
    esac
    break
  done
  rm -f "$err"
  if [[ "${http:-000}" -ge 400 ]]; then
    echo "error: Notion API $method $path -> HTTP $http" >&2
    jq -r '.message // .object // "(no message)"' "$tmp" >&2 2>/dev/null || cat "$tmp" >&2
    rm -f "$tmp"; exit 1
  fi
  cat "$tmp"; rm -f "$tmp"
}

# notion_resolve_page_id <ticket | page-id | url> [soft] -> prints page UUID.
notion_resolve_page_id() {
  local raw="$1" soft="${2:-}" hex num query resp page_id
  hex="$(printf '%s' "${raw//-/}" | grep -oiE '[0-9a-f]{32}' | tail -n1 || true)"
  if [[ -n "$hex" ]]; then
    printf '%s-%s-%s-%s-%s' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
    return
  fi
  num="${raw//[^0-9]/}"
  [[ -n "$num" ]] || die "could not parse a ticket number from '$raw' (try FM-9, 9, a page id, or a Notion URL)"
  query="$(jq -n --arg prop "$NOTION_ID_PROP" --argjson num "$num" \
    '{filter: {property: $prop, unique_id: {equals: $num}}, page_size: 1}')"
  resp="$(notion_api POST "/databases/$NOTION_DB_ID/query" "$query")"
  page_id="$(printf '%s' "$resp" | jq -r '.results[0].id // empty')"
  [[ -n "$page_id" || -n "$soft" ]] || die "no ticket with $NOTION_ID_PROP = $num in database $NOTION_DB_ID"
  printf '%s' "$page_id"
}

# notion_collect_pages METHOD PATH [JSON_BODY] -> single JSON array of all .results.
notion_collect_pages() {
  local method="$1" path="$2" body="${3:-}"
  local sep cursor="" resp acc="[]"
  [[ "$path" == *\?* ]] && sep="&" || sep="?"
  while :; do
    local url="${path}${sep}page_size=100"
    [[ -n "$cursor" ]] && url="${url}&start_cursor=${cursor}"
    resp="$(notion_api "$method" "$url" "$body")"
    acc="$(jq -n --argjson a "$acc" --argjson b "$(printf '%s' "$resp" | jq '.results')" '$a + $b')"
    [[ "$(printf '%s' "$resp" | jq -r '.has_more')" == "true" ]] || break
    cursor="$(printf '%s' "$resp" | jq -r '.next_cursor // empty')"
    [[ -n "$cursor" ]] || break
  done
  printf '%s' "$acc"
}

# notion_append_blocks <page-id> <blocks-json> — append blocks to a page in batches
# of 100 (Notion's per-request cap). No-op when the array is empty.
notion_append_blocks() {
  local pid="$1" children="$2" n i batch
  n="$(printf '%s' "$children" | jq 'length')"
  for (( i = 0; i < n; i += 100 )); do
    batch="$(printf '%s' "$children" | jq --argjson i "$i" '.[$i:$i+100]')"
    notion_api PATCH "/blocks/$pid/children" "$(jq -n --argjson c "$batch" '{children: $c}')" >/dev/null
  done
}

# notion_user_name <user-id> -> display name, or the id (best-effort; never fails).
notion_user_name() {
  local uid="$1" name
  name="$(curl -sS \
    -H "Authorization: Bearer $NOTION_TOKEN" \
    -H "Notion-Version: $NOTION_VERSION" \
    "$NOTION_API/users/$uid" 2>/dev/null | jq -r '.name // empty' 2>/dev/null || true)"
  printf '%s' "${name:-$uid}"
}

# notion_collect_descendant_block_ids <block-id> -> every descendant block id (one/line).
notion_collect_descendant_block_ids() {
  local root="$1" children id
  children="$(notion_collect_pages GET "/blocks/$root/children")"
  printf '%s' "$children" | jq -r '.[].id'
  for id in $(printf '%s' "$children" \
    | jq -r '.[] | select(.has_children == true and .type != "child_page" and .type != "child_database") | .id'); do
    notion_collect_descendant_block_ids "$id"
  done
}

# ── tracker interface ───────────────────────────────────────────────────────

tracker_get_details() {
  local page_id page_json blocks_json title_text props_text ticket_label url body_text
  page_id="$(notion_resolve_page_id "$1")"
  page_json="$(notion_api GET "/pages/$page_id")"
  blocks_json="$(notion_collect_pages GET "/blocks/$page_id/children")"

  title_text="$(printf '%s' "$page_json" | notion_jqm 'page_title_text')"
  props_text="$(printf '%s' "$page_json" | notion_jqm 'props_text')"
  ticket_label="$(printf '%s' "$page_json" | notion_jqm '[.properties[] | select(.type=="unique_id")][0] | if . then prop_to_text else "" end')"
  url="$(printf '%s' "$page_json" | jq -r '.url // ""')"
  body_text="$(printf '%s' "$blocks_json" | notion_jqm 'render_blocks_text')"

  if [[ -n "$ticket_label" ]]; then
    printf '%s — %s\n' "$ticket_label" "${title_text:-Untitled}"
  else
    printf '%s\n' "${title_text:-Untitled}"
  fi
  [[ -n "$url" ]] && printf '%s\n' "$url"
  [[ -n "$props_text" ]] && printf '\n%s\n' "$props_text"
  if [[ -n "$body_text" ]]; then
    printf '\n%s\n\n%s\n' "------------------------------------------------------------" "$body_text"
  fi
}

# Internal --deep worker: write one block's open comments as JSON into $NOTION_OUTDIR.
tracker_comments_for_block() {
  notion_collect_pages GET "/comments?block_id=$1" > "$NOTION_OUTDIR/$1.json" 2>/dev/null
}

tracker_get_comments() {
  local deep="$1" ticket="$2" page_id page_comments comments_json names_json count comments_text
  page_id="$(notion_resolve_page_id "$ticket")"
  page_comments="$(notion_collect_pages GET "/comments?block_id=$page_id")"

  if [[ "$deep" -eq 1 ]]; then
    local tmpdir; tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' RETURN
    export NOTION_OUTDIR="$tmpdir"
    notion_collect_descendant_block_ids "$page_id" | sort -u | grep . \
      | xargs -P "${NOTION_CONCURRENCY:-8}" -n 1 "$0" --comments-for-block || true
    comments_json="$(
      { printf '%s\n' "$page_comments"; cat "$tmpdir"/*.json 2>/dev/null; } \
      | jq -s 'add // [] | unique_by(.id)'
    )"
  else
    comments_json="$(printf '%s' "$page_comments" | jq 'unique_by(.id)')"
  fi

  names_json="{}"
  local uid
  for uid in $(printf '%s' "$comments_json" | jq -r '[.[].created_by.id] | unique[]'); do
    names_json="$(jq -n --argjson m "$names_json" --arg k "$uid" --arg v "$(notion_user_name "$uid")" '$m + {($k): $v}')"
  done

  count="$(printf '%s' "$comments_json" | jq 'length')"
  comments_text="$(printf '%s' "$comments_json" | jq -L "$NOTION_IMPL_DIR" -r --argjson names "$names_json" '
    include "notion";
    sort_by(.created_time)
    | map(
        (.created_by.id) as $id
        | ($names[$id] // $id) as $who
        | "\($who)  \(.created_time)\n"
          + ( (.rich_text | rich_to_text) | split("\n") | map("  " + .) | join("\n") )
      )
    | join("\n\n")')"

  printf 'Comments (%s)\n' "$count"
  if [[ "$count" -eq 0 ]]; then
    printf '\nNo open page-level comments on this ticket.\n'
  else
    printf '\n%s\n' "$comments_text"
  fi
}

tracker_upsert() {
  local ticket="$1" dry="$2" fields="$3" body_md="${4:-}" props body page_id title label children nblocks new_id resp
  # Map the abstract field set to Notion's properties object. --description sets the
  # one-line Description PROPERTY; the full spec (body_md) goes in the page BODY below.
  props="$(printf '%s' "$fields" | jq \
    --arg pStatus "$NOTION_PROP_STATUS" --arg pPriority "$NOTION_PROP_PRIORITY" \
    --arg pEffort "$NOTION_PROP_EFFORT" --arg pDevPts "$NOTION_PROP_DEV_POINTS" \
    --arg pQaPts "$NOTION_PROP_QA_POINTS" --arg pTitle "$NOTION_PROP_TITLE" \
    --arg pDesc "$NOTION_PROP_DESCRIPTION" '
    {}
    + (if .status      then {($pStatus):   {status:    {name: .status}}} else {} end)
    + (if .priority    then {($pPriority): {select:    {name: .priority}}} else {} end)
    + (if .effort      then {($pEffort):   {select:    {name: .effort}}} else {} end)
    + (if .dev_points  then {($pDevPts):   {number:    (.dev_points | tonumber)}} else {} end)
    + (if .qa_points   then {($pQaPts):    {number:    (.qa_points  | tonumber)}} else {} end)
    + (if .title       then {($pTitle):    {title:     [{text: {content: .title}}]}} else {} end)
    + (if .description then {($pDesc):     {rich_text: [{text: {content: .description}}]}} else {} end)
    ')"

  # Child-issue flags (provider-agnostic --parent/--issuetype/--component/--link). Component
  # → multi_select; issuetype → the Type property; parent + links → relations (resolved to
  # page ids on a real run; in --dry-run they're noted, not resolved, to stay offline). For
  # Notion --subtask is a no-op — the parent relation already models the sub-item.
  local comps_json links_json issuetype want_parent
  # --component and --label both map to the Component multi_select on Notion (tags).
  comps_json="$(printf '%s' "$fields" | jq -c '(.components // []) + (.labels // [])')"
  links_json="$(printf '%s' "$fields" | jq -c '.links // []')"
  issuetype="$(printf '%s' "$fields" | jq -r '.issuetype // empty')"
  want_parent="$(printf '%s' "$fields" | jq -r '.parent // empty')"

  # --project is not a per-ticket field on Notion (the tasks database is the project) —
  # be honest rather than silently drop it.
  [[ "$(printf '%s' "$fields" | jq -r '((.project // "") | tostring | length) > 0')" == "true" ]] \
    && echo "WARN: --project ignored on Notion — the tasks database is the project; there is no per-ticket project field." >&2

  if [[ "$(printf '%s' "$comps_json" | jq 'length')" -gt 0 ]]; then
    if [[ -n "$NOTION_PROP_COMPONENT" ]]; then
      props="$(jq -n --argjson p "$props" --arg prop "$NOTION_PROP_COMPONENT" --argjson c "$comps_json" \
        '$p + {($prop): {multi_select: ($c | map({name: .}))}}')"
    else
      echo "WARN: --component ignored — NOTION_PROP_COMPONENT not set in scripts/tracker/.env" >&2
    fi
  fi
  if [[ -n "$issuetype" ]]; then
    props="$(jq -n --argjson p "$props" --arg prop "$NOTION_PROP_TYPE" --arg t "$issuetype" \
      '$p + {($prop): {multi_select: [{name: $t}]}}')"
  fi
  # parent + links → relations (page ids). Resolve only on a real run; note them when --dry-run.
  if [[ "$dry" -eq 1 ]]; then
    [[ -n "$want_parent" && -n "$NOTION_PROP_PARENT" ]] \
      && printf 'DRY RUN — would set relation %s → %s\n' "$NOTION_PROP_PARENT" "$want_parent"
    [[ "$(printf '%s' "$links_json" | jq 'length')" -gt 0 && -n "$NOTION_PROP_LINKS" ]] \
      && printf 'DRY RUN — would set relation %s → %s\n' "$NOTION_PROP_LINKS" "$(printf '%s' "$links_json" | jq -r '[.[].key] | join(", ")')"
  else
    if [[ -n "$want_parent" ]]; then
      if [[ -n "$NOTION_PROP_PARENT" ]]; then
        props="$(jq -n --argjson p "$props" --arg prop "$NOTION_PROP_PARENT" --arg id "$(notion_resolve_page_id "$want_parent")" \
          '$p + {($prop): {relation: [{id: $id}]}}')"
      else
        echo "WARN: --parent ignored — NOTION_PROP_PARENT not set in scripts/tracker/.env" >&2
      fi
    fi
    if [[ "$(printf '%s' "$links_json" | jq 'length')" -gt 0 ]]; then
      if [[ -n "$NOTION_PROP_LINKS" ]]; then
        local lk link_pids='[]'
        for lk in $(printf '%s' "$links_json" | jq -r '.[].key'); do
          link_pids="$(jq -n --argjson cur "$link_pids" --arg id "$(notion_resolve_page_id "$lk")" '$cur + [$id]')"
        done
        props="$(jq -n --argjson p "$props" --arg prop "$NOTION_PROP_LINKS" --argjson ids "$link_pids" \
          '$p + {($prop): {relation: ($ids | map({id: .}))}}')"
      else
        echo "WARN: --link ignored — NOTION_PROP_LINKS not set in scripts/tracker/.env (Notion has no typed issue links; set a relation property to enable --link)" >&2
      fi
    fi
  fi

  # Build the page-body block array from the Markdown spec (empty array when no body).
  children='[]'
  if [[ -n "$body_md" ]]; then
    children="$(printf '%s' "$body_md" | jq -R -s -L "$NOTION_IMPL_DIR" 'include "notion"; md_to_blocks')"
  fi
  nblocks="$(printf '%s' "$children" | jq 'length')"

  # ref "new" forces a create; otherwise resolve softly (empty → create when --title given).
  if [[ "$ticket" =~ ^[Nn][Ee][Ww]$ ]]; then
    page_id=""
  else
    page_id="$(notion_resolve_page_id "$ticket" soft)"
  fi

  if [[ -n "$page_id" ]]; then
    # Properties go on the page (PATCH /pages); body blocks are APPENDED separately
    # (PATCH /blocks/{id}/children) — the pages endpoint can't write body blocks.
    body="$(jq -n --argjson p "$props" '{properties: $p}')"
    if [[ "$dry" -eq 1 ]]; then
      [[ "$props" != "{}" ]] && printf 'DRY RUN — PATCH /pages/%s\n%s\n' "$page_id" "$(printf '%s' "$body" | jq .)"
      [[ "$nblocks" -gt 0 ]] && printf 'DRY RUN — PATCH /blocks/%s/children (%s block(s))\n%s\n' "$page_id" "$nblocks" "$(printf '%s' "$children" | jq .)"
      return 0
    fi
    if [[ "$props" != "{}" ]]; then
      resp="$(notion_api PATCH "/pages/$page_id" "$body")"
      title="$(printf '%s' "$resp" | notion_jqm 'page_title_text')"
      printf 'Updated %s — %s\n' "$ticket" "${title:-(untitled)}"
      printf 'Changed: %s\n' "$(printf '%s' "$props" | jq -r 'keys | join(", ")')"
    fi
    if [[ "$nblocks" -gt 0 ]]; then
      notion_append_blocks "$page_id" "$children"
      printf 'Appended %s body block(s) to %s\n' "$nblocks" "$ticket"
    fi
  else
    [[ "$(printf '%s' "$props" | jq --arg t "$NOTION_PROP_TITLE" 'has($t)')" == "true" ]] \
      || die "no ticket '$ticket' — pass --title to create it (the ticket number is auto-assigned, so it won't be reused)"
    # Notion accepts up to 100 children on create; any overflow is appended after.
    body="$(jq -n --argjson p "$props" --argjson c "$children" --arg db "$NOTION_DB_ID" \
      '{parent: {database_id: $db}, properties: $p} + (if ($c|length) > 0 then {children: $c[0:100]} else {} end)')"
    if [[ "$dry" -eq 1 ]]; then
      printf 'DRY RUN — POST /pages (create in %s, %s body block(s))\n%s\n' "$NOTION_DB_ID" "$nblocks" "$(printf '%s' "$body" | jq .)"
      return 0
    fi
    resp="$(notion_api POST "/pages" "$body")"
    new_id="$(printf '%s' "$resp" | jq -r '.id // empty')"
    label="$(printf '%s' "$resp" | notion_jqm '[.properties[] | select(.type=="unique_id")][0] | if . then prop_to_text else "" end')"
    title="$(printf '%s' "$resp" | notion_jqm 'page_title_text')"
    printf 'Created %s — %s\n' "${label:-(new ticket)}" "${title:-(untitled)}"
    # Append any blocks beyond the 100 the create call carried.
    if [[ "$nblocks" -gt 100 && -n "$new_id" ]]; then
      notion_append_blocks "$new_id" "$(printf '%s' "$children" | jq '.[100:]')"
      printf 'Appended %s additional body block(s)\n' "$((nblocks - 100))"
    fi
  fi
}

tracker_add_comment() {
  local ticket="$1" dry="$2" text="$3" page_id body cid resp
  page_id="$(notion_resolve_page_id "$ticket")"
  # Render the Markdown into a prettified rich_text run (bold headings, • bullets,
  # inline marks/links, aligned tables) — the /comments endpoint takes rich_text only,
  # never block children, so md_to_comment_rt also keeps each object under Notion's
  # 2000-char cap and the array under its 100-element limit.
  body="$(printf '%s' "$text" | jq -R -s -L "$NOTION_IMPL_DIR" --arg pid "$page_id" '
    include "notion";
    {parent: {page_id: $pid}, rich_text: md_to_comment_rt}')"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — POST /comments\n%s\n' "$(printf '%s' "$body" | jq .)"
    return 0
  fi
  resp="$(notion_api POST "/comments" "$body")"
  cid="$(printf '%s' "$resp" | jq -r '.id // empty')"
  printf 'Added comment to %s (id %s)\n' "$ticket" "${cid:-?}"
}

# tracker_find OPTS_JSON — OPTS = {query, open, limit, as_json, types:[...]}.
# Query the tasks database and print one compact line per match (newest first):
#   "<ID> | <Status> | <Type> | <Title>  ::  <Description>", or raw JSON with as_json.
# The dedup lookup behind /clarifying-ticket. Pagination puts the cursor in the BODY
# (POST /databases/{id}/query), so this does its own loop rather than notion_collect_pages.
tracker_find() {
  local opts="$1" query open done_only estimated limit as_json types_json conds filter sorts body resp cursor acc n
  query="$(printf '%s' "$opts" | jq -r '.query // ""')"
  open="$(printf '%s' "$opts" | jq -r '.open // false')"
  done_only="$(printf '%s' "$opts" | jq -r '.done // false')"
  estimated="$(printf '%s' "$opts" | jq -r '.estimated // false')"
  limit="$(printf '%s' "$opts" | jq -r '.limit // 50')"
  as_json="$(printf '%s' "$opts" | jq -r '.as_json // false')"
  types_json="$(printf '%s' "$opts" | jq -c '.types // []')"

  # --estimated → keep tickets with a Dev-points OR QA-points value (whichever props are
  # configured); an is_not_empty OR-group, or [] (no-op) when neither prop is set.
  local est_json='[]'
  if [[ "$estimated" == "true" ]]; then
    est_json="$(jq -n --arg dp "$NOTION_PROP_DEV_POINTS" --arg qp "$NOTION_PROP_QA_POINTS" '
      ( [ (if ($dp|length)>0 then {property:$dp, number:{is_not_empty:true}} else empty end),
          (if ($qp|length)>0 then {property:$qp, number:{is_not_empty:true}} else empty end) ] )
      | if length>0 then [{or: .}] else [] end')"
  fi

  # Build the Notion filter (AND of the supplied constraints).
  conds="$(jq -n \
    --arg q "$query" --argjson open "$open" --argjson done "$done_only" \
    --argjson est "$est_json" --argjson types "$types_json" \
    --arg pTitle "$NOTION_PROP_TITLE" --arg pStatus "$NOTION_PROP_STATUS" \
    --arg pType "$NOTION_PROP_TYPE" --arg done_name "$NOTION_STATUS_DONE" '
    []
    + (if ($q | length) > 0 then [{property: $pTitle, title: {contains: $q}}] else [] end)
    + (if $open then [{property: $pStatus, status: {does_not_equal: $done_name}}] else [] end)
    + (if $done then [{property: $pStatus, status: {equals: $done_name}}] else [] end)
    + $est
    + ( ($types | map({property: $pType, multi_select: {contains: .}}))
        | if   length == 0 then []
          elif length == 1 then [.[0]]
          else [{or: .}] end )
    ')"
  filter="$(jq -n --argjson c "$conds" 'if ($c|length)==0 then {} elif ($c|length)==1 then $c[0] else {and:$c} end')"
  sorts='[{"timestamp":"created_time","direction":"descending"}]'

  cursor=""; acc="[]"
  while :; do
    body="$(jq -n --argjson f "$filter" --argjson s "$sorts" --arg c "$cursor" \
      '{page_size:100, sorts:$s} + (if ($f|length)>0 then {filter:$f} else {} end) + (if $c!="" then {start_cursor:$c} else {} end)')"
    resp="$(notion_api POST "/databases/$NOTION_DB_ID/query" "$body")"
    acc="$(jq -n --argjson a "$acc" --argjson b "$(printf '%s' "$resp" | jq '.results')" '$a + $b')"
    [[ "$(printf '%s' "$resp" | jq -r '.has_more')" == "true" ]] || break
    cursor="$(printf '%s' "$resp" | jq -r '.next_cursor // empty')"
    [[ -n "$cursor" ]] || break
  done

  if [[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 ]]; then
    acc="$(printf '%s' "$acc" | jq --argjson n "$limit" '.[0:$n]')"
  fi

  if [[ "$as_json" == "true" ]]; then
    printf '%s\n' "$acc"; return 0
  fi

  n="$(printf '%s' "$acc" | jq 'length')"
  if [[ "$n" -eq 0 ]]; then echo "(no matching tickets)"; return 0; fi

  printf '%s' "$acc" | jq -L "$NOTION_IMPL_DIR" -r \
    --arg pStatus "$NOTION_PROP_STATUS" --arg pType "$NOTION_PROP_TYPE" --arg pDesc "$NOTION_PROP_DESCRIPTION" '
    include "notion";
    def field($name): (.properties[$name] // null) | if . then prop_to_text else "" end;
    .[]
    | ([.properties[] | select(.type=="unique_id")][0] | if . then prop_to_text else "" end) as $id
    | (field($pStatus)) as $st
    | (field($pType)) as $tt
    | (page_title_text) as $title
    | (field($pDesc)) as $desc
    | (if $id == "" then "(no id)" else $id end)
      + " | " + (if $st == "" then "—" else $st end)
      + " | " + (if $tt == "" then "—" else $tt end)
      + " | " + (if $title == "" then "(untitled)" else $title end)
      + (if $desc == "" then "" else "  ::  " + $desc end)
  '
}
