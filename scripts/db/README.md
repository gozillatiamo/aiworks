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

A target is just a database. Nothing about your topology is assumed until you declare it.

### Shards (optional)

If your data is split across up to 16 databases keyed by one hex digit (`0`–`f`), declare each
one's shard role and the triage tools can route to it for you:

| Env var                          | Declares                          | Address as          |
|----------------------------------|-----------------------------------|---------------------|
| `PGPROD_SHARD_<HEX>`             | shard `<hex>`                     | `target="<hex>"`    |
| `PGPROD_<LABEL>_SHARD_<HEX>`     | shard `<hex>`; `<LABEL>` is free-form (e.g. the host, `HOST1`) | `target="<hex>"` |
| `PGPROD_<NAME>` + `PGPROD_<NAME>_SHARD=<hex>` | shard `<hex>` for an existing named DSN | `target="<hex>"` |

- The target key is always `shard_<hex>`, whichever var backs it; `list_targets` shows the var
  (`kind: shard`; everything else is `kind: named`).
- Two vars claiming the same hex is a conflict: that shard reads as unconfigured and every claimant
  is named (`conflict: [vars]` in `list_targets`, a FAIL line in `--selftest`). Fix
  `scripts/db/.env`; nothing is guessed.
- `resolve_shard(routing_key)` maps an identifier to its shard by its **first character** (`0`–`f`).
  Data tools accept `routing_key=` instead of `target=`. This is the only place the framework assumes
  a keyspace, and it engages only when you declare a shard.
- Staging shard databases are named by `PGSTG_DB_SHARD_FMT` (default `shard_%s`, which is also the
  plain name default).
- `PGPROD_SHARD0` (no underscore before the hex) is an ordinary named target, `shard0`.

> **Upgrading:** a var that ends in `_SHARD_<hex>` or `_SHARD` used to be an ordinary named target
> and is now a shard declaration. `--selftest` lists every key it reinterprets.

Declare no shard vars and every target behaves as a plain named database, as before.

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
a target, declare a tunnel sidecar beside its DSN and the MCP will port-forward for you. Two
transports exist: `gcloud` (a per-target IAP SSH forward) and `gost` (ONE shared SOCKS5
forwarder for every gost target).

### Declaring a tunnel

Add a `_TUNNEL` sidecar in `scripts/db/.env` next to the target DSN:

```bash
PGPROD_MAIN=postgresql://readonly:pw@prod-db.internal:5432/app?sslmode=verify-full
PGPROD_MAIN_TUNNEL=tunnel=gcloud;host=prod-db.internal;port=5432;local=15432;vm=bastion-vm;zone=asia-southeast1-a

# gost: hosts live in gost.yaml; the sidecar only names the service port serving the target
PGPROD_MAIN_TUNNEL=tunnel=gost;local=65432
PGPROD_SECONDARY_TUNNEL=tunnel=gost;local=65433
```

**Supported keys:**

| Key       | Required                | Default  | Description |
|-----------|-------------------------|----------|-------------|
| `tunnel`  | no                      | `gcloud` | `gcloud` \| `gost` \| `none` (use `none` when already reachable via VPN/bastion). |
| `host`    | yes (for `gcloud`)      |          | Remote Postgres hostname as seen **from the VM** (not your laptop). gcloud only — rejected with `gost`. |
| `port`    | no                      | `5432`   | Remote Postgres port. gcloud only — rejected with `gost`. |
| `local`   | yes (`gcloud`, `gost`)  |          | Local port on 127.0.0.1. gcloud: unique across sidecars. gost: the service port in your `gost.yaml` (two targets on one host share it). Never 5432; gost ports must not overlap gcloud ports. |
| `vm`      | yes (for `gcloud`)      |          | `gcloud compute` instance name. gcloud only — rejected with `gost`. |
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
and certificate verification — a `sslmode=verify-full` DSN keeps working through the forward
(an IP-literal DSN host needs `sslmode=require`).

**`tunnel=gost`** — the first call to ANY gost target spawns one `gost -C "$PG_TRIAGE_GOST_CONFIG"`
(cwd = that file's directory) and waits until that target's `127.0.0.1:<local>` accepts TCP.
Every gost target holds the same process; a target is released after 120 s idle (or on
`disconnect`), and gost stops when the LAST holder is released. `tunnel_status` shows such
tunnels with `kind: gost`, `shared: true` and the shared pid. Readiness proves gost's listener
only — a bad proxy or SOCKS credential surfaces as a psycopg connect error within 5 s. If a gost
you started yourself with that same file is already serving every port, the MCP adopts it
instead of spawning, and never stops it: `disconnect` and idle reaping only drop the MCP's
hold. `tunnel_status` shows it as `owner: adopted`.

### gost (shared SOCKS proxy)

Point `PG_TRIAGE_GOST_CONFIG` in `scripts/db/.env` at your `gost.yaml` (absolute, or relative
to the workspace root). Keep the SOCKS credential file `socks.auth` beside it; the tools check
it exists and never open it. A gost you started yourself with that same file is adopted for
connecting and never stopped by the MCP or by `tunnel.sh kill`.

`--selftest` runs a preflight for every `tunnel=gost` sidecar and fails LOUDLY (a `!!!` banner)
when `gost` is not installed, `PG_TRIAGE_GOST_CONFIG` is unset or names a missing file,
`socks.auth` is missing (existence only — never read), or a `local` port is not a service port
in that `gost.yaml`. It also prints a non-failing `WARN` for each prod target still connecting
directly.

### Prerequisites

```bash
gcloud auth login
# The IAP-TCP-forwarding role on the VM project (when iap=true)

brew install gost        # tunnel=gost
```

### Port-in-use behaviour

A `gcloud` port already listening is **refused** — the MCP never adopts or kills a gcloud tunnel
it did not open. A `gost` port already listening is **adopted** only when the process table
proves it is this `gost.yaml`'s gost; the call is refused, naming the failed condition, when:

- the listener is not a `gost` process, or is not yours;
- more than one process listens, or one gost does not serve EVERY port declared in `gost.yaml`;
- its `-C` config does not resolve to `PG_TRIAGE_GOST_CONFIG` (a different config);
- it started before that file last changed (stale — restart it);
- it is an orphan of an earlier MCP session (ppid 1 with the MCP's own argv).

Nothing is sent to the port to decide this: a connect to gost dials prod. Inspect and clear with:

```bash
scripts/db/tunnel.sh status    # each gost labelled MCP-owned | MCP orphan | manual | detached manual
scripts/db/tunnel.sh kill      # kills MCP orphans; SPARES a manual gost and prints how you stop it
scripts/db/tunnel.sh kill main # one target by name
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
6. **Connect failures say why, never what** — a pool timeout carries a classified reason
   (`authentication failed (wrong password, or the role does not exist; …)`, `connection
   refused (…)`, `rejected by pg_hba.conf (…)`, …) captured at the source by the pool's
   connection class. A classified reason is a fixed string; only the unclassified fallback
   carries error text, exact-value scrubbed against the DSN. `psycopg.pool` warnings (raw libpq
   text on stderr) are silenced, and a DSN libpq cannot parse is refused by variable NAME —
   its parse error would echo the fragment it choked on, which can be the password.

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
