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

## Repro seeding — `prod_repro_seed.py`

`prod_repro_seed.py` is the **one sanctioned path** to move production data into a **local**
repro database, used by the developer inside `/diagnosing-bugs` when a data bug only
reproduces against the actual offending rows. It reads prod through the same read-only DSNs,
then **masks external PII and loads an entity-scoped slice into a throwaway `ofb_repro_<ticket>`
database** — never the shared local DB. `reproduce-then-DROP`, so nothing prod-derived
lingers locally.

Enforced invariants (in code, not memory):

1. **Read-only prod** — same read-only role + read-only transaction as the MCP; never writes prod.
2. **Hard mask on persist** — every external-PII value (`scripts/lib/pii-patterns.txt`, the same
   list every engine reads) and PII-named column is masked before the local write.
   Inner-system identity (`player_code`/`site_code`/`*_code`, UUID), money integers and status survive.
   The same values are also fingerprinted into the **provenance vault**, so if one later surfaces
   in a ticket or a Slack post the adapters redact it there too — and only it, never the
   identical-looking local/staging data (`docs/agents/pii-provenance.md`).
3. **Throwaway, isolated DBs** — data lands in `ofb_repro_<ticket>_<seed>` (created from a
   `template_db` that has the schema); `--teardown` DROPs every one for the ticket, across
   instances. Never the shared local DB.
4. **Entity-scoped** — seed the rows reachable from the ticket's identifier; a run above the
   row caps (per-table 500 / total 2000 across all seeds) needs `--approve-large`.

**Split-topology, multi-source.** OFB's service connects to the master (MAD) **and** a player
shard (ASS) at once, so a spec is a list of `seeds` — each pulls one prod source (`target`/
`agency_id`) into one throwaway DB on one local instance (chosen by `local.admin_env`). Seed a
MAD+shard bug with both in one run; the tool prints which DB to wire to the service's MASTER vs
SHARD connection. A single-source bug can use the flat `{source, template_db, tables}` shorthand.

Extra config in `scripts/db/.env` — **local** maintenance DSNs with CREATEDB/DROPDB rights (NOT
prod): `PGLOCAL_MAD_ADMIN` (local master instance, default :5432), `PGLOCAL_ASS_ADMIN` (local
shard instance, default :5433), and `PGLOCAL_ADMIN` (fallback for shorthand specs). Leave unset
on machines that don't run repro seeding.

```bash
uv run scripts/db/prod_repro_seed.py --selftest                          # deps/config/mask, no DB access
uv run scripts/db/prod_repro_seed.py --ticket OFB-123 --spec seed.json --dry-run   # pull+mask preview
uv run scripts/db/prod_repro_seed.py --ticket OFB-123 --spec seed.json --fk-bypass # create + load masked
uv run scripts/db/prod_repro_seed.py --ticket OFB-123 --teardown                   # DROP the throwaway DB
```

**Two persist modes.** The default (above) is the **isolated throwaway** — a fresh `ofb_repro_<ticket>_<seed>` DB the service must be pointed at. Reconfiguring the service's DB connection is extra friction (and, under auto mode, a `docker compose up` with prod-shaped env can trip the safety classifier). The alternative is `--into-db <localdb>`: load the masked slice straight into the **existing local DB the running service already uses** (the local Postgres from `agent-db run`, not the deployed `dev` server), so the service reproduces with **zero reconfig**. It trades isolation for simplicity — the local DB is polluted with masked prod-derived rows until cleaned — and `--teardown` becomes a **targeted DELETE** (by each table's `where`), never a `DROP`, so it needs the spec and preserves the DB + all other data.

```bash
uv run scripts/db/prod_repro_seed.py --into-db ofb_local --spec seed.json --fk-bypass   # load into the local DB, no throwaway
uv run scripts/db/prod_repro_seed.py --into-db ofb_local --spec seed.json --teardown     # DELETE only the seeded rows (DB kept)
```

The read-only triage MCP does **not** use `PGLOCAL_ADMIN` and never seeds — reading and finding
is its whole job. Only the developer's `/diagnosing-bugs` flow persists, and only through this tool.
