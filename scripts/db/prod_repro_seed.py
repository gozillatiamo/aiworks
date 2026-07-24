# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "psycopg[binary]>=3.1",
#   "python-dotenv>=1.0",
# ]
# ///
"""prod_repro_seed — the ONE sanctioned path to move OFB production data into local repro DBs.

Purpose (decided in the prod-pg-triage allocation consult): during `/diagnosing-bugs`, a
developer sometimes needs the *actual* offending prod rows to reproduce a data bug against the
local source. Reading prod is what `prod-pg-triage` does; **persisting** any of it locally is
gated here, so the mask/isolation/teardown invariants are enforced in code, not left to memory:

  1. READ-ONLY prod  — pulled through the same read-only DSNs + read-only transaction as the
     triage MCP. This tool never writes to prod.
  2. HARD MASK on persist — every external-PII value (scripts/lib/pii-patterns.txt) and every
     PII-named column is masked BEFORE it is written locally. Inner-system identity
     (player_code/site_code/*_code, UUID), money integers and status survive (the bug needs
     them); phone/email/wallet/bank/national-id do not.
  3. THROWAWAY, ISOLATED DBs — data lands in dedicated `ofb_repro_<ticket>_<seed>` databases,
     never the shared local dev DB. `--teardown` DROPs every one for the ticket, across instances.
  4. ENTITY-SCOPED — you seed the rows reachable from the ticket's identifier, not a table
     dump; a seed above the row caps needs an explicit `--approve-large`.

OFB is split-topology: the service connects to the master (MAD) AND a player shard (ASS) at
once. So a spec has a list of `seeds`, each pulling one prod source into one throwaway DB on
one local instance — reproduce a MAD+shard bug by seeding both in a single run, then point the
service's master + shard connections at the two DBs this prints.

Normal development is untouched: this only governs prod-DERIVED data into throwaway DBs.
`execute_sql` INSERTs of synthetic/fixture data into the normal local dev DB stay free.

  seed:     prod_repro_seed.py --ticket OFB-123 --spec seed.json [--approve-large] [--dry-run]
  teardown: prod_repro_seed.py --ticket OFB-123 --teardown
  list:     prod_repro_seed.py --list
  selftest: prod_repro_seed.py --selftest      # deps/config/mask, no prod or local access

Environment (scripts/db/.env — never Read/cat/grep it, the .env guard blocks it):
  PGPROD_MAD / PGPROD_ASS_<hex>   read-only prod DSNs (shared with the triage MCP)
  PGLOCAL_MAD_ADMIN               LOCAL master instance, maintenance DB, CREATEDB/DROPDB rights
  PGLOCAL_ASS_ADMIN               LOCAL shard  instance, maintenance DB, CREATEDB/DROPDB rights
  PGLOCAL_ADMIN                   fallback used when a seed names no admin_env

Spec file (JSON) — one entry per prod source the repro needs:
  {
    "seeds": [
      {
        "name": "mad",                                   // → DB ofb_repro_<ticket>_mad
        "source": { "target": "mad" },
        "local":  { "admin_env": "PGLOCAL_MAD_ADMIN", "template_db": "ofb_master" },
        "tables": [ { "name": "master_site", "where": "site_code = 'ABCDE'", "limit": 5 } ]
      },
      {
        "name": "shard3",                                // → DB ofb_repro_<ticket>_shard3
        "source": { "agency_id": "3ABCDE00000001" },
        "local":  { "admin_env": "PGLOCAL_ASS_ADMIN", "template_db": "ofb_shard" },
        "tables": [
          { "schema": "public", "name": "player",
            "where": "player_code = 'ABCDE00000001'", "limit": 5, "mask_columns": ["phone"] },
          { "name": "wallet", "where": "player_id = 42", "limit": 50 }
        ]
      }
    ]
  }

  A single-source bug can still use the flat shorthand — top-level {source, template_db, tables}
  is normalized to one seed on PGLOCAL_ADMIN.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

HEX = "0123456789abcdef"
PER_TABLE_CAP = 500      # rows/table before --approve-large is required
TOTAL_CAP = 2000         # rows across the WHOLE run (all seeds) before --approve-large

STATEMENT_TIMEOUT_MS = 15_000
CONN_OPTIONS_RO = (
    f"-c default_transaction_read_only=on -c statement_timeout={STATEMENT_TIMEOUT_MS}"
)

# Every local maintenance DSN the tool may use. A seed picks one by name via local.admin_env;
# teardown/list sweep all that are set.
ADMIN_ENVS = ["PGLOCAL_ADMIN", "PGLOCAL_MAD_ADMIN", "PGLOCAL_ASS_ADMIN"]

ENV_PATH = Path(__file__).parent / ".env"
PATTERNS_FILE = Path(__file__).parent.parent / "lib" / "pii-patterns.txt"

PII_COLUMN_RE = re.compile(
    r"(phone|tel|mobile|msisdn|e?mail|passport|national_?id|citizen|id_?card|"
    r"bank_?acc|account_?no|iban|wallet|addr(ess)?|token|secret|passw(or)?d|"
    r"(^|_)ip(_|$)|"  # ip / player_ip / ip_addr — external PII the value scanner can't shape-match
    r"(first|last|full|holder|real|customer)_?name)",
    re.IGNORECASE,
)
MASK = "***MASKED***"


# --- shared pattern list (same file the bash egress gate reads) --------------------------
def load_pii_patterns() -> list[tuple[str, "re.Pattern[str]"]]:
    out: list[tuple[str, re.Pattern[str]]] = []
    if not PATTERNS_FILE.is_file():
        return out
    for line in PATTERNS_FILE.read_text(encoding="utf-8").splitlines():
        if not line or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        cat, mode, pat = parts
        try:
            out.append((cat, re.compile(pat, re.IGNORECASE if mode == "ci" else 0)))
        except re.error:
            continue
    return out


_PATTERNS = load_pii_patterns()


def value_has_pii(text: str) -> bool:
    return any(rx.search(text) for _, rx in _PATTERNS)


def mask_row(columns: list[str], row: dict, extra_mask: set[str]) -> tuple[dict, int]:
    """(masked_row, masked_cell_count). Mask a cell whose column name looks personal, is
    explicitly listed, or whose stringified value trips the shared PII patterns."""
    masked, n = {}, 0
    for col in columns:
        val = row.get(col)
        if val is not None and (col in extra_mask or PII_COLUMN_RE.search(col) or value_has_pii(str(val))):
            masked[col] = MASK
            n += 1
        else:
            masked[col] = val
    return masked, n


# --- prod target resolution (mirrors prod_pg_mcp.py) -------------------------------------
def target_key(target: str | None, agency_id: str | None) -> str:
    if agency_id:
        first = agency_id.strip()[:1].lower()
        if first not in HEX:
            raise ValueError(f"agency_id {agency_id!r} does not start with a shard hex 0-f")
        return f"ass_{first}"
    if not target:
        raise ValueError("source needs `target` ('mad' | hex 0-f) or `agency_id`")
    t = target.strip().lower()
    if t == "mad":
        return "mad"
    if len(t) == 1 and t in HEX:
        return f"ass_{t}"
    raise ValueError(f"invalid target {target!r}; use 'mad' or a shard hex 0-f")


def prod_env_var(key: str) -> str:
    return "PGPROD_MAD" if key == "mad" else f"PGPROD_ASS_{key[4:].upper()}"


def slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9_]", "_", text.strip().lower())
    return s.strip("_")


def repro_db_name(ticket: str, seed_name: str) -> str:
    t = slug(ticket)
    if not t:
        raise ValueError("empty ticket key")
    return f"ofb_repro_{t}_{slug(seed_name)}"


def repro_db_prefix(ticket: str) -> str:
    return f"ofb_repro_{slug(ticket)}_"


def _swap_dbname(dsn: str, dbname: str) -> str:
    return re.sub(r"(postgresql://[^/]+/)[^?]*", r"\g<1>" + dbname, dsn, count=1)


def _host_port_db(dsn: str) -> str:
    m = re.match(r"postgresql://[^@]*@([^/]+)/([^?]*)", dsn)
    return f"{m.group(1)}/{m.group(2)}" if m else "?"


# --- spec normalization ------------------------------------------------------------------
def normalize_seeds(spec: dict) -> list[dict]:
    if "seeds" in spec:
        seeds = spec["seeds"]
    else:  # flat shorthand → one seed on the fallback admin
        seeds = [{
            "name": None,
            "source": spec.get("source", {}),
            "local": {"admin_env": "PGLOCAL_ADMIN", "template_db": spec.get("template_db")},
            "tables": spec.get("tables", []),
        }]
    out = []
    for i, s in enumerate(seeds):
        src = s.get("source", {})
        key = target_key(src.get("target"), src.get("agency_id"))
        name = s.get("name") or ("mad" if key == "mad" else key[4:])
        out.append({
            "name": name,
            "prod_key": key,
            "admin_env": (s.get("local") or {}).get("admin_env", "PGLOCAL_ADMIN"),
            "template_db": (s.get("local") or {}).get("template_db"),
            "tables": s.get("tables", []),
        })
    if not out:
        raise ValueError("spec has no seeds")
    return out


# --- actions -----------------------------------------------------------------------------
def _need_psycopg():
    try:
        import psycopg  # noqa: F401
    except ImportError:
        sys.exit("psycopg is required — run via `uv run scripts/db/prod_repro_seed.py ...`")


def _admin_dsn(env_name: str) -> str:
    dsn = os.environ.get(env_name)
    if not dsn:
        sys.exit(f"{env_name} not set in scripts/db/.env (LOCAL maintenance DB, CREATEDB rights)")
    return dsn


def do_seed(args) -> int:
    _need_psycopg()
    import psycopg
    from psycopg.rows import dict_row

    seeds = normalize_seeds(json.loads(Path(args.spec).read_text(encoding="utf-8")))

    # Enforce caps up front, across the WHOLE run (all seeds).
    total = sum(int(t.get("limit", PER_TABLE_CAP)) for s in seeds for t in s["tables"])
    over = [f'{s["name"]}.{t["name"]}' for s in seeds for t in s["tables"]
            if int(t.get("limit", PER_TABLE_CAP)) > PER_TABLE_CAP]
    if (over or total > TOTAL_CAP) and not args.approve_large:
        sys.exit(
            f"seed exceeds entity-scope caps (per-table {PER_TABLE_CAP}, total {TOTAL_CAP}): "
            f"over-cap={over or '-'}, requested total={total}. Keep it a tight entity graph, "
            f"not a table dump. Re-run with --approve-large only if a wide join is required."
        )

    print(f"[seed] ticket={args.ticket} seeds={[s['name'] for s in seeds]} dry_run={args.dry_run}")
    masked_cells = 0
    wired = []  # (seed_name, prod_key, db_name, admin_env, local_loc) for the final report

    for s in seeds:
        prod_dsn = os.environ.get(prod_env_var(s["prod_key"]))
        if not prod_dsn:
            sys.exit(f"prod target {s['prod_key']!r} has no DSN — set {prod_env_var(s['prod_key'])}")
        admin = _admin_dsn(s["admin_env"])
        dbname = repro_db_name(args.ticket, s["name"])
        print(f"  seed '{s['name']}': prod={s['prod_key']} → {dbname} on {s['admin_env']} ({_host_port_db(admin)})")

        # 1) pull + mask from prod (read-only)
        pulled = []
        with psycopg.connect(prod_dsn, autocommit=True, options=CONN_OPTIONS_RO) as pconn:
            for t in s["tables"]:
                schema, name = t.get("schema", "public"), t["name"]
                limit = min(int(t.get("limit", PER_TABLE_CAP)),
                            PER_TABLE_CAP if not args.approve_large else 10 ** 9)
                extra = set(t.get("mask_columns", []))
                sql = f'SELECT * FROM "{schema}"."{name}" WHERE {t.get("where", "true")} LIMIT {limit}'
                with pconn.cursor(row_factory=dict_row) as cur:
                    cur.execute(sql)
                    cols = [d.name for d in cur.description]
                    rows = cur.fetchall()
                mrows = []
                for r in rows:
                    mr, n = mask_row(cols, r, extra)
                    masked_cells += n
                    mrows.append(mr)
                pulled.append(({"schema": schema, "name": name}, mrows, cols))
                print(f"      {len(rows):>4} rows from {schema}.{name}")

        wired.append((s["name"], s["prod_key"], dbname, s["admin_env"], _host_port_db(admin)))
        if args.dry_run:
            continue

        # 2) create the throwaway DB (from a template so the schema exists), then load
        template = s["template_db"]
        with psycopg.connect(admin, autocommit=True) as aconn:
            exists = aconn.execute("SELECT 1 FROM pg_database WHERE datname=%s", (dbname,)).fetchone()
            if not exists:
                if template:
                    aconn.execute(f'CREATE DATABASE "{dbname}" TEMPLATE "{template}"')
                    print(f"      created {dbname} from template {template}")
                else:
                    aconn.execute(f'CREATE DATABASE "{dbname}"')
                    print(f"      created empty {dbname} (no template_db — tables must already exist)")
            else:
                print(f"      {dbname} exists — appending")

        inserted = 0
        with psycopg.connect(_swap_dbname(admin, dbname), autocommit=False) as lconn:
            for tinfo, mrows, cols in pulled:
                if not mrows:
                    continue
                fq = f'"{tinfo["schema"]}"."{tinfo["name"]}"'
                collist = ", ".join(f'"{c}"' for c in cols)
                ph = ", ".join(["%s"] * len(cols))
                ins = f'INSERT INTO {fq} ({collist}) VALUES ({ph}) ON CONFLICT DO NOTHING'
                with lconn.cursor() as cur:
                    for r in mrows:
                        cur.execute(ins, tuple(r[c] for c in cols))
                        inserted += cur.rowcount
            lconn.commit()
        print(f"      inserted {inserted} masked rows")

    print(f"[seed] masked {masked_cells} PII cells total.")
    if args.dry_run:
        print("[dry-run] no local write performed.")
        return 0
    print("\nWire the local service to these throwaway DBs, then reproduce:")
    for name, key, db, env, loc in wired:
        role = "MASTER" if key == "mad" else f"SHARD {key[4:]}"
        print(f"  {role:<9} connection → database {db}   ({loc})")
    print(f"When done: prod_repro_seed.py --ticket {args.ticket} --teardown")
    return 0


def do_teardown(args) -> int:
    _need_psycopg()
    import psycopg

    prefix = repro_db_prefix(args.ticket)
    dropped = []
    for env in ADMIN_ENVS:
        dsn = os.environ.get(env)
        if not dsn:
            continue
        with psycopg.connect(dsn, autocommit=True) as aconn:
            names = [r[0] for r in aconn.execute(
                "SELECT datname FROM pg_database WHERE datname LIKE %s", (prefix + "%",)).fetchall()]
            for db in names:
                aconn.execute(
                    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                    "WHERE datname=%s AND pid<>pg_backend_pid()", (db,))
                aconn.execute(f'DROP DATABASE IF EXISTS "{db}"')
                dropped.append(f"{db} ({env})")
    if dropped:
        print("[teardown] dropped:")
        for d in dropped:
            print(f"  {d}")
    else:
        print(f"[teardown] nothing to drop for {args.ticket} (no {prefix}* DBs on any configured instance)")
    print("Zero prod-derived data remains locally for this ticket.")
    return 0


def do_list(_args) -> int:
    _need_psycopg()
    import psycopg

    any_found = False
    for env in ADMIN_ENVS:
        dsn = os.environ.get(env)
        if not dsn:
            continue
        with psycopg.connect(dsn, autocommit=True) as aconn:
            rows = aconn.execute(
                "SELECT datname FROM pg_database WHERE datname LIKE 'ofb_repro_%' ORDER BY 1").fetchall()
        if rows:
            any_found = True
            print(f"{env} ({_host_port_db(dsn)}):")
            for (n,) in rows:
                print(f"  {n}")
    if not any_found:
        print("no throwaway repro DBs (ofb_repro_*) on any configured local instance")
    return 0


def do_selftest(_args) -> int:
    print(f"env file:      {ENV_PATH} ({'present' if ENV_PATH.exists() else 'MISSING'})")
    print(f"patterns file: {PATTERNS_FILE} ({'present' if PATTERNS_FILE.is_file() else 'MISSING'})")
    print(f"loaded {len(_PATTERNS)} PII detectors: {sorted({c for c, _ in _PATTERNS})}")
    for var in ADMIN_ENVS + ["PGPROD_MAD"]:
        print(f"  {var:<18} {'set' if os.environ.get(var) else 'unset'}")
    cols = ["player_code", "phone", "email", "balance", "note", "ip", "chat_token", "status"]
    row = {"player_code": "GC78900000021", "phone": "0891234567", "email": "x@y.com",
           "balance": 100000000, "note": "wallet 0x" + "a" * 40, "ip": "203.0.113.7",
           "chat_token": "eyJhbGciOi_secrettoken", "status": "ACTIVE"}
    masked, n = mask_row(cols, row, set())
    ok = (masked["player_code"] == "GC78900000021" and masked["balance"] == 100000000
          and masked["status"] == "ACTIVE"
          and masked["phone"] == MASK and masked["email"] == MASK and masked["note"] == MASK
          and masked["ip"] == MASK and masked["chat_token"] == MASK)
    print(f"  mask demo: {masked}")
    print(f"  masked {n} cells; identity+money+status preserved, PII/secret masked: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def main() -> int:
    from dotenv import load_dotenv

    load_dotenv(ENV_PATH)
    p = argparse.ArgumentParser(description="Seed throwaway local repro DBs from prod (masked, multi-source).")
    p.add_argument("--ticket", help="ticket key; names the throwaway DBs ofb_repro_<ticket>_<seed>")
    p.add_argument("--spec", help="path to the seed spec JSON")
    p.add_argument("--approve-large", action="store_true", help="allow a run above the entity-scope caps")
    p.add_argument("--dry-run", action="store_true", help="pull+mask from prod but write nothing locally")
    p.add_argument("--teardown", action="store_true", help="DROP every ofb_repro_<ticket>_* DB across instances")
    p.add_argument("--list", action="store_true", help="list ofb_repro_* DBs on every configured local instance")
    p.add_argument("--selftest", action="store_true", help="validate deps/config/mask, no DB access")
    args = p.parse_args()

    if args.selftest:
        return do_selftest(args)
    if args.list:
        return do_list(args)
    if args.teardown:
        if not args.ticket:
            sys.exit("--teardown needs --ticket")
        return do_teardown(args)
    if args.ticket and args.spec:
        return do_seed(args)
    p.print_help()
    return 64


if __name__ == "__main__":
    raise SystemExit(main())
