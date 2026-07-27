"""pg_staging — how a triage target maps to a database name on the STAGING Postgres instance.

Staging is ONE instance holding every database, so a target is just a dbname on the single
`PGSTG_DSN` base connection. Which dbnames those are is deployment-specific — one org runs
`mad` + `shard_0…f`, another `master` + `players_a…`, another a single database for everything —
so the mapping is CONFIGURED, not compiled in:

    PGSTG_DSN          the base DSN (host/user/params). Its dbname is irrelevant and replaced.
    PGSTG_DB_MAD       database for target="mad"                        (default `mad`)
    PGSTG_DB_ASS_FMT   database for a shard, with `%s` = the shard hex  (default `shard_%s`)

Examples:

    PGSTG_DB_MAD=master        PGSTG_DB_ASS_FMT=players_%s   -> master, players_a
    PGSTG_DB_MAD=ofb_staging   PGSTG_DB_ASS_FMT=ofb_staging  -> one database for every target
                                                                (no `%s` = no substitution)

It lives in `scripts/lib/` because two tools must agree on it exactly: the read-only triage MCP
(`scripts/db/pg_triage_mcp.py`) and the repro seeder (`scripts/db/prod_repro_seed.py`). Two copies
of this mapping would mean the seeder pulling from a different database than the one triage read.

`%s` is substituted by plain string replacement, not `%`-formatting, so a dbname containing a
stray `%` cannot raise mid-triage.

  python3 scripts/lib/pg_staging.py            # the mapping as the CURRENT SHELL env resolves it
  python3 scripts/lib/pg_staging.py --selftest # mapping cases, no DB access

The standalone view above reads the process environment only — it does NOT load
`scripts/db/.env` (that file is the servers' to read). To see the mapping the servers will
actually use, run `uv run scripts/db/pg_triage_mcp.py --selftest`.
"""

from __future__ import annotations

import os
import sys

DSN_VAR = "PGSTG_DSN"
DB_MAD_VAR = "PGSTG_DB_MAD"
DB_ASS_FMT_VAR = "PGSTG_DB_ASS_FMT"

DEFAULT_DB_MAD = "mad"
DEFAULT_DB_ASS_FMT = "shard_%s"

SHARD_TOKEN = "%s"
HEX = "0123456789abcdef"


def db_mad() -> tuple[str, bool]:
    """(database for MAD, came_from_env)."""
    v = os.environ.get(DB_MAD_VAR)
    return (v, True) if v else (DEFAULT_DB_MAD, False)


def db_ass_fmt() -> tuple[str, bool]:
    """(shard database pattern, came_from_env)."""
    v = os.environ.get(DB_ASS_FMT_VAR)
    return (v, True) if v else (DEFAULT_DB_ASS_FMT, False)


def dbname(key: str) -> str:
    """The staging database for a target key ('mad' | 'ass_<hex>' | a bare hex)."""
    if key == "mad":
        return db_mad()[0]
    shard = key[4:] if key.startswith("ass_") else key
    return db_ass_fmt()[0].replace(SHARD_TOKEN, shard)


def describe() -> str:
    """One line naming the resolved mapping and where each half came from — for selftests."""
    mad, mad_env = db_mad()
    fmt, fmt_env = db_ass_fmt()
    return (
        f"mad -> {mad} ({'env' if mad_env else 'default'}), "
        f"shard h -> {fmt.replace(SHARD_TOKEN, 'h')} ({'env' if fmt_env else 'default'})"
    )


def _selftest() -> int:
    failures = 0

    def check(label: str, cond: bool, detail: str = "") -> None:
        nonlocal failures
        if not cond:
            failures += 1
        print(f"  {'ok  ' if cond else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")

    saved = {k: os.environ.pop(k, None) for k in (DB_MAD_VAR, DB_ASS_FMT_VAR)}
    try:
        check("default mad", dbname("mad") == "mad", dbname("mad"))
        check("default shard", dbname("ass_a") == "shard_a", dbname("ass_a"))
        check("bare hex accepted", dbname("f") == "shard_f", dbname("f"))

        os.environ[DB_MAD_VAR] = "master"
        os.environ[DB_ASS_FMT_VAR] = "players_%s"
        check("env override mad", dbname("mad") == "master", dbname("mad"))
        check("env override shard", dbname("ass_3") == "players_3", dbname("ass_3"))

        os.environ[DB_MAD_VAR] = "ofb_staging"
        os.environ[DB_ASS_FMT_VAR] = "ofb_staging"  # no %s: one database for every target
        check(
            "pattern without %s maps every target to one database",
            dbname("mad") == dbname("ass_b") == "ofb_staging",
        )

        os.environ[DB_ASS_FMT_VAR] = "odd%name_%s"  # a stray % must not raise
        check("stray % in the pattern is literal", dbname("ass_c") == "odd%name_c", dbname("ass_c"))

        os.environ[DB_ASS_FMT_VAR] = "shard_%s"
        check("every hex maps to a distinct database",
              len({dbname(f"ass_{h}") for h in HEX}) == len(HEX))
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    print("selftest ok" if not failures else f"{failures} check(s) FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    print(f"{DSN_VAR}: {'set' if os.environ.get(DSN_VAR) else 'unset'}")
    print(f"mapping: {describe()}")
    raise SystemExit(0)
