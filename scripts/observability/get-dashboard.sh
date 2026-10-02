#!/usr/bin/env bash
# List dashboards, read one, and inspect or run a widget's query on the observability backend.
#
#   ./get-dashboard.sh list [--search <substr>]
#   ./get-dashboard.sh get <dashboard-id>
#   ./get-dashboard.sh widget <dashboard-id> <widget-id>
#   ./get-dashboard.sh widget <dashboard-id> <widget-id> --run --from -6h --var env=staging --summary
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: get-dashboard.sh list [--search <substr>]
       get-dashboard.sh get <dashboard-id>
       get-dashboard.sh widget <dashboard-id> <widget-id>
       get-dashboard.sh widget <dashboard-id> <widget-id> --run [--from <when>] [--to <when>]
                        [--step <dur>] [--var <name>=<value> ...] [--summary] [--dry-run]

  list    JSON [{id, title, tags, widgets:<count>}]; --search filters on title, case-insensitive.
  get     JSON {id, title, variables:[{name, default}], widgets:[{id, title, panel_type,
          query_type: promql|builder|clickhouse_sql, queries:[<name>...]}]}.
  widget  JSON {id, title, panel_type, query_type, queries:<the widget's own query object>} —
          PromQL text, builder query data, or ClickHouse SQL, exactly as stored.
  --run   Run the widget's queries over the window (same --from/--to/--step as get-metric.sh)
          and print one get-metric.sh report block per query name. A dashboard variable the
          query references ($name or {{.name}}) resolves from --var, then the dashboard default;
          an unresolved one is REFUSED before any request. --summary drops points; --dry-run
          prints the request and sends nothing.

Exit: 0 ok · 1 backend error or unknown dashboard/widget (lists the valid widget ids) · 2 usage.
Environment: OBSERVABILITY_PROVIDER signoz (default). Provider creds live in .env.
EOF
}

# jq helpers shared by get / widget: query_type comes from query.queryType or, on an older
# dashboard schema, from whichever of promql[] / builder.queryData[] / clickhouse_sql[] is used.
JQ_DEFS='
  def qtype: .query.queryType // (
    if ((.query.promql // []) | length) > 0 then "promql"
    elif ((.query.builder.queryData // []) | length) > 0 then "builder"
    elif ((.query.clickhouse_sql // []) | length) > 0 then "clickhouse_sql"
    else "unknown" end);
  def qnames: (qtype) as $t |
    if $t == "promql" then [.query.promql[]?.name]
    elif $t == "builder" then [.query.builder.queryData[]?.queryName, .query.builder.queryFormulas[]?.queryName]
    elif $t == "clickhouse_sql" then [.query.clickhouse_sql[]?.name]
    else [] end;
  def wsummary: {id, title: (.title // ""), panel_type: (.panelTypes // .panelType // ""), query_type: qtype, queries: qnames};'

sub="${1:-}"; [[ -n "$sub" ]] && shift
case "$sub" in -h|--help) usage; exit 0 ;; list|get|widget) ;; *) usage >&2; exit 2 ;; esac

search="" dash="" wid="" run=0 from="-1h" to="now" step="" summary=0 dry_run=0 vars='{}'
if [[ "$sub" != list ]]; then dash="${1:-}"; [[ -n "$dash" ]] && shift; [[ -n "$dash" ]] || { usage >&2; exit 2; }; fi
if [[ "$sub" == widget ]]; then wid="${1:-}"; [[ -n "$wid" ]] && shift; [[ -n "$wid" ]] || { usage >&2; exit 2; }; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --search) search="${2:-}"; shift 2 ;;
    --run) run=1; shift ;;
    --from) from="${2:-}"; shift 2 ;;
    --to) to="${2:-}"; shift 2 ;;
    --step) step="${2:-}"; shift 2 ;;
    --var) [[ "${2:-}" == *=* ]] || { echo "error: --var expects <name>=<value>" >&2; exit 2; }
           vars="$(jq -c --arg k "${2%%=*}" --arg v "${2#*=}" '. + {($k): $v}' <<<"$vars")"; shift 2 ;;
    --summary) summary=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

