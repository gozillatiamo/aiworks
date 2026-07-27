"""pg_staging — how a triage target resolves to a DSN on the STAGING Postgres.

Production targets are one DSN each (`PGPROD_<NAME>`), because a production fleet is usually
several hosts. Staging is commonly the opposite: ONE instance holding a database per target. Both
shapes are supported, checked in this order:

    PGSTG_<NAME>       a full DSN for that target — always wins, for a staging split across hosts
    PGSTG_DSN          a base DSN for the whole instance; this module swaps in the dbname
    PGSTG_DB_<NAME>    the database that target lives in on that base DSN (default: the target name)

So a staging that mirrors prod host-for-host declares `PGSTG_MAIN`, `PGSTG_SECONDARY`, …; a staging
that is one instance with many databases declares `PGSTG_DSN` once and, only where the database is
not simply the target name, a `PGSTG_DB_<NAME>` line. Neither shape is compiled in.

    PGSTG_DSN=postgresql://ro:pw@stg:5432/postgres?sslmode=require
    # target="main"    -> database `main`
    # target="shard0"  -> database `shard0`
    PGSTG_DB_SHARD0=shard_0        # ...unless you say otherwise

It lives in `scripts/lib/` because two tools must agree on it exactly: the read-only triage MCP
(`scripts/db/pg_triage_mcp.py`) and the repro seeder (`scripts/db/prod_repro_seed.py`). Two copies
would mean the seeder pulling from a different database than the one triage read.

  python3 scripts/lib/pg_staging.py            # the mapping as the CURRENT SHELL env resolves it
  uv run --with "psycopg[binary]" python scripts/lib/pg_staging.py --selftest   # resolution cases,
                                               # no DB access (psycopg supplies make_conninfo)

The standalone view reads the process environment only — it does NOT load `scripts/db/.env` (that
file is the servers' to read). For the mapping the servers will use, run
`uv run scripts/db/pg_triage_mcp.py --selftest`.
"""

from __future__ import annotations

import os
import re
import sys

DSN_VAR = "PGSTG_DSN"  # base DSN for a single staging instance
TARGET_PREFIX = "PGSTG_"  # per-target DSN: PGSTG_<NAME>
DB_PREFIX = "PGSTG_DB_"  # database for a target on the base DSN: PGSTG_DB_<NAME>

# `PGSTG_DSN` and `PGSTG_DB_*` share the target prefix, so they must never be read as targets
# named "dsn" / "db_…". A target you actually want to call "dsn" is the one name this scheme
# cannot express — call it something else.
RESERVED = {DSN_VAR}


def _suffix(name: str) -> str:
    return re.sub(r"[^A-Z0-9]+", "_", name.strip().upper())


def target_var(name: str) -> str:
    """Env var holding a full DSN for one staging target: 'main' -> PGSTG_MAIN."""
    return TARGET_PREFIX + _suffix(name)


def db_var(name: str) -> str:
    """Env var holding the database name for one target on the base DSN."""
    return DB_PREFIX + _suffix(name)


def dbname(name: str) -> str:
    """The staging database for a target — the configured override, else the target name."""
    return os.environ.get(db_var(name)) or name.strip().lower()


def base_dsn() -> str | None:
    return os.environ.get(DSN_VAR) or None


def configured(name: str) -> bool:
    """Whether this machine can reach that staging target at all (booleans only, never a DSN)."""
    return bool(os.environ.get(target_var(name)) or base_dsn())


def configured_targets() -> list[str]:
    """Staging target names this machine declares EXPLICITLY — every `PGSTG_<NAME>` DSN plus every
    `PGSTG_DB_<NAME>` mapping. With only a base DSN set, any target name resolves, so the list is
    what was named, not what is reachable."""
    names = set()
    for k, v in os.environ.items():
        if not v or k in RESERVED:
            continue
        if k.startswith(DB_PREFIX):
            names.add(k[len(DB_PREFIX):].lower())
        elif k.startswith(TARGET_PREFIX):
            names.add(k[len(TARGET_PREFIX):].lower())
    return sorted(names)


def dsn(name: str) -> str:
    """The read-only DSN for one staging target. Raises with the variable to set when neither a
    per-target DSN nor a base DSN is configured."""
    key = name.strip().lower()
    explicit = os.environ.get(target_var(key))
    if explicit:
        return explicit
    base = base_dsn()
    if not base:
        raise ValueError(
            f"staging target {key!r} has no DSN — set {target_var(key)}, or set {DSN_VAR} once "
            f"(one instance, one database per target; override the database with {db_var(key)}). "
            "Use a read-only account, same rule as prod."
        )
    # make_conninfo rather than string surgery: it accepts both the URL and keyword DSN forms, and
    # the base DSN is written by hand into a file nobody may read back to check.
    from psycopg.conninfo import make_conninfo

    return make_conninfo(base, dbname=dbname(key))


def describe(name: str = "") -> str:
    """One line describing how staging resolves — for selftest output."""
    base = "set" if base_dsn() else "unset"
    named = configured_targets()
    out = f"{DSN_VAR} {base}; named targets: {', '.join(named) if named else 'none'}"
    if name:
        via = target_var(name) if os.environ.get(target_var(name)) else f"{DSN_VAR} + db {dbname(name)}"
        out += f"; {name} -> {via}"
    return out


def _selftest() -> int:
    failures = 0

    def check(label: str, cond: bool, detail: str = "") -> None:
        nonlocal failures
        if not cond:
            failures += 1
        print(f"  {'ok  ' if cond else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")

    saved = {k: v for k, v in os.environ.items() if k.startswith(TARGET_PREFIX)}
    for k in saved:
        os.environ.pop(k, None)
    try:
        check("nothing configured -> not reachable", not configured("main"))
        try:
            dsn("main")
            check("unconfigured target raises", False)
        except ValueError as exc:
            check("unconfigured target raises", "PGSTG_MAIN" in str(exc) and DSN_VAR in str(exc))

        os.environ[DSN_VAR] = "postgresql://ro:pw@stg:5432/postgres"
        check("base DSN makes any target reachable", configured("main") and configured("shard0"))
        check("dbname defaults to the target name", dbname("shard0") == "shard0", dbname("shard0"))
        check("base DSN keeps host, swaps dbname",
              "host=stg" in dsn("main") and "dbname=main" in dsn("main"), dsn("main"))

        os.environ[DB_PREFIX + "SHARD0"] = "shard_0"
        check("PGSTG_DB_<NAME> overrides the database", dbname("shard0") == "shard_0")
        check("override reaches the DSN", "dbname=shard_0" in dsn("shard0"), dsn("shard0"))

        os.environ[TARGET_PREFIX + "MAIN"] = "postgresql://ro:pw@other:5432/whatever"
        check("per-target DSN wins over the base", dsn("main").startswith("postgresql://ro:pw@other"))

        check("named targets are listed", configured_targets() == ["main", "shard0"],
              str(configured_targets()))
        os.environ.pop(DSN_VAR)
        check("a named target works with no base DSN", dsn("main").endswith("/whatever"))
        try:
            dsn("shard0")  # only a DB-name mapping, no DSN anywhere
            check("a db-name mapping alone is not a DSN", False)
        except ValueError:
            check("a db-name mapping alone is not a DSN", True)
    finally:
        for k in [k for k in os.environ if k.startswith(TARGET_PREFIX)]:
            os.environ.pop(k, None)
        os.environ.update(saved)

    print("selftest ok" if not failures else f"{failures} check(s) FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    print(describe())
    raise SystemExit(0)
