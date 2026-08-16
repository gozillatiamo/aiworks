# scripts/db — deployed Postgres (staging + production), read-only

`pg_triage_mcp.py` is an **on-demand, read-only MCP server** over your **deployed** Postgres —
**staging and production**. One MCP process serves both; which environment and which database a
tool touches is chosen **per call** by `env` + `target`, so there is no per-env or per-database
server to spin up.

It is ground truth for root-causing a live issue — read-only, with a clean teardown. The driving
skill is `pg-triage` (`.claude/skills/pg-triage/`).

It lives in **local scope**, deliberately *not* in the shared `.mcp.json`, so prod credentials
never enter the shared repo. Register it with `scripts/triage-mcp.sh sync` — **you** run that,
`aiworks sync` does not (`docs/adr/0009`); `aiworks doctor` reports when it is owed. Registration
is on by default (`triage.enabled`) because **staging needs no authorization**; **production**
needs the per-machine `triage.prod` opt-in, enforced inside the server. See `docs/adr/0005`.

## Environments and targets

`env` is **required** on every data tool — there is no default, so production is never implied.

| Env       | DSNs                              | Shape                                                     |
|-----------|-----------------------------------|-----------------------------------------------------------|
| `staging` | `PGSTG_<NAME>`, or `PGSTG_DSN`    | Per target like prod, OR one instance with a database per target (default: the target name; override with `PGSTG_DB_<NAME>`). |
| `prod`    | `PGPROD_<NAME>`                   | One DSN per database. Requires `triage.prod: true`.        |

Staging resolution lives in `scripts/lib/pg_staging.py`, shared with the repro seeder so the two
cannot disagree about which database a target means.