case "$sub" in
  list)
    obs_list_dashboards | jq --arg s "$search" '[.[] | select($s == "" or (.title | ascii_downcase | contains($s | ascii_downcase)))]'
    ;;
  get)
    obs_get_dashboard "$dash" | jq "$JQ_DEFS"' {id, title, variables, widgets: [.widgets[] | wsummary]}'
    ;;
  widget)
    d="$(obs_get_dashboard "$dash")"
    w="$(jq -c --arg w "$wid" '[.widgets[] | select(.id == $w)] | first // empty' <<<"$d")"
    if [[ -z "$w" ]]; then
      echo "error: no widget '$wid' in dashboard $dash — valid widgets:" >&2
      jq -r '.widgets[] | "  \(.id)  \(.title // "")"' <<<"$d" >&2
      exit 1
    fi
    if [[ $run -eq 0 ]]; then
      jq "$JQ_DEFS"' wsummary + {queries: .query}' <<<"$w"
      exit 0
    fi
    if jq -e '.query.v5 == true' <<<"$w" >/dev/null; then
      echo "error: widget '$wid' is a builder query in the v2 dashboard shape, which this adapter cannot run" \
           "(/api/v4/query_range takes the v4 builder shape) — read it with 'widget' and run its PromQL/SQL equivalent via get-metric.sh" >&2
      exit 1
    fi
    # --run: the widget's own composite query, disabled entries dropped, keyed the way the
    # query_range API expects (promQueries / builderQueries incl. formulas / chQueries).
    cq="$(jq -c "$JQ_DEFS"' (qtype) as $t | .query as $q
      | {queryType: $t, panelType: (.panelTypes // .panelType // "graph")}
      + (if $t == "promql" then {promQueries: ([$q.promql[] | select(.disabled | not) | {(.name): .}] | add // {})}
         elif $t == "builder" then {builderQueries: ([($q.builder.queryData[]?, $q.builder.queryFormulas[]?) | select(.disabled | not) | {(.queryName): .}] | add // {})}
         elif $t == "clickhouse_sql" then {chQueries: ([$q.clickhouse_sql[] | select(.disabled | not) | {(.name): .}] | add // {})}
         else {} end)' <<<"$w")"
    # Variables the query references ($name or {{.name}}; `__*` are the backend's own) resolve
    # from --var, then the dashboard default; anything left is refused before any request.
    # A legend is a display template ({{label}} of the SERIES), not a query reference: skip it, or
    # every legend label reads as an unresolved variable and refuses a runnable widget.
    refs="$(jq -r 'walk(if type == "object" then del(.legend) else . end) | [.. | strings] | join("\n")' <<<"$cq" \
      | grep -oE '\$[A-Za-z_][A-Za-z0-9_.]*|\{\{[[:space:]]*\.?[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*\}\}' \
      | sed -E 's/^\$//; s/^\{\{[[:space:]]*\.?//; s/[[:space:]]*\}\}$//' | grep -v '^__' | sort -u || true)"
    unresolved=()
    for name in $refs; do
      if jq -e --arg n "$name" 'has($n)' <<<"$vars" >/dev/null; then continue; fi
      def="$(jq -r --arg n "$name" '[.variables[] | select(.name == $n) | .default] | first // null' <<<"$d")"
      if [[ "$def" == null ]]; then unresolved+=("$name"); else vars="$(jq -c --arg k "$name" --arg v "$def" '. + {($k): $v}' <<<"$vars")"; fi
    done
    if [[ ${#unresolved[@]} -gt 0 ]]; then
      echo "error: unresolved dashboard variable(s): ${unresolved[*]} — pass --var <name>=<value> (no dashboard default)" >&2
      exit 1
    fi
    from_ms="$(obs_epoch_ms "$from")"; to_ms="$(obs_epoch_ms "$to")"
    [[ "$from_ms" -lt "$to_ms" ]] || { echo "error: --from ($from) is not before --to ($to)" >&2; exit 2; }
    step_s="$(obs_step_s "$from_ms" "$to_ms" "$step")"
    if [[ $dry_run -eq 1 ]]; then OBS_DRY_RUN=1 obs_query_composite "$cq" "$vars" "$from_ms" "$to_ms" "$step_s"; exit 0; fi
    resp="$(obs_query_composite "$cq" "$vars" "$from_ms" "$to_ms" "$step_s")"
    if ! printf '%s' "$resp" | jq -e 'has("series")' >/dev/null 2>&1; then printf '%s\n' "$resp"; exit 0; fi
    for name in $(jq -r '(.promQueries // .builderQueries // .chQueries // {}) | keys[]' <<<"$cq"); do
      printf '%s' "$resp" | jq -c --arg n "$name" '{series: [.series[] | select(.query == $n)]}' \
        | obs_series_report "$name" "$from_ms" "$to_ms" "$step_s" "$summary" 50
    done
    ;;
esac
