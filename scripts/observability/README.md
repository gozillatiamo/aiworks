# Observability adapter

Read-only access to traces and logs, mirroring the `scripts/vcs` / `scripts/tracker` /
`scripts/notify` adapters: an entry script per operation, a `lib.sh` dispatcher that
picks a provider by env var, and a `<provider>/impl.sh` implementing the interface.
Always go through these scripts — never call the SigNoz API directly.

## Setup

```bash
cp scripts/observability/.env.example scripts/observability/.env
# then edit scripts/observability/.env and set SIGNOZ_API_KEY
```

`.env` is git-ignored (the workspace's blanket `.env` / `.env.*` rule already covers it).

## Usage

```bash
# Trace waterfall (from a SigNoz trace URL: /trace/<trace_id>?spanId=<span_id>)
scripts/observability/get-trace.sh <trace_id> [--span <span_id>] [--raw]

# SEARCH and COUNT traces — the base rate, before explaining any single one
scripts/observability/find-traces.sh \
  [--service <name>] [--status <code>] [--error] [--operation <name>] \
  [--tag k=v]... [--min-duration <ms>] \
  [--since -7d] [--until now] \
  [--by <attribute>] [--interval 1h] [--list] [--limit 20] [--raw]

# Logs — explicit filter flags (each ANDed; comma-separate --service/--severity for several)
scripts/observability/get-logs.sh \
  [--service <name>] [--severity <level>] [--env local|dev|staging|prod] \
  [--body-contains <substr>] [--trace-id <hex>] \
  [--from -1h] [--to now] [--limit 100] [--raw]

# Metrics — a PromQL range query (no --env: the query carries its own label matcher)
scripts/observability/get-metric.sh --promql '<query>' \
  [--from -1h] [--to now] [--step 2m] [--summary] [--limit-series 50] [--raw] [--dry-run]

# Dashboards — list, read one, inspect or run a widget's query
scripts/observability/get-dashboard.sh list [--search <substr>]
scripts/observability/get-dashboard.sh get <dashboard-id>
scripts/observability/get-dashboard.sh widget <dashboard-id> <widget-id>
scripts/observability/get-dashboard.sh widget <dashboard-id> <widget-id> --run \
  [--from -6h] [--to now] [--step 2m] [--var <name>=<value>]... [--summary] [--dry-run]
```

> **Filters use the backend's STRUCTURED filter form, not a free-text expression.** This SigNoz
> instance silently *ignores* a free-text `filter.expression` — it returns the latest logs
> regardless, so a wrong query looks like "wrong/extra logs", not an error. The flags above map
> to structured filter items in `signoz/impl.sh`; that is the only reliable path. Don't add a
> free-text query flag back.

### Base rate first

`get-trace.sh` answers *what happened in this request*. `find-traces.sh` answers the question that
has to come first — *how often does this happen, and when* — because the shape of that answer
eliminates whole families of cause before any code is read:

```bash
# clustered or spread? the single most decisive cheap query
find-traces.sh --service APISIX --status 502 --since -7d --interval 1h
# which route/host carries them
find-traces.sh --service APISIX --status 502 --since -7d --by httpRoute
# sample ids to hand to get-trace.sh
find-traces.sh --service APISIX --status 502 --since -7d --list
```

A clustered result rules out steady causes (request content, an always-wrong branch); a spread one
rules out episodic causes (a deploy, an eviction). The output says which it found. `/root-cause-deployed`
drives this.

> **Time is unambiguous or refused.** `--since`/`--until` take `-Nm`/`-Nh`/`-Nd`, epoch ms, or an
> ISO-8601 string **carrying its offset** (`2026-08-10T22:00:00+07:00`, `2026-08-10T15:00:00Z` —
> the same instant). A bare `2026-08-10T22:00:00` is rejected rather than read as the shell's
> timezone. It used to be read as local time, which was the quietest possible bug: SigNoz stores
> UTC, so passing a trace's own clock time straight back shifted the window seven hours under
> Asia/Bangkok and returned a confident, well-formed answer about the wrong hours.

> **Not every attribute is populated by every emitter.** APISIX-lua fills `http.target` /
> `apisix.route_name`, not SigNoz's normalized `httpUrl` / `httpHost`, so a `--by` on the wrong key
> returns one `(unset)` bucket. The tool says so rather than reporting a total of zero.

### Metrics and dashboards

`get-metric.sh` prints `{query, window:{from,to,step_s}, series:[{labels, summary, points}]}`,
series sorted by `summary.peak` descending. `points` are `[<epoch_ms>, <number|null>]` pairs — a
`NaN` / `+Inf` / `-Inf` value becomes `null` and the summary skips it. `summary` is
`{current, current_time, peak, peak_time, min, points, trend}` (ISO-8601 UTC times); `trend`
compares the mean of the first 10 % of points with the mean of the last 10 %, as a ratio of
`|peak|`: `|r| < 0.05` flat, `r > 0` rising, else falling.

- **No `--env` flag.** PromQL carries the environment itself — a label matcher
  (`{deployment_environment="staging"}`) or a `by (...)` label. The adapter never rewrites the
  query; the text reaches the backend byte-exact (built with `jq --arg`), so pass it single-quoted
  with PromQL's own escaping, and a backend parse error is printed verbatim with exit 1.
- `--step` defaults to `max(1m, range/300)` rounded up to a minute (6 h gives 2 m); more than
  11000 points is refused with a suggested step.
- `--summary` drops `points`; `--limit-series N` keeps the N highest peaks and counts the rest on
  stderr; `--raw` prints the backend response unparsed; `--dry-run` prints method, URL, the auth
  header with the key masked, and the body, and sends nothing.

`get-dashboard.sh get` lists each widget's `query_type` (`promql | builder | clickhouse_sql`,
inferred when an older dashboard schema has no `query.queryType`); `widget` prints the stored
query object; `widget --run` rebuilds it as the backend's composite query and prints one
`get-metric.sh`-shaped block per query name. A dashboard variable the query references
(`$name` or `{{.name}}`) resolves from `--var`, then the dashboard default — an unresolved one is
refused before any request. PromQL widgets are the guaranteed path; builder / ClickHouse widgets
run best-effort and fall back to raw JSON plus a stderr `note:` when the result is not series.

