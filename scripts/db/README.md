# scripts/db — production Postgres, read-only

`prod_pg_mcp.py` is an **on-demand, read-only MCP server** over your **production** Postgres.
One MCP process serves as many databases as you configure; the database a tool touches is
chosen **per call** by a `target` argument, so there is no per-database server to spin up.

It is ground-truth production data for root-causing a live issue — read-only, with a clean
teardown. The driving skill is `prod-pg-triage` (`.claude/skills/prod-pg-triage/`).

This is **opt-in and personal** — it is deliberately *not* in the shared `.mcp.json`, so it
never spawns for teammates who aren't doing prod triage and never carries prod credentials
into the shared repo. You register it in local scope on the machine that has the read-only
DSNs.

## Targets

A target is a name you configure with a `PGPROD_<NAME>` DSN in `scripts/db/.env`, addressed
as `target="<name>"` at call time:

| Env var             | Address as           | Notes                                             |
|---------------------|----------------------|---------------------------------------------------|
| `PGPROD_MAIN`       | `target="main"`      | Your primary database.                            |
| `PGPROD_SECONDARY`  | `target="secondary"` | A second database, if any.                        |
| `PGPROD_<NAME>`     | `target="<name>"`    | Any additional database.                          |

There is **no sharding scheme baked in**. If your data is split across several databases,
declare one target per database (`PGPROD_SHARD0`, `PGPROD_SHARD1`, …) and address each
explicitly; a fleet-wide check is just a query per target.

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

   Restart the session so it connects. The `mcp__prod_pg_triage__*` tools then appear.
   To remove it: `claude mcp remove prod_pg_triage --scope local`.

## Tools

| Tool                 | Purpose                                                             |
|----------------------|---------------------------------------------------------------------|
| `list_targets`       | Which targets are configured / have an open pool. No prod access.   |
| `list_schemas`       | User schemas on a target.                                           |
| `list_objects`       | Tables/views in a schema (optional `object_type` filter).           |
| `get_object_details` | Columns + indexes of a table/view.                                  |
| `explain_query`      | Query plan. `analyze=True` runs the query (off by default).         |
| `execute_sql`        | Read-only query, paginated at 200 rows/page.                        |
| `disconnect`         | Close all prod pools — the teardown. Leaves zero open connections.  |

Every data tool takes a `target`.

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
   `disconnect()` drops every pool when a job is done; the managed process stays up but idle.

Credentials live only in `scripts/db/.env`, read only by this server process — never through
the agent, the MCP config, or the transcript. Do not Read/cat/grep the `.env`.

## Repro seeding — `prod_repro_seed.py`

`prod_repro_seed.py` is the **one sanctioned path** to move production data into a **local**
repro database, used by the developer inside `/diagnosing-bugs` when a data bug only
reproduces against the actual offending rows. It reads prod through the same read-only DSNs,
then **masks external PII and loads an entity-scoped slice into a throwaway `repro_<ticket>`
database** — never the shared local DB. `reproduce-then-DROP`, so nothing prod-derived
lingers locally.

Enforced invariants (in code, not memory):

1. **Read-only prod** — same read-only role + read-only transaction as the MCP; never writes prod.
2. **Hard mask on persist** — every external-PII value (`scripts/lib/pii-patterns.txt`, the same
   list every engine reads) and PII-named column is masked before the local write.
   Inner-system identity (any `*_code`, UUID), money integers and status survive.
   The same values are also fingerprinted into the **provenance vault**, so if one later surfaces
   in a ticket or a chat post the adapters redact it there too — and only it, never the
   identical-looking local/staging data (`docs/agents/pii-provenance.md`).
3. **Throwaway, isolated DBs** — data lands in `repro_<ticket>_<seed>` (created from a
   `template_db` that has the schema); `--teardown` DROPs every one for the ticket, across
   instances. Never the shared local DB.
4. **Entity-scoped** — seed the rows reachable from the ticket's identifier; a run above the
   row caps (per-table 500 / total 2000 across all seeds) needs `--approve-large`.

**Multi-source.** If your service connects to more than one database at once, a spec is a list
of `seeds` — each pulls one prod `target` into one throwaway DB on one local instance (chosen
by `local.admin_env`). Seed a multi-database bug with all of them in one run; the tool prints
which DB to wire to each of the service's connections. A single-source bug can use the flat
`{source, template_db, tables}` shorthand.

Extra config in `scripts/db/.env` — **local** maintenance DSNs with CREATEDB/DROPDB rights (NOT
prod): `PGLOCAL_ADMIN` (fallback for shorthand specs) and optional per-instance
`PGLOCAL_<NAME>_ADMIN` DSNs matching a seed's `local.admin_env`. Leave unset on machines that
don't run repro seeding.

```bash
uv run scripts/db/prod_repro_seed.py --selftest                          # deps/config/mask, no DB access
uv run scripts/db/prod_repro_seed.py --ticket APP-123 --spec seed.json --dry-run   # pull+mask preview
uv run scripts/db/prod_repro_seed.py --ticket APP-123 --spec seed.json --fk-bypass # create + load masked
uv run scripts/db/prod_repro_seed.py --ticket APP-123 --teardown                   # DROP the throwaway DB
```

**Two persist modes.** The default (above) is the **isolated throwaway** — a fresh
`repro_<ticket>_<seed>` DB the service must be pointed at. Reconfiguring the service's DB
connection is extra friction (and, under auto mode, a `docker compose up` with prod-shaped env
can trip the safety classifier). The alternative is `--into-db <localdb>`: load the masked
slice straight into the **existing local DB the running service already uses**, so the service
reproduces with **zero reconfig**. It trades isolation for simplicity — the local DB is
polluted with masked prod-derived rows until cleaned — and `--teardown` becomes a **targeted
DELETE** (by each table's `where`), never a `DROP`, so it needs the spec and preserves the DB +
all other data.

```bash
uv run scripts/db/prod_repro_seed.py --into-db app_local --spec seed.json --fk-bypass   # load into the local DB, no throwaway
uv run scripts/db/prod_repro_seed.py --into-db app_local --spec seed.json --teardown     # DELETE only the seeded rows (DB kept)
```

The read-only triage MCP does **not** use `PGLOCAL_*` and never seeds — reading and finding
is its whole job. Only the developer's `/diagnosing-bugs` flow persists, and only through this tool.
