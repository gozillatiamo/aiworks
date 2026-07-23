# scripts/db — production Postgres, read-only

`prod_pg_mcp.py` is an **on-demand, read-only MCP server** over the OFB **production**
Postgres fleet. One MCP process serves the whole fleet; the database a tool touches is
chosen **per call** by a `target` argument, so there is no per-shard server to spin up.

It is the DB counterpart of the SigNoz `telemetry-triage` flow: ground-truth production
data for root-causing a live issue, read-only, with a clean teardown. The driving skill is
`prod-pg-triage` (`.claude/skills/prod-pg-triage/`).

This is **opt-in and personal** — it is deliberately *not* in the shared `.mcp.json`, so it
never spawns for teammates who aren't doing prod triage and never carries prod credentials
into the shared repo. You register it in local scope on the machine that has the read-only
DSNs.

## Targets

| Target        | Selector                                   | Notes                                            |
|---------------|--------------------------------------------|--------------------------------------------------|
| MAD (master)  | `target="mad"`                             | Explicit only — never resolved from an agency id |
| ASS shard 0-f | `target="<hex>"` or `agency_id="<id>"`     | Shard = first char of the agency id; 1 host = 2 shards, so 0-f live across ASS1-8 |

## Setup (one-time, per machine)

1. **Create the read-only credentials file** from the template and fill in real values.
   Use a **read-only DB role** for every DSN.

   ```bash
   cp scripts/db/.env.example scripts/db/.env
   # edit scripts/db/.env  (git-ignored; also blocked by the .env-guard hook)
   ```

2. **Pre-warm deps + validate config** (prints only which targets are set — never a DSN):

   ```bash
   uv run scripts/db/prod_pg_mcp.py --selftest
   ```

3. **Register the MCP in local scope** (personal, this project only) — use an absolute path
   so it resolves regardless of the session's cwd:

   ```bash
   claude mcp add prod_pg_triage --scope local -- \
     uv run --quiet "$(pwd)/scripts/db/prod_pg_mcp.py"
   ```

   Restart the Claude session so it connects. The `mcp__prod_pg_triage__*` tools then appear.
   To remove it: `claude mcp remove prod_pg_triage --scope local`.

## Tools

| Tool                 | Purpose                                                             |
|----------------------|---------------------------------------------------------------------|
| `list_targets`       | Which targets are configured / have an open pool. No prod access.   |
| `resolve_shard`      | `agency_id` → shard hex. Pure lookup, no DB access.                 |
| `list_schemas`       | User schemas on a target.                                           |
| `list_objects`       | Tables/views in a schema (optional `object_type` filter).           |
| `get_object_details` | Columns + indexes of a table/view.                                  |
| `explain_query`      | Query plan. `analyze=True` runs the query (off by default).         |
| `execute_sql`        | Read-only query, paginated at 200 rows/page.                        |
| `disconnect`         | Close all prod pools — the teardown. Leaves zero open connections.  |

Every data tool takes `target` **or** `agency_id`.

## Safety model (layered)

A production DB behind an AI tool is a real risk, so protection does not rely on any single
mechanism:

1. **Read-only DB role** in every DSN — the actual guarantee. Nothing else is trusted to
   substitute for it.
2. **Read-only transaction + timeouts** forced on every connection
   (`default_transaction_read_only=on`, `statement_timeout=15s`,
   `idle_in_transaction_session_timeout=30s`) — the DB itself rejects any write, including
   writable CTEs, with a clear error.
3. **SQL shape guard** — `execute_sql` accepts only a single SELECT / WITH / TABLE / VALUES
   statement; `explain_query` handles EXPLAIN. This is for clear errors, not the guarantee.
4. **Pagination** — results capped at 200 rows/page so a wide table can't flood context.
5. **Lazy + teardown** — `min_size=0` pools hold no prod connection until first use, and
   `disconnect()` drops every pool when a job is done; the Claude-managed process stays up
   but idle.

Credentials live only in `scripts/db/.env`, read only by this server process — never through
Claude, the MCP config, or the transcript. Do not Read/cat/grep the `.env`.
