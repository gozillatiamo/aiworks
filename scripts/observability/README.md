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

# Logs
scripts/observability/get-logs.sh --query "service.name = 'x' AND severity_text = 'ERROR'" \
  [--from -1h] [--to now] [--limit 100] [--raw]
```

## Provider interface (`lib.sh`)

- `obs_require_config` — validate the provider's env, die if missing
- `obs_get_trace TRACE_ID [SPAN_ID]` — print the trace's span waterfall
- `obs_query_logs QUERY FROM_MS TO_MS [LIMIT]` — print matching log lines, newest first

## Notes

- The signoz implementation targets query-service's OSS routes (`GET /api/v1/traces/{id}`,
  `POST /api/v4/query_range`) as of SigNoz v0.55+. If this instance is on a different
  version and a call 404s, check its `/api` docs and adjust the endpoint in
  `signoz/impl.sh` — the parsing is defensive and falls back to raw JSON when the
  response shape doesn't match what's expected, so a version mismatch fails loud rather
  than silently mis-parsing.
- To add another provider: create `scripts/observability/<name>/impl.sh` implementing
  the three functions above, then set `OBSERVABILITY_PROVIDER=<name>`.