A target is a name you configure with a `PGPROD_<NAME>` / `PGSTG_<NAME>` DSN in `scripts/db/.env`,
addressed as `target="<name>"` at call time:

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
   uv run scripts/db/pg_triage_mcp.py --selftest
   ```

3. **Register it** — `aiworks` does this for you in local scope (personal, this project only):

   ```bash
   ./aiworks setup                  # or, on its own: scripts/triage-mcp.sh sync
   scripts/triage-mcp.sh status     # policy + what is registered
   ```

   Staging is usable from here on. **To reach production**, add the opt-in to your git-ignored
   `workspace.config.local.yaml` — the server reads it live, so this needs no re-register and no
   restart:

   ```yaml
   triage:
     prod: true
   ```

   Restart the session so it connects. The `mcp__pg_triage__*` tools then appear. Flipping
   the flag back to `false` and re-running deregisters it. By hand, if you prefer (an absolute
   path, so it resolves regardless of the session's cwd):

   ```bash
   claude mcp add pg_triage --scope local -- \
     uv run --quiet "$(pwd)/scripts/db/pg_triage_mcp.py"
   claude mcp remove pg_triage --scope local
   ```

## Tools

| Tool                 | Purpose                                                             |
|----------------------|---------------------------------------------------------------------|
| `list_targets`       | Both envs: which targets are configured, which pools are open, and whether prod is allowed. No DB access. |
| `list_schemas`       | User schemas on a target.                                           |
| `list_objects`       | Tables/views in a schema (optional `object_type` filter).           |
| `get_object_details` | Columns + indexes of a table/view.                                  |
| `explain_query`      | Query plan. `analyze=True` runs the query (off by default).         |
| `execute_sql`        | Read-only query, paginated at 200 rows/page.                        |
| `tunnel_status`      | Open tunnel sidecars: pid, up/idle seconds, time-to-reap, forward. No DB access. |
| `disconnect`         | Close pools **and** tunnels — both envs by default, or one via `env`. Leaves zero open connections. |

Every data tool takes `env` **and** `target`. Every result carries `env` + `pii_vaulted`, so a
mixed-env investigation can't mislabel where a row came from.

Every data tool takes a `target`.

## Tunnel sidecars (optional — for managed Postgres behind a VPC)

A managed Postgres instance is usually not reachable from a laptop. When you need to triage such
a target, declare a tunnel sidecar beside its DSN and the MCP will port-forward for you.

### Declaring a tunnel

Add a `_TUNNEL` sidecar in `scripts/db/.env` next to the target DSN:

```bash
PGPROD_MAIN=postgresql://readonly:pw@prod-db.internal:5432/app?sslmode=verify-full
PGPROD_MAIN_TUNNEL=tunnel=gcloud;host=prod-db.internal;port=5432;local=15432;vm=bastion-vm;zone=asia-southeast1-a
```

**Supported keys:**

| Key       | Required                | Default  | Description |
|-----------|-------------------------|----------|-------------|
| `tunnel`  | no                      | `gcloud` | `gcloud` \| `none` (use `none` when already reachable via VPN/bastion). |
| `host`    | yes (for `gcloud`)      |          | Remote Postgres hostname as seen **from the VM** (not your laptop). |
| `port`    | no                      | `5432`   | Remote Postgres port. |
| `local`   | yes (for `gcloud`)      |          | Local port to bind on 127.0.0.1. Must be unique across all sidecars; must not be 5432. |
| `vm`      | yes (for `gcloud`)      |          | `gcloud compute` instance name. |
| `zone`    | no                      |          | gcloud zone (omit to use your `gcloud config` default zone). |
| `project` | no                      |          | gcloud project (omit to use your `gcloud config` default project). |
| `iap`     | no                      | `true`   | `true` → `--tunnel-through-iap` (IAP-TCP-forwarding role required); `false` → direct SSH. |

**Naming rules:**
- A target may not be named `…_tunnel` (the suffix is reserved for sidecars, same as `dsn` is
  reserved for the staging base DSN).
- `PGSTG_DSN_TUNNEL` is not supported — the bare staging instance has no target name to attach a
  tunnel to; declare `PGSTG_<NAME>` per target instead.

### How it works

The tunnel is lazy: it is spawned on the first tool call for that target, not at process start.
It is reaped automatically after 120 s of idle time, and `disconnect` closes it immediately.
`gcloud compute ssh` connects with `--tunnel-through-iap` (or without, when `iap=false`) and the
`-L <local>:<host>:<port>` flag; the framework never runs a remote command.

The connection goes through `127.0.0.1:<local>` while the DSN's `host=` is preserved for TLS SNI
and certificate verification — a `sslmode=verify-full` DSN keeps working through the forward.

### Prerequisites

```bash
gcloud auth login
# The IAP-TCP-forwarding role on the VM project (when iap=true)
```

### Port-in-use behaviour

If `127.0.0.1:<local>` is already listening when the MCP tries to open the tunnel, the call is
**refused** — the MCP never adopts or kills a tunnel it did not open. Clear the orphan with:

```bash
scripts/db/tunnel.sh status    # see what is open
scripts/db/tunnel.sh kill      # kill all orphans
scripts/db/tunnel.sh kill main # kill one target by name
```

`tunnel.sh` is **not** granted to agents. `gcloud compute ssh` with a different operand would
give a shell on the production VM — that is why the tunnel lives inside the MCP server.

## Verifying it

```bash
uv run scripts/db/pg_triage_mcp.py --selftest                      # config + policy, no DB access
uv run scripts/db/pg_triage_mcp.py --verify staging --target main  # live read-only acceptance run
uv run scripts/db/pg_triage_mcp.py --verify prod --target main     # needs triage.prod: true
```

The staging run also asserts that a prod call is refused while the opt-in is off, and both runs
point the provenance vault at a throwaway directory so a verify never writes fingerprints into the
real one.

## Safety model (layered)

A production DB behind an AI tool is a real risk, so protection does not rely on any single
mechanism:

1. **Production opt-in** — `triage.prod` (local-first, `scripts/lib/triage_policy.py`) is checked
   before the DSN is looked up: having the credentials is not permission. Staging is ungated.
2. **Read-only DB role** in every DSN — staging included — the actual guarantee. Nothing else is trusted to
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
