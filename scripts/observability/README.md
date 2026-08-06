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

> ⚠️ **ISO-8601 arguments are read as LOCAL time; SigNoz timestamps are UTC.** Passing a trace's
> clock time straight back queries the wrong hour and returns a confidently wrong answer — pass
> **epoch ms** when correlating against a trace.

> **Not every attribute is populated by every emitter.** APISIX-lua fills `http.target` /
> `apisix.route_name`, not SigNoz's normalized `httpUrl` / `httpHost`, so a `--by` on the wrong key
> returns one `(unset)` bucket. The tool says so rather than reporting a total of zero.

## Provider interface (`lib.sh`)

- `obs_require_config` — validate the provider's env, die if missing
- `obs_get_trace TRACE_ID [SPAN_ID]` — print the trace's span waterfall
- `obs_query_logs FILTERS_JSON FROM_MS TO_MS [LIMIT] [RAW]` — print matching log lines, newest
  first. `FILTERS_JSON` is a provider-agnostic semantic object (any subset of `service`,
  `severity`, `env`, `body_contains`, `trace_id`); the provider impl translates it into the
  backend's native filter. `RAW=1` prints the raw JSON response.

## Notes

- The signoz implementation targets query-service's OSS routes (`GET /api/v1/traces/{id}`,
  `POST /api/v4/query_range`) as of SigNoz v0.55+. If this instance is on a different
  version and a call 404s, check its `/api` docs and adjust the endpoint in
  `signoz/impl.sh` — the parsing is defensive and falls back to raw JSON when the
  response shape doesn't match what's expected, so a version mismatch fails loud rather
  than silently mis-parsing.
- To add another provider: create `scripts/observability/<name>/impl.sh` implementing
  the three functions above, then set `OBSERVABILITY_PROVIDER=<name>`.
