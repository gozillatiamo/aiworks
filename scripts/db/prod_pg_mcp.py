# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "mcp>=1.2",
#   "psycopg[binary]>=3.1",
#   "psycopg-pool>=3.2",
#   "python-dotenv>=1.0",
# ]
# ///
"""prod-pg-triage — on-demand, READ-ONLY MCP wrapper over the OFB PRODUCTION Postgres.

One MCP process, many targets. Which database a tool touches is chosen *per call* by a
`target` argument (never baked into the process), so a single server covers the whole prod
fleet:

  - MAD  — the master DB. Reachable only by explicit `target="mad"`; never auto-resolved.
  - ASS  — 16 player shards addressed by hex 0-f (topology: 1 host holds 2 shards, so the
           16 shards live across ASS1-8; the host lives in each shard's DSN, not here).

Targets resolve to read-only DSNs loaded from `scripts/db/.env` *by this process* — the
credentials never pass through Claude, the MCP config, or the transcript. Callers pass a
`target` or an `agency_id` (the shard is the first character of the agency id); the DSN
lookup and connection stay inside the server.

Safety is layered, because a production database behind an AI tool is a real risk:
  1. The DSNs must use a read-only DB role — this is the actual guarantee.
  2. Every connection is opened with `default_transaction_read_only=on`, a 15s
     `statement_timeout`, and an idle-transaction timeout — a backstop that makes the DB
     itself reject any write (including writable CTEs) with a clear error.
  3. `execute_sql` only accepts SELECT / WITH / TABLE / VALUES, a single statement, and
     paginates results at 200 rows/page so a fat table can't flood the context.

Pools are lazy (min_size=0): the process holds zero prod connections until a tool is
actually called, and `disconnect()` drops every pool so nothing lingers after a triage job
— the "down the MCP when done" teardown, without needing to kill the Claude-managed process.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

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

# libpq connection options — enforce read-only + timeouts at the server level, as a backstop
# on top of the read-only DB role the DSNs are required to use.
CONN_OPTIONS = (
    f"-c default_transaction_read_only=on "
    f"-c statement_timeout={STATEMENT_TIMEOUT_MS} "
    f"-c idle_in_transaction_session_timeout={IDLE_TX_TIMEOUT_MS}"
)

_pools: dict[str, ConnectionPool] = {}

mcp = FastMCP("prod-pg-triage")

# --- target resolution -------------------------------------------------------------------


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


def _env_var(key: str) -> str:
    if key == "mad":
        return "PGPROD_MAD"
    return f"PGPROD_ASS_{key[4:].upper()}"  # ass_a -> PGPROD_ASS_A


def _pool(key: str) -> ConnectionPool:
    """Lazily open a pool for a target. min_size=0 means no prod connection is opened until
    the first real use, so a running-but-idle process holds nothing."""
    if key in _pools:
        return _pools[key]
    var = _env_var(key)
    dsn = os.environ.get(var)
    if not dsn:
        raise ValueError(
            f"target {key!r} has no DSN — set {var} in scripts/db/.env (read-only account)"
        )
    pool = ConnectionPool(
        conninfo=dsn,
        min_size=0,
        max_size=POOL_MAX_SIZE,
        max_idle=POOL_MAX_IDLE_S,
        kwargs={"autocommit": True, "options": CONN_OPTIONS},
        open=True,
        name=f"prod-{key}",
    )
    _pools[key] = pool
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


def _query(key: str, sql: str, params: tuple | None = None) -> tuple[list[str], list[dict]]:
    pool = _pool(key)
    with pool.connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(sql, params)
            cols = [d.name for d in cur.description] if cur.description else []
            rows = cur.fetchall() if cur.description else []
    return cols, rows


# --- tools -------------------------------------------------------------------------------


@mcp.tool()
def list_targets() -> dict:
    """List every prod target and whether it's configured / currently connected.

    Does NOT touch prod — it only reads which DSN env vars are present and the local pool
    state. Use this to sanity-check setup before querying, and to see what `disconnect`
    would close."""
    targets = []
    for key in ["mad"] + [f"ass_{h}" for h in HEX]:
        pool = _pools.get(key)
        targets.append(
            {
                "target": "mad" if key == "mad" else key[4:],
                "key": key,
                "configured": bool(os.environ.get(_env_var(key))),  # boolean only, never the DSN
                "pool_open": pool is not None,
            }
        )
    return _jsonable({"targets": targets, "open_pools": [k for k in _pools]})


@mcp.tool()
def resolve_shard(agency_id: str) -> dict:
    """Show which shard an agency_id maps to (shard = first char of agency_id). Pure lookup,
    no DB access — handy to confirm targeting before a query."""
    key = _target_key(agency_id=agency_id)
    return {"agency_id": agency_id, "shard": key[4:], "target_key": key, "env_var": _env_var(key)}


@mcp.tool()
def list_schemas(target: str | None = None, agency_id: str | None = None) -> dict:
    """List user schemas on a target (excludes pg_* and information_schema).
    Provide `target` ('mad' | shard hex 0-f) or `agency_id`."""
    key = _target_key(target, agency_id)
    cols, rows = _query(
        key,
        "SELECT schema_name FROM information_schema.schemata "
        "WHERE schema_name NOT LIKE 'pg\\_%' AND schema_name <> 'information_schema' "
        "ORDER BY 1",
    )
    return _jsonable({"target": key, "schemas": [r["schema_name"] for r in rows]})


@mcp.tool()
def list_objects(
    target: str | None = None,
    agency_id: str | None = None,
    schema: str = "public",
    object_type: str | None = None,
) -> dict:
    """List tables/views in a schema on a target. `object_type` optionally filters to
    'table' or 'view'. Provide `target` or `agency_id`."""
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
    cols, rows = _query(key, sql, params)
    return _jsonable({"target": key, "schema": schema, "objects": rows})


@mcp.tool()
def get_object_details(
    name: str,
    target: str | None = None,
    agency_id: str | None = None,
    schema: str = "public",
) -> dict:
    """Describe a table/view: its columns (name, type, nullability, default) and indexes.
    Provide `target` or `agency_id`."""
    key = _target_key(target, agency_id)
    _, columns = _query(
        key,
        "SELECT column_name, data_type, is_nullable, column_default, ordinal_position "
        "FROM information_schema.columns WHERE table_schema = %s AND table_name = %s "
        "ORDER BY ordinal_position",
        (schema, name),
    )
    _, indexes = _query(
        key,
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = %s AND tablename = %s "
        "ORDER BY indexname",
        (schema, name),
    )
    return _jsonable(
        {"target": key, "schema": schema, "name": name, "columns": columns, "indexes": indexes}
    )


@mcp.tool()
def explain_query(
    sql: str,
    target: str | None = None,
    agency_id: str | None = None,
    analyze: bool = False,
) -> dict:
    """Return the query plan for a read-only query. `analyze=False` (default) plans without
    running it; `analyze=True` runs EXPLAIN (ANALYZE, BUFFERS) — note that actually EXECUTES
    the query against prod, so leave it off unless you need real timings. Provide `target`
    or `agency_id`."""
    key = _target_key(target, agency_id)
    body = _assert_read_only(sql)
    prefix = "EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT) " if analyze else "EXPLAIN (VERBOSE, FORMAT TEXT) "
    cols, rows = _query(key, prefix + body)
    plan_col = cols[0] if cols else "QUERY PLAN"
    return _jsonable({"target": key, "analyzed": analyze, "plan": [r[plan_col] for r in rows]})


@mcp.tool()
def execute_sql(
    sql: str,
    target: str | None = None,
    agency_id: str | None = None,
    page: int = 1,
    page_size: int = DEFAULT_PAGE_SIZE,
) -> dict:
    """Run a READ-ONLY query against a prod target, paginated.

    Provide exactly one of `target` ('mad' | shard hex 0-f) or `agency_id` (shard = first
    char). Only SELECT/WITH/TABLE/VALUES, one statement. Results are paged at `page_size`
    (max 200) rows; `page` is 1-based. Include an ORDER BY so pages are stable — OFFSET
    paging over an unordered query can repeat or skip rows between pages.
    `has_more` in the result tells you whether to fetch the next page.
    """
    key = _target_key(target, agency_id)
    body = _assert_read_only(sql)
    page = max(1, int(page))
    page_size = max(1, min(int(page_size), MAX_PAGE_SIZE))
    wrapped = f"SELECT * FROM (\n{body}\n) AS _q LIMIT %s OFFSET %s"
    cols, rows = _query(key, wrapped, (page_size + 1, (page - 1) * page_size))
    has_more = len(rows) > page_size
    rows = rows[:page_size]
    return _jsonable(
        {
            "target": key,
            "page": page,
            "page_size": page_size,
            "row_count": len(rows),
            "has_more": has_more,
            "columns": cols,
            "rows": rows,
        }
    )


@mcp.tool()
def disconnect() -> dict:
    """Close every open prod connection pool — the teardown for a triage job. Leaves zero
    open prod connections; the MCP process stays up but idle. Always call this when the
    investigation is done."""
    closed = []
    for key, pool in list(_pools.items()):
        try:
            pool.close()
        finally:
            closed.append("mad" if key == "mad" else key[4:])
            _pools.pop(key, None)
    return {"closed": closed, "open_pools": list(_pools)}


# --- entrypoint --------------------------------------------------------------------------


def _selftest() -> int:
    """Validate deps + config without connecting to prod. Prints only booleans (which
    targets are configured) — never a DSN value, honoring the workspace .env guard."""
    print(f"env file: {ENV_PATH} ({'present' if ENV_PATH.exists() else 'MISSING'})")
    for key in ["mad"] + [f"ass_{h}" for h in HEX]:
        var = _env_var(key)
        print(f"  {var:<16} {'set' if os.environ.get(var) else 'unset'}")
    print("selftest ok")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    mcp.run()  # stdio transport