Metric series are aggregates, not personal data: unlike `get-logs.sh` / `get-trace.sh`, these
two scripts do not feed the PII provenance vault.

## Provider interface (`lib.sh`)

- `obs_require_config` — validate the provider's env, die if missing
- `obs_get_trace TRACE_ID [SPAN_ID]` — print the trace's span waterfall
- `obs_query_logs FILTERS_JSON FROM_MS TO_MS [LIMIT] [RAW]` — print matching log lines, newest
  first. `FILTERS_JSON` is a provider-agnostic semantic object (any subset of `service`,
  `severity`, `env`, `body_contains`, `trace_id`); the provider impl translates it into the
  backend's native filter. `RAW=1` prints the raw JSON response.
- `obs_query_promql QUERY FROM_MS TO_MS STEP_S` — run a PromQL range query; print
  `{series:[{query, labels, points:[[ms, number|null]]}]}` (non-numeric values become `null`).
  `OBS_RAW=1` prints the response unparsed; `OBS_DRY_RUN=1` prints the request and sends nothing.
- `obs_query_composite COMPOSITE_JSON VARIABLES_JSON FROM_MS TO_MS STEP_S` — same, for a widget's
  own composite query with its `{name: value}` variables.
- `obs_list_dashboards` — print `[{id, title, tags, widgets:<count>}]`.
- `obs_get_dashboard ID` — print `{id, title, variables:[{name, default}], widgets:[<raw widget>]}`.

`lib.sh` also holds the shared, provider-agnostic pieces: `obs_step_s` (the default step and the
point cap) and `obs_series_report` (the summary / sort / `--summary` / `--limit-series` shaping).
Entry scripts never call `curl`; all HTTP sits in the provider's `impl.sh`.

## Notes

- The signoz implementation targets query-service's OSS routes (`GET /api/v1/traces/{id}`,
  `POST /api/v4/query_range`) as of SigNoz v0.55+. If this instance is on a different
  version and a call 404s, check its `/api` docs and adjust the endpoint in
  `signoz/impl.sh` — the parsing is defensive and falls back to raw JSON when the
  response shape doesn't match what's expected, so a version mismatch fails loud rather
  than silently mis-parsing.
- To add another provider: create `scripts/observability/<name>/impl.sh` implementing
  the functions above, then set `OBSERVABILITY_PROVIDER=<name>`.
- `selftest.sh` is the hermetic regression for the metrics + dashboard scripts: no network, no
  credentials, no `.env` — a fake `curl` records the request and serves inline fixtures.
