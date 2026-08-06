# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "mcp>=1.2,<2",
#   "psycopg[binary]>=3.1",
#   "psycopg-pool>=3.2",
#   "python-dotenv>=1.0",
# ]
# ///
# # The <2 bound is load-bearing: mcp 2.0 removed `mcp.server.fastmcp`, so an unbounded `mcp>=1.2`
# # resolves to a release this file cannot import. It only looks fine on a machine whose uv cache
# # still holds a 1.x environment — a fresh clone gets ModuleNotFoundError on the import below.
"""pg-triage — on-demand, READ-ONLY MCP wrapper over the OFB deployed Postgres (STAGING + PROD).

One MCP process, two environments, many targets. Both axes are chosen *per call* and neither is
ever baked into the process or defaulted:

  - `env`    — "staging" or "prod". REQUIRED on every data tool: an unnamed environment is an
               error, never a guess, so production is only ever reached by asking for it.
  - `target` — which database inside that environment:
                 MAD  the master DB. Reachable only by explicit `target="mad"`; never
                      auto-resolved, so player-shard traffic can't land on the master.
                 ASS  16 player shards addressed by hex 0-f (shard = first char of an agency id).

Topology differs per environment, and only the DSN lookup knows it:
  - prod    — a fleet of hosts (1 host holds 2 shards, so 0-f live across ASS1-8). One DSN per
              target: `PGPROD_MAD` / `PGPROD_ASS_<HEX>`.
  - staging — ONE instance holding every database. One base DSN, `PGSTG_DSN`, whose dbname this
              server swaps per target — 17 near-identical lines in a .env would be noise, and a
              file nobody may read is a bad place for noise. WHICH dbnames is deployment-specific,
              so it is configured too (`PGSTG_DB_MAD` / `PGSTG_DB_ASS_FMT`, defaulting to `mad` /
              `shard_<hex>`); see scripts/lib/pg_staging.py.

Safety is layered, because a production database behind an AI tool is a real risk:
  1. Production is gated by policy, checked in-process before any DSN lookup or connection
     (`scripts/lib/triage_policy.py` → `triage.prod`, local-first). Credentials being present is
     not permission; staging needs no opt-in.
  2. Every DSN — staging included — MUST use a read-only DB role. That is the actual guarantee.
  3. Every connection is opened with `default_transaction_read_only=on`, a 15s
     `statement_timeout`, and an idle-transaction timeout — a backstop that makes the DB itself
     reject any write (including writable CTEs) with a clear error.
  4. `execute_sql` only accepts SELECT / WITH / TABLE / VALUES, a single statement, and paginates
     results at 200 rows/page so a fat table can't flood the context.
  5. PII provenance is PROD-ONLY. Rows a prod target returns are fed to the vault
     (`scripts/lib/pii_provenance.py`) as keyed hashes — never values — which is what makes the
     egress redaction in the tracker / notify adapters prod-specific: they mask a personal value
     if and only if production is where it came from. Staging rows are never vaulted, so
     identical-looking staging or local data flows untouched. Every result says which happened
     (`env` + `pii_vaulted`). See docs/agents/pii-provenance.md and docs/adr/0005.

Pools are lazy (min_size=0): the process holds zero connections until a tool is actually called,
and `disconnect()` drops every pool so nothing lingers after a triage job — the "down the MCP
when done" teardown, without needing to kill the Claude-managed process.

  uv run scripts/db/pg_triage_mcp.py --selftest          # deps + config + policy, no DB access
  uv run scripts/db/pg_triage_mcp.py --verify staging     # live read-only acceptance run
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP
from psycopg.conninfo import make_conninfo
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

# Value-exact PII provenance (scripts/lib/pii_provenance.py) and the production policy gate
# (scripts/lib/triage_policy.py). Provenance is a safety net that must not break triage if it is
# missing; the policy gate is load-bearing, so an import failure there is fatal rather than
# silently permissive.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import pg_staging  # noqa: E402  — the staging dbname mapping, shared with prod_repro_seed.py
import triage_policy  # noqa: E402

try:
    import pii_provenance  # noqa: E402
except Exception:  # provenance is a safety net; a missing module must not break triage
    pii_provenance = None  # type: ignore[assignment]

# --- configuration -----------------------------------------------------------------------

ENV_PATH = Path(__file__).parent / ".env"
load_dotenv(ENV_PATH)  # no-op if the file is absent; targets simply report "unconfigured"

STATEMENT_TIMEOUT_MS = 15_000
IDLE_TX_TIMEOUT_MS = 30_000
MAX_PAGE_SIZE = 200
DEFAULT_PAGE_SIZE = 200
POOL_MAX_SIZE = 4
POOL_MAX_IDLE_S = 60

HEX = "0123456789abcdef"

ENV_PROD = "prod"
ENV_STAGING = "staging"
ENVS = (ENV_STAGING, ENV_PROD)

STAGING_DSN_VAR = "PGSTG_DSN"  # one base DSN; this server swaps the dbname per target

# libpq connection options — enforce read-only + timeouts at the server level, as a backstop
# on top of the read-only DB role the DSNs are required to use.
CONN_OPTIONS = (
    f"-c default_transaction_read_only=on "
    f"-c statement_timeout={STATEMENT_TIMEOUT_MS} "
    f"-c idle_in_transaction_session_timeout={IDLE_TX_TIMEOUT_MS}"
)

_pools: dict[str, ConnectionPool] = {}

mcp = FastMCP("pg-triage")

# --- env + target resolution -------------------------------------------------------------


def _resolve_env(env: str | None) -> str:
    """Canonicalize the environment. There is NO default: an unnamed env is an error, never a
    guess, so prod is only ever reached by asking for it explicitly."""
    if not env:
        raise ValueError("provide `env`: 'staging' or 'prod' (no default — prod is never implied)")
    e = env.strip().lower()
    if e not in ENVS:
        raise ValueError(f"unknown env {env!r}; use {' | '.join(ENVS)}")
    return e


def _target_key(target: str | None = None, agency_id: str | None = None) -> str:
    """Canonicalize a request to a target key: 'mad' or 'ass_<hex>'.

    Exactly one of `target` / `agency_id` is expected. `agency_id` resolves to a shard by
    its first character (the shard hex); MAD is never resolved this way — it must be asked
    for explicitly, so player-shard traffic can't accidentally land on the master.
    """
    if agency_id:
        first = agency_id.strip()[:1].lower()
        if first not in HEX:
            raise ValueError(
                f"agency_id {agency_id!r} does not start with a shard hex 0-f (got {first!r})"
            )
        return f"ass_{first}"
    if not target:
        raise ValueError("provide either `target` ('mad' | shard hex 0-f) or `agency_id`")
    t = target.strip().lower()
    if t == "mad":
        return "mad"
    if len(t) == 1 and t in HEX:
        return f"ass_{t}"
    if len(t) == 5 and t.startswith("ass_") and t[4] in HEX:
        return t
    raise ValueError(f"invalid target {target!r}; use 'mad' or a shard hex 0-f")


def _prod_env_var(key: str) -> str:
    if key == "mad":
        return "PGPROD_MAD"
    return f"PGPROD_ASS_{key[4:].upper()}"  # ass_a -> PGPROD_ASS_A


def _staging_dbname(key: str) -> str:
    """The database a target lives in on the single staging instance. Deployment-specific, so it
    is configured (`PGSTG_DB_MAD` / `PGSTG_DB_ASS_FMT`) rather than compiled in — see
    scripts/lib/pg_staging.py, which prod_repro_seed.py reads too so the two cannot disagree."""
    return pg_staging.dbname(key)


def _configured(env: str, key: str) -> bool:
    """Whether a target has credentials on this machine. Booleans only — never a DSN."""
    if env == ENV_PROD:
        return bool(os.environ.get(_prod_env_var(key)))
    return bool(os.environ.get(STAGING_DSN_VAR))


def _dsn(env: str, key: str) -> str:
    if env == ENV_PROD:
        var = _prod_env_var(key)
        dsn = os.environ.get(var)
        if not dsn:
            raise ValueError(
                f"prod target {key!r} has no DSN — set {var} in scripts/db/.env (read-only account)"
            )
        return dsn
    base = os.environ.get(STAGING_DSN_VAR)
    if not base:
        raise ValueError(
            f"staging has no DSN — set {STAGING_DSN_VAR} in scripts/db/.env (read-only account). "
            "One base DSN covers every staging database; this server swaps the dbname per target."
        )
    # Staging is one instance, one database per target: keep the base DSN's host/user/params and
    # replace only the dbname. make_conninfo accepts both URL and keyword DSN forms.
    return make_conninfo(base, dbname=_staging_dbname(key))


def _pool_key(env: str, key: str) -> str:
    return f"{env}:{key}"


def _pool(env: str, key: str) -> ConnectionPool:
    """Lazily open a pool for one env+target. min_size=0 means no connection is opened until the
    first real use, so a running-but-idle process holds nothing.

    This is the one place a connection comes into existence, which makes it the right place for
    the production gate: it fires before the DSN is even looked up."""
    pk = _pool_key(env, key)
    if pk in _pools:
        return _pools[pk]
    if env == ENV_PROD:
        triage_policy.assert_prod_allowed("PRODUCTION Postgres triage")
    pool = ConnectionPool(
        conninfo=_dsn(env, key),
        min_size=0,
        max_size=POOL_MAX_SIZE,
        max_idle=POOL_MAX_IDLE_S,
        kwargs={"autocommit": True, "options": CONN_OPTIONS},
        open=True,
        name=pk,
    )
    _pools[pk] = pool
    return pool


# --- read-only SQL guard -----------------------------------------------------------------

_ALLOWED_START = re.compile(r"^(select|with|table|values)\b", re.IGNORECASE)


def _strip_sql(sql: str) -> str:
    s = re.sub(r"/\*.*?\*/", " ", sql, flags=re.DOTALL)  # block comments
    s = re.sub(r"--[^\n]*", " ", s)  # line comments
    return s.strip()


def _assert_read_only(sql: str) -> str:
    """Return the cleaned single-statement body, or raise if it isn't a read query.

    This is convenience, not the guarantee: the read-only DB role + read-only transaction
    reject anything that slips past (e.g. a writable `WITH ... DELETE`). But catching the
    common cases here gives a clearer error than a Postgres exception mid-run.
    """
    s = _strip_sql(sql)
    if not s:
        raise ValueError("empty SQL")
    body = s.rstrip(";").strip()
    if ";" in body:
        raise ValueError("only one statement per call; run a single read-only query")
    if not _ALLOWED_START.match(body):
        first = (body.split(None, 1)[0] if body.split() else body)[:20]
        raise ValueError(
            f"read-only queries only (SELECT/WITH/TABLE/VALUES); got {first!r}. "
            "Use explain_query for EXPLAIN."
        )
    return body


# --- helpers -----------------------------------------------------------------------------


def _jsonable(payload: dict) -> dict:
    """Coerce non-JSON values (datetime, Decimal, UUID, ...) to strings so FastMCP can
    serialize the structured result."""
    return json.loads(json.dumps(payload, default=str))


def _vaults(env: str) -> bool:
    """Whether values from this env are fingerprinted for egress redaction. Prod only."""
    return env == ENV_PROD and pii_provenance is not None


def _result(env: str, key: str, payload: dict) -> dict:
    """Stamp every result with the two facts a reader must not have to remember: which
    environment answered, and whether those values will be redacted at egress."""
    return _jsonable({"env": env, "target": key, "pii_vaulted": _vaults(env), **payload})


def _query(
    env: str, key: str, sql: str, params: tuple | None = None
) -> tuple[list[str], list[dict]]:
    """The single choke point for every read — which makes it the single place that has to
    record provenance. Recording is best-effort, prod-only, and never observable to the
    caller."""
    pool = _pool(env, key)
    with pool.connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(sql, params)
            cols = [d.name for d in cur.description] if cur.description else []
            rows = cur.fetchall() if cur.description else []
    if _vaults(env) and rows:
        try:
            pii_provenance.record_rows(cols, rows)
        except Exception:
            pass
    return cols, rows


# --- tools -------------------------------------------------------------------------------


@mcp.tool()
def list_targets() -> dict:
    """List every target in BOTH environments and whether it's configured / connected, plus
    whether production is enabled on this machine.

    Touches no database — it reads which DSN env vars are present (booleans only, never a DSN)
    and the local pool state. Use it to sanity-check setup before querying, and to see what
    `disconnect` would close."""
    prod_allowed, policy_source = triage_policy.resolve("prod")
    envs = {}
    for env in ENVS:
        envs[env] = [
            {
                "target": "mad" if key == "mad" else key[4:],
                "key": key,
                "configured": _configured(env, key),
                "pool_open": _pool_key(env, key) in _pools,
                **(
                    {"database": _staging_dbname(key)}
                    if env == ENV_STAGING
                    else {"env_var": _prod_env_var(key)}
                ),
            }
            for key in ["mad"] + [f"ass_{h}" for h in HEX]
        ]
    return _jsonable(
        {
            "envs": envs,
            "prod_allowed": prod_allowed,
            "policy": f"triage.prod = {str(prod_allowed).lower()} ({policy_source})",
            "staging_dsn_var": STAGING_DSN_VAR,
            "pii_vaulted": {ENV_PROD: _vaults(ENV_PROD), ENV_STAGING: False},
            "open_pools": list(_pools),
        }
    )


@mcp.tool()
def resolve_shard(agency_id: str, env: str | None = None) -> dict:
    """Show which shard an agency_id maps to (shard = first char of agency_id). Pure lookup, no
    DB access, identical in both environments — `env` only selects which credential / database
    name to report, and may be omitted to see both."""
    key = _target_key(agency_id=agency_id)
    out: dict = {"agency_id": agency_id, "shard": key[4:], "target_key": key}
    for e in [_resolve_env(env)] if env else list(ENVS):
        out[e] = (
            {"database": _staging_dbname(key)}
            if e == ENV_STAGING
            else {"env_var": _prod_env_var(key)}
        )
    return out


@mcp.tool()
def list_schemas(
    env: str | None = None, target: str | None = None, agency_id: str | None = None
) -> dict:
    """List user schemas on a target (excludes pg_* and information_schema).
    Provide `env` ('staging' | 'prod') plus `target` ('mad' | shard hex 0-f) or `agency_id`."""
    e = _resolve_env(env)
    key = _target_key(target, agency_id)
    _, rows = _query(
        e,
        key,
        "SELECT schema_name FROM information_schema.schemata "
        "WHERE schema_name NOT LIKE 'pg\\_%' AND schema_name <> 'information_schema' "
        "ORDER BY 1",
    )
    return _result(e, key, {"schemas": [r["schema_name"] for r in rows]})


@mcp.tool()
def list_objects(
    env: str | None = None,
    target: str | None = None,
    agency_id: str | None = None,
    schema: str = "public",
    object_type: str | None = None,
) -> dict:
    """List tables/views in a schema on a target. `object_type` optionally filters to
    'table' or 'view'. Provide `env` plus `target` or `agency_id`."""
    e = _resolve_env(env)
    key = _target_key(target, agency_id)
    sql = (
        "SELECT table_schema, table_name, table_type FROM information_schema.tables "
        "WHERE table_schema = %s"
    )
    params: tuple = (schema,)
    if object_type:
        mapping = {"table": "BASE TABLE", "view": "VIEW"}
        sql += " AND table_type = %s"
        params = (schema, mapping.get(object_type.lower(), object_type.upper()))
    sql += " ORDER BY 1, 2"
    _, rows = _query(e, key, sql, params)
    return _result(e, key, {"schema": schema, "objects": rows})


@mcp.tool()
def get_object_details(
    name: str,
    env: str | None = None,
    target: str | None = None,
    agency_id: str | None = None,
    schema: str = "public",
) -> dict:
    """Describe a table/view: its columns (name, type, nullability, default) and indexes.
    Provide `env` plus `target` or `agency_id`."""
    e = _resolve_env(env)
    key = _target_key(target, agency_id)
    _, columns = _query(
        e,
        key,
        "SELECT column_name, data_type, is_nullable, column_default, ordinal_position "
        "FROM information_schema.columns WHERE table_schema = %s AND table_name = %s "
        "ORDER BY ordinal_position",
        (schema, name),
    )
    _, indexes = _query(
        e,
        key,
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = %s AND tablename = %s "
        "ORDER BY indexname",
        (schema, name),
    )
    return _result(
        e, key, {"schema": schema, "name": name, "columns": columns, "indexes": indexes}
    )


@mcp.tool()
def explain_query(
    sql: str,
    env: str | None = None,
    target: str | None = None,
    agency_id: str | None = None,
    analyze: bool = False,
) -> dict:
    """Return the query plan for a read-only query. `analyze=False` (default) plans without
    running it; `analyze=True` runs EXPLAIN (ANALYZE, BUFFERS) — note that actually EXECUTES
    the query against the target, so leave it off unless you need real timings. Provide `env`
    plus `target` or `agency_id`."""
    e = _resolve_env(env)
    key = _target_key(target, agency_id)
    body = _assert_read_only(sql)
    prefix = (
        "EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT) "
        if analyze
        else "EXPLAIN (VERBOSE, FORMAT TEXT) "
    )
    cols, rows = _query(e, key, prefix + body)
    plan_col = cols[0] if cols else "QUERY PLAN"
    return _result(e, key, {"analyzed": analyze, "plan": [r[plan_col] for r in rows]})


@mcp.tool()
def execute_sql(
    sql: str,
    env: str | None = None,
    target: str | None = None,
    agency_id: str | None = None,
    page: int = 1,
    page_size: int = DEFAULT_PAGE_SIZE,
) -> dict:
    """Run a READ-ONLY query against one target, paginated.

    Provide `env` ('staging' | 'prod' — required, never defaulted) and exactly one of `target`
    ('mad' | shard hex 0-f) or `agency_id` (shard = first char). Only SELECT/WITH/TABLE/VALUES,
    one statement. Results are paged at `page_size` (max 200) rows; `page` is 1-based. Include
    an ORDER BY so pages are stable — OFFSET paging over an unordered query can repeat or skip
    rows between pages. `has_more` tells you whether to fetch the next page.

    `pii_vaulted` in the result says whether these values are fingerprinted for egress
    redaction: true for prod, false for staging (staging is not the prod boundary).
    """
    e = _resolve_env(env)
    key = _target_key(target, agency_id)
    body = _assert_read_only(sql)
    page = max(1, int(page))
    page_size = max(1, min(int(page_size), MAX_PAGE_SIZE))
    wrapped = f"SELECT * FROM (\n{body}\n) AS _q LIMIT %s OFFSET %s"
    cols, rows = _query(e, key, wrapped, (page_size + 1, (page - 1) * page_size))
    has_more = len(rows) > page_size
    rows = rows[:page_size]
    return _result(
        e,
        key,
        {
            "page": page,
            "page_size": page_size,
            "row_count": len(rows),
            "has_more": has_more,
            "columns": cols,
            "rows": rows,
        },
    )


@mcp.tool()
def disconnect(env: str | None = None) -> dict:
    """Close open connection pools — the teardown for a triage job. Closes BOTH environments by
    default; pass `env` to close just one. Always call this when the investigation is done — it
    leaves zero open connections; the MCP process stays up but idle."""
    only = _resolve_env(env) if env else None
    closed = []
    for pk, pool in list(_pools.items()):
        if only and not pk.startswith(f"{only}:"):
            continue
        try:
            pool.close()
        finally:
            closed.append(pk)
            _pools.pop(pk, None)
    return {"closed": closed, "open_pools": list(_pools)}


# --- entrypoint --------------------------------------------------------------------------


def _selftest() -> int:
    """Validate deps + config + policy without connecting to anything. Prints only booleans
    (which targets are configured) — never a DSN value, honoring the workspace .env guard."""
    print(f"env file: {ENV_PATH} ({'present' if ENV_PATH.exists() else 'MISSING'})")
    print(f"pii provenance: {'wired' if pii_provenance is not None else 'UNAVAILABLE'}")
    for key in ("enabled", "prod"):
        value, source = triage_policy.resolve(key)
        print(f"triage.{key:<8} = {str(value).lower():<5} ({source})")
    dead = triage_policy.dead_key_present()
    if dead:
        print(f"  ! {dead} still sets the REMOVED key `prod_triage.enabled` — ignored; use triage.prod")
    print(
        f"staging: {STAGING_DSN_VAR} {'set' if os.environ.get(STAGING_DSN_VAR) else 'unset'}"
        f"  -> {pg_staging.describe()}"
    )
    print("prod:")
    for key in ["mad"] + [f"ass_{h}" for h in HEX]:
        var = _prod_env_var(key)
        print(f"  {var:<16} {'set' if os.environ.get(var) else 'unset'}")
    print("selftest ok")
    return 0


def _verify(env: str, target: str = "mad") -> int:
    """Live, read-only acceptance run against one environment: cheap reads, the PII-provenance
    behaviour for that env, the production gate, and teardown. It drives the SERVER's own tool
    functions, so it exercises the same code paths the MCP tools do.

    The PII assertions use a THROWAWAY vault directory, so a verify run never writes
    fingerprints into the real vault and never depends on what is already in it."""
    import shutil
    import tempfile

    failures = 0

    def check(label: str, cond: bool, detail: str = "") -> None:
        nonlocal failures
        if not cond:
            failures += 1
        print(f"  {'ok  ' if cond else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")

    e = _resolve_env(env)
    prod_allowed, policy_source = triage_policy.resolve("prod")
    print(f"verify env={e} target={target}")
    print(f"  triage.prod = {str(prod_allowed).lower()} ({policy_source})")
    if e == ENV_PROD and not prod_allowed:
        print("  FAIL production is not enabled on this machine — set triage.prod: true first")
        return 1
    if not _configured(e, _target_key(target)):
        var = STAGING_DSN_VAR if e == ENV_STAGING else _prod_env_var(_target_key(target))
        print(f"  FAIL {e} target {target!r} is unconfigured — set {var} in scripts/db/.env")
        return 1

    vault_tmp = Path(tempfile.mkdtemp(prefix="pg-triage-verify-vault-"))
    prev_vault = os.environ.get("PII_VAULT_DIR")
    os.environ["PII_VAULT_DIR"] = str(vault_tmp)
    try:
        # 1) metadata read — proves the DSN, the role, and the connection options work
        schemas = list_schemas(env=e, target=target)
        check(
            "list_schemas returns schemas",
            bool(schemas["schemas"]),
            ", ".join(schemas["schemas"][:5]),
        )
        check(
            "result is stamped with env + pii_vaulted",
            schemas["env"] == e and schemas["pii_vaulted"] is (e == ENV_PROD),
            f"env={schemas['env']} pii_vaulted={schemas['pii_vaulted']}",
        )

        # 2) a real query through the pagination wrapper
        one = execute_sql(sql="SELECT 1 AS one", env=e, target=target)
        check("execute_sql runs a read query", one["row_count"] == 1 and not one["has_more"])

        # 3) plan-only EXPLAIN (never executes)
        plan = explain_query(sql="SELECT 1", env=e, target=target)
        check("explain_query returns a plan", bool(plan["plan"]) and plan["analyzed"] is False)

        # 4) client-side read-only guard
        for bad, why in (
            ("UPDATE player SET turnover = 0", "write statement"),
            ("SELECT 1; SELECT 2", "two statements"),
        ):
            try:
                execute_sql(sql=bad, env=e, target=target)
                check(f"read-only guard rejects a {why}", False)
            except ValueError:
                check(f"read-only guard rejects a {why}", True)

        # 5) DB-LEVEL read-only proof — bypass the client guard on purpose and let the server
        # reject it, which is what protects against a careless future edit inside a tool.
        try:
            _query(e, _target_key(target), "CREATE TEMP TABLE _pg_triage_verify (i int)")
            check("DB rejects a write (read-only transaction)", False, "the write SUCCEEDED")
        except Exception as exc:  # psycopg.errors.ReadOnlySqlTransaction, normally
            check(
                "DB rejects a write (read-only transaction)",
                "read-only" in str(exc).lower(),
                str(exc).splitlines()[0][:80],
            )

        # 6) PII provenance, per env — a synthetic literal, never real data
        before = len(pii_provenance._load_vault()) if pii_provenance else 0
        pii = execute_sql(sql="SELECT 'somchai@gmail.com'::text AS email", env=e, target=target)
        after = len(pii_provenance._load_vault()) if pii_provenance else 0
        if e == ENV_STAGING:
            check(
                "staging value is NOT vaulted",
                after == before and pii["pii_vaulted"] is False,
                f"vault {before} -> {after}",
            )
        else:
            check(
                "prod value IS vaulted",
                after > before and pii["pii_vaulted"] is True,
                f"vault {before} -> {after}",
            )

        # 7) the production gate, exercised from the staging run when prod is off
        if not prod_allowed:
            try:
                execute_sql(sql="SELECT 1", env=ENV_PROD, target="mad")
                check("prod is refused while triage.prod is off", False, "the call SUCCEEDED")
            except PermissionError as exc:
                check("prod is refused while triage.prod is off", "triage.prod" in str(exc))
        else:
            print("  skip prod-gate check — triage.prod is on, so prod is legitimately reachable")

        # 8) teardown
        closed = disconnect()
        check(
            "disconnect leaves zero open pools",
            not closed["open_pools"],
            f"closed {closed['closed']}",
        )
    finally:
        if prev_vault is None:
            os.environ.pop("PII_VAULT_DIR", None)
        else:
            os.environ["PII_VAULT_DIR"] = prev_vault
        shutil.rmtree(vault_tmp, ignore_errors=True)
        disconnect()

    print("verify ok" if not failures else f"{failures} check(s) FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    if "--verify" in sys.argv:
        rest = sys.argv[sys.argv.index("--verify") + 1 :]
        env_arg = rest[0] if rest and not rest[0].startswith("-") else ""
        if not env_arg:
            raise SystemExit(
                f"usage: --verify <{' | '.join(ENVS)}> [--target mad|<hex>]  "
                "(the env is required — prod is never implied)"
            )
        target_arg = "mad"
        if "--target" in sys.argv:
            idx = sys.argv.index("--target") + 1
            target_arg = sys.argv[idx] if idx < len(sys.argv) else "mad"
        raise SystemExit(_verify(env_arg, target_arg))
    mcp.run()  # stdio transport
