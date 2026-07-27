# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "psycopg[binary]>=3.1",
#   "python-dotenv>=1.0",
# ]
# ///
"""prod_repro_seed — the ONE sanctioned path to move production data into local repro DBs.

Purpose: during `/diagnosing-bugs`, a developer sometimes needs the *actual* offending prod
rows to reproduce a data bug against the local source. Reading it is what `pg-triage`
does; **persisting** any of it locally is gated here, so the mask/isolation/teardown
invariants are enforced in code, not left to memory:

  0. PRODUCTION IS GATED — a `"env": "prod"` source requires the per-machine opt-in
     (`triage.prod`, via scripts/lib/triage_policy.py), checked before the DSN is looked up.
     Credentials being present in .env is not permission. Staging needs no opt-in.
  1. READ-ONLY source — pulled through the same read-only DSNs + read-only transaction as the
     triage MCP. This tool never writes to the environment it reads.
  2. HARD MASK on persist, FOR PRODUCTION — every external-PII value
     (scripts/lib/pii-patterns.txt) and every PII-named column of a PROD row is masked BEFORE it
     is written locally. Inner-system identity (`*_code`, UUID), money integers and status
     survive (the bug needs them); phone/email/wallet/bank/national-id do not. **A `staging`
     source is loaded verbatim and never vaulted** — staging is not the production boundary, and
     a repro that hinges on the real shape of a value needs the real value (docs/adr/0005).
  3. THROWAWAY, ISOLATED DBs — data lands in dedicated `repro_<ticket>_<seed>` databases,
     never the shared local DB. `--teardown` DROPs every one for the ticket, across instances.
  4. ENTITY-SCOPED — you seed the rows reachable from the ticket's identifier, not a table
     dump; a seed above the row caps needs an explicit `--approve-large`.

A prod target is just a name you configure via `PGPROD_<NAME>` in scripts/db/.env (the same
targets the triage MCP uses) — there is no topology baked in. If your service connects to more
than one database at once (a master plus a shard, or two service DBs), a spec lists a `seeds`
entry per source: each pulls one prod target into one throwaway DB on one local instance.
Reproduce a multi-database bug by seeding them all in one run, then point each of the
service's connections at the DBs this prints.

Normal development is untouched: this only governs prod-DERIVED data into throwaway DBs.
`execute_sql` INSERTs of synthetic/fixture data into the normal local DB stay free.

  seed:      prod_repro_seed.py --ticket APP-123 --spec seed.json [--approve-large] [--dry-run] [--fk-bypass]
  teardown:  prod_repro_seed.py --ticket APP-123 --teardown
  into-db:   prod_repro_seed.py --into-db <localdb> --spec seed.json --fk-bypass   # load into the DB the
             service already uses (no throwaway/reconfig); teardown: --into-db <localdb> --spec seed.json --teardown
  list:      prod_repro_seed.py --list
  selftest:  prod_repro_seed.py --selftest      # deps/config/mask, no prod or local access

Environment (scripts/db/.env — never Read/cat/grep it, the .env guard blocks it):
  PGPROD_<NAME>                   read-only PROD DSNs (shared with the triage MCP)
  PGSTG_<NAME> / PGSTG_DSN        read-only STAGING DSNs — per target, or one base DSN for a
                                  single instance (database per target; override with
                                  PGSTG_DB_<NAME>). See scripts/lib/pg_staging.py
  PGLOCAL_ADMIN                   LOCAL maintenance DB (CREATEDB/DROPDB), fallback for shorthand specs
  PGLOCAL_<NAME>_ADMIN            optional per-instance LOCAL maintenance DBs (e.g. PGLOCAL_MAIN_ADMIN)

Spec file (JSON) — one entry per source the repro needs. `source.env` is REQUIRED
("staging" | "prod"): the environment is never defaulted, so prod is never implied.
  {
    "seeds": [
      {
        "name": "main",                                  // → DB repro_<ticket>_main
        "source": { "env": "prod", "target": "main" },
        "local":  { "admin_env": "PGLOCAL_MAIN_ADMIN", "template_db": "app_schema" },
        "tables": [ { "name": "account", "where": "account_code = 'ABCDE'", "limit": 5 } ]
      },
      {
        "name": "secondary",                             // → DB repro_<ticket>_secondary
        "source": { "env": "prod", "target": "secondary" },
        "local":  { "admin_env": "PGLOCAL_SECONDARY_ADMIN", "template_db": "app_shard_schema" },
        "tables": [
          { "schema": "public", "name": "entity",
            "where": "entity_code = 'ABCDE00000001'", "limit": 5, "mask_columns": ["phone"] },
          { "name": "wallet", "where": "entity_id = 42", "limit": 50 }
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

PER_TABLE_CAP = 500      # rows/table before --approve-large is required
TOTAL_CAP = 2000         # rows across the WHOLE run (all seeds) before --approve-large

STATEMENT_TIMEOUT_MS = 15_000
CONN_OPTIONS_RO = (
    f"-c default_transaction_read_only=on -c statement_timeout={STATEMENT_TIMEOUT_MS}"
)

PROD_ENV_PREFIX = "PGPROD_"   # a target "main" reads from PGPROD_MAIN

# Every local maintenance DSN the tool may use. A seed picks one by name via local.admin_env;
# teardown/list sweep every PGLOCAL_* that is set.
FALLBACK_ADMIN_ENV = "PGLOCAL_ADMIN"

ENV_PATH = Path(__file__).parent / ".env"

# The PII policy lives in ONE module — scripts/lib/pii_provenance.py — which reads the shared
# detector list scripts/lib/pii-patterns.txt. This tool borrows two things from it: the
# shape/column rules used to MASK a value on the way to the local sandbox, and the provenance
# vault it records into (keyed hashes of the prod values seen, never the values), so those same
# values are redacted later if they surface in a ticket or a chat post.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import pg_staging  # noqa: E402  — staging DSN resolution, shared with pg_triage_mcp.py
import pii_provenance  # noqa: E402  (path must be set first)
import triage_policy  # noqa: E402  — the production gate, the same one the triage MCPs enforce

PII_COLUMN_RE = pii_provenance.PII_COLUMN_RE
value_has_pii = pii_provenance.value_has_pii
MASK = "***MASKED***"


def mask_row(columns: list[str], row: dict, extra_mask: set[str]) -> tuple[dict, int]:
    """(masked_row, masked_cell_count). Mask a cell whose column name looks personal, is
    explicitly listed, or whose stringified value trips the shared PII patterns."""
    masked, n = {}, 0
    for col in columns:
        val = row.get(col)
        # Only a STRING value can carry the PII shapes we mask (phone/email/ip/token/wallet-
        # address/name). Masking a non-text value (bool/int/uuid/enum returned as non-str) is
        # both semantically wrong AND type-unsafe — writing "***MASKED***" into a bool/enum/uuid
        # column fails the local INSERT (InvalidTextRepresentation). So a mask only replaces a str.
        if isinstance(val, str) and (col in extra_mask or PII_COLUMN_RE.search(col) or value_has_pii(val)):
            masked[col] = MASK
            n += 1
        else:
            masked[col] = val
    return masked, n


# --- prod target resolution (mirrors pg_triage_mcp.py) -------------------------------------
ENV_PROD = "prod"
ENV_STAGING = "staging"
ENVS = (ENV_STAGING, ENV_PROD)


def resolve_env(env: str | None) -> str:
    """No default: a spec that does not name its environment is an error, so a prod pull is
    always something someone wrote down."""
    if not env or not str(env).strip():
        raise ValueError(
            'source needs `env`: "staging" or "prod" (no default — prod is never implied)'
        )
    e = str(env).strip().lower()
    if e not in ENVS:
        raise ValueError(f"invalid source env {env!r}; use {' | '.join(ENVS)}")
    return e


def source_dsn(env: str, key: str) -> str:
    """The read-only DSN for one env+target. Gates production before the lookup, so a machine
    without the opt-in never reaches prod even with credentials sitting in .env."""
    if env == ENV_PROD:
        triage_policy.assert_prod_allowed("seeding from PRODUCTION")
        dsn = os.environ.get(prod_env_var(key))
        if not dsn:
            sys.exit(f"prod target {key!r} has no DSN — set {prod_env_var(key)}")
        return dsn
    try:
        return pg_staging.dsn(key)
    except ValueError as exc:
        sys.exit(str(exc))


def target_key(target: str | None) -> str:
    if not target or not target.strip():
        raise ValueError("source needs a `target` (a configured prod target name, e.g. 'main')")
    return target.strip().lower()


def prod_env_var(key: str) -> str:
    return PROD_ENV_PREFIX + re.sub(r"[^A-Z0-9]+", "_", key.strip().upper())


def slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9_]", "_", text.strip().lower())
    return s.strip("_")


def repro_db_name(ticket: str, seed_name: str) -> str:
    t = slug(ticket)
    if not t:
        raise ValueError("empty ticket key")
    return f"repro_{t}_{slug(seed_name)}"


def repro_db_prefix(ticket: str) -> str:
    return f"repro_{slug(ticket)}_"


def _configured_admin_envs() -> list[str]:
    """Every PGLOCAL_* maintenance DSN set in the environment (teardown/list sweep these)."""
    envs = [k for k in os.environ if k.startswith("PGLOCAL_") and os.environ[k]]
    # keep the fallback first for a stable, predictable order
    envs.sort(key=lambda k: (k != FALLBACK_ADMIN_ENV, k))
    return envs


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
            "local": {"admin_env": FALLBACK_ADMIN_ENV, "template_db": spec.get("template_db")},
            "tables": spec.get("tables", []),
        }]
    out = []
    for i, s in enumerate(seeds):
        src = s.get("source", {})
        env = resolve_env(src.get("env"))
        key = target_key(src.get("target"))
        name = s.get("name") or key
        out.append({
            "name": name,
            "env": env,
            "prod_key": key,
            "admin_env": (s.get("local") or {}).get("admin_env", FALLBACK_ADMIN_ENV),
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

    into_db = getattr(args, "into_db", None)
    if into_db:
        print(f"[seed] into-db mode: loading MASKED prod-derived rows into EXISTING local DB "
              f"'{into_db}' (NOT isolated). Clean up with `--into-db {into_db} --spec <spec> --teardown` "
              f"(targeted DELETE) or reset the local DB. Never used against prod.")
    print(f"[seed] ticket={args.ticket} seeds={[s['name'] for s in seeds]} dry_run={args.dry_run}")
    masked_cells = 0
    wired = []  # (seed_name, prod_key, db_name, admin_env, local_loc) for the final report

    for s in seeds:
        src_env = s["env"]
        is_prod = src_env == ENV_PROD
        src_dsn = source_dsn(src_env, s["prod_key"])
        admin = _admin_dsn(s["admin_env"])
        dbname = into_db or repro_db_name(args.ticket, s["name"])
        dest = f"existing DB {dbname} (into-db)" if into_db else dbname
        print(f"  seed '{s['name']}': {src_env}={s['prod_key']} → {dest} on {s['admin_env']} "
              f"({_host_port_db(admin)}) [{'masked + vaulted' if is_prod else 'verbatim, not vaulted'}]")

        # 1) pull from the source (read-only), masking + vaulting PROD rows only
        pulled = []
        with psycopg.connect(src_dsn, autocommit=True, options=CONN_OPTIONS_RO) as pconn:
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
                if is_prod:
                    # Vault the prod values BEFORE masking: what is masked out of the local
                    # sandbox is exactly what must also be redacted if it ever reaches a ticket
                    # or a chat post. Staging is skipped on both counts — vaulting it would make
                    # identical-looking local data start disappearing from tickets.
                    pii_provenance.record_rows(cols, rows)
                    mrows = []
                    for r in rows:
                        mr, n = mask_row(cols, r, extra)
                        masked_cells += n
                        mrows.append(mr)
                else:
                    mrows = list(rows)
                pulled.append(({"schema": schema, "name": name}, mrows, cols))
                print(f"      {len(rows):>4} rows from {schema}.{name}")

        wired.append((s["name"], s["prod_key"], dbname, s["admin_env"], _host_port_db(admin)))
        if args.dry_run:
            continue

        # 2) create the throwaway DB (from a template so the schema exists), then load —
        #    UNLESS into-db mode, which loads into an existing DB the service already uses.
        if into_db:
            print(f"      loading into existing DB {dbname} (into-db; no create/template)")
        else:
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
            # Optional: load an entity slice into a full-schema template without seeding every
            # FK parent. session_replication_role=replica disables FK/user triggers for THIS
            # local load session only (never prod) — a repro convenience, not a prod bypass.
            if getattr(args, "fk_bypass", False):
                lconn.execute("SET session_replication_role = replica")
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
        print(f"      inserted {inserted} rows ({'masked' if is_prod else 'verbatim staging'})")

    envs_used = sorted({s["env"] for s in seeds})
    print(f"[seed] sources: {', '.join(envs_used)}; masked {masked_cells} PII cells "
          f"(prod rows only — staging rows are loaded verbatim).")
    if args.dry_run:
        print("[dry-run] no local write performed.")
        return 0
    if into_db:
        print("\nRows loaded into the existing DB the service already uses — reproduce directly (no reconfig):")
        for name, key, db, env, loc in wired:
            print(f"  target {key:<12} → {db}   ({loc})")
        print(f"When done: prod_repro_seed.py --into-db {into_db} --spec <spec> --teardown"
              f"   (targeted DELETE of the seeded rows — never DROPs {into_db})")
    else:
        print("\nWire the local service to these throwaway DBs, then reproduce:")
        for name, key, db, env, loc in wired:
            print(f"  target {key:<12} connection → database {db}   ({loc})")
        print(f"When done: prod_repro_seed.py --ticket {args.ticket} --teardown")
    return 0


def _teardown_into_db(args) -> int:
    import psycopg

    into_db = args.into_db
    if not getattr(args, "spec", None):
        sys.exit("--into-db --teardown needs --spec: it DELETEs only the seeded rows (by each table's "
                 "WHERE) and never DROPs the shared DB, so it must know what to remove.")
    seeds = normalize_seeds(json.loads(Path(args.spec).read_text(encoding="utf-8")))
    deleted = 0
    for s in seeds:
        admin = _admin_dsn(s["admin_env"])
        with psycopg.connect(_swap_dbname(admin, into_db), autocommit=True) as c:
            c.execute("SET session_replication_role = replica")  # FK off → delete order-independent
            for t in reversed(s["tables"]):  # children before parents (belt; replica already off)
                schema, name = t.get("schema", "public"), t["name"]
                cur = c.execute(f'DELETE FROM "{schema}"."{name}" WHERE {t.get("where", "true")}')
                deleted += cur.rowcount
                print(f"  deleted {cur.rowcount:>4} from {schema}.{name} in {into_db} ({_host_port_db(admin)})")
    print(f"[teardown] into-db: DELETEd {deleted} seeded rows from '{into_db}' — DB preserved, never dropped.")
    return 0


def do_teardown(args) -> int:
    _need_psycopg()
    import psycopg

    if getattr(args, "into_db", None):
        return _teardown_into_db(args)

    prefix = repro_db_prefix(args.ticket)
    dropped = []
    for env in _configured_admin_envs():
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
    for env in _configured_admin_envs():
        dsn = os.environ.get(env)
        if not dsn:
            continue
        with psycopg.connect(dsn, autocommit=True) as aconn:
            rows = aconn.execute(
                "SELECT datname FROM pg_database WHERE datname LIKE 'repro_%' ORDER BY 1").fetchall()
        if rows:
            any_found = True
            print(f"{env} ({_host_port_db(dsn)}):")
            for (n,) in rows:
                print(f"  {n}")
    if not any_found:
        print("no throwaway repro DBs (repro_*) on any configured local instance")
    return 0


def do_selftest(_args) -> int:
    print(f"env file:      {ENV_PATH} ({'present' if ENV_PATH.exists() else 'MISSING'})")
    patterns_file = pii_provenance.PATTERNS_FILE
    detectors = pii_provenance.load_patterns()
    print(f"patterns file: {patterns_file} ({'present' if patterns_file.is_file() else 'MISSING'})")
    print(f"loaded {len(detectors)} PII detectors: {sorted({c for c, _ in detectors})}")
    print(f"provenance vault: {pii_provenance.vault_dir()}")
    admin_envs = _configured_admin_envs()
    prod_targets = sorted(k for k in os.environ if k.startswith(PROD_ENV_PREFIX) and os.environ[k])
    print(f"  local admin envs set: {admin_envs or '(none)'}")
    print(f"  prod targets set:     {prod_targets or '(none)'}")
    print(f"  staging:              {pg_staging.describe()}")
    for _k in ("enabled", "prod"):
        _v, _src = triage_policy.resolve(_k)
        print(f"  triage.{_k:<8} = {str(_v).lower():<5} ({_src})")
    _dead = triage_policy.dead_key_present()
    if _dead:
        print(f"  ! {_dead} still sets the REMOVED key `prod_triage.enabled` — ignored; use triage.prod")
    import uuid as _uuid
    cols = ["account_code", "phone", "email", "balance", "note", "ip", "chat_token", "status",
            "wallet_type", "wallet_id", "requires_secondary_password"]
    row = {"account_code": "ABCDE00000021", "phone": "0891234567", "email": "x@y.com",
           "balance": 100000000, "note": "wallet 0x" + "a" * 40, "ip": "203.0.113.7",
           "chat_token": "eyJhbGciOi_secrettoken", "status": "ACTIVE",
           # non-text / inner-system cols whose NAMES brush the PII patterns — must survive
           # untouched (masking them would corrupt the type and break the INSERT).
           "wallet_type": "CASH", "wallet_id": _uuid.UUID(int=1),
           "requires_secondary_password": True}
    masked, n = mask_row(cols, row, set())
    ok = (masked["account_code"] == "ABCDE00000021" and masked["balance"] == 100000000
          and masked["status"] == "ACTIVE" and masked["wallet_type"] == "CASH"
          and masked["wallet_id"] == _uuid.UUID(int=1)
          and masked["requires_secondary_password"] is True
          and masked["phone"] == MASK and masked["email"] == MASK and masked["note"] == MASK
          and masked["ip"] == MASK and masked["chat_token"] == MASK)
    print(f"  mask demo: {masked}")
    print(f"  masked {n} cells; identity+money+status+enum/uuid/bool preserved, PII/secret masked: {'PASS' if ok else 'FAIL'}")

    # The env axis: a spec must name it, staging must resolve, and a prod source must be refused
    # unless this machine opted in.
    spec_env_required = False
    try:
        normalize_seeds({"source": {"target": "main"}, "tables": []})
    except ValueError as exc:
        spec_env_required = "env" in str(exc)
    if triage_policy.prod_allowed():
        gate_ok, gate_note = True, "triage.prod is ON — prod sources are legitimately allowed"
    else:
        try:
            source_dsn(ENV_PROD, "main")
            gate_ok, gate_note = False, "prod source was NOT refused"
        except PermissionError:
            gate_ok, gate_note = True, "prod source refused while triage.prod is off"
        except SystemExit:
            gate_ok, gate_note = False, "prod source failed on the DSN lookup, not the gate"
    print(f"  spec requires source.env: {'PASS' if spec_env_required else 'FAIL'}")
    print(f"  prod gate: {'PASS' if gate_ok else 'FAIL'} — {gate_note}")
    return 0 if (ok and spec_env_required and gate_ok) else 1


def main() -> int:
    from dotenv import load_dotenv

    load_dotenv(ENV_PATH)
    p = argparse.ArgumentParser(description="Seed throwaway local repro DBs from prod (masked, multi-source).")
    p.add_argument("--ticket", help="ticket key; names the throwaway DBs repro_<ticket>_<seed>")
    p.add_argument("--spec", help="path to the seed spec JSON")
    p.add_argument("--approve-large", action="store_true", help="allow a run above the entity-scope caps")
    p.add_argument("--dry-run", action="store_true", help="pull+mask from prod but write nothing locally")
    p.add_argument("--fk-bypass", action="store_true", help="SET session_replication_role=replica during the LOCAL load so an entity slice loads into a full-schema template without seeding every FK parent (repro convenience; local throwaway only, never prod)")
    p.add_argument("--into-db", metavar="DBNAME", help="load the masked slice into an EXISTING local DB (the one the running service already uses) instead of an isolated throwaway — no create/template, and --teardown does a targeted DELETE (never DROP). Simpler repro (no service reconfig) at the cost of isolation; the DB is polluted with masked prod-derived rows until you teardown/reset. Pair with --fk-bypass.")
    p.add_argument("--teardown", action="store_true", help="DROP every repro_<ticket>_* DB across instances")
    p.add_argument("--list", action="store_true", help="list repro_* DBs on every configured local instance")
    p.add_argument("--selftest", action="store_true", help="validate deps/config/mask, no DB access")
    args = p.parse_args()

    if args.selftest:
        return do_selftest(args)
    if args.list:
        return do_list(args)
    if args.teardown:
        # into-db teardown is spec-driven (targeted DELETE), so it doesn't need a ticket;
        # throwaway teardown DROPs repro_<ticket>_* and does.
        if not args.into_db and not args.ticket:
            sys.exit("--teardown needs --ticket (or --into-db --spec for a targeted DELETE)")
        return do_teardown(args)
    if args.spec and (args.ticket or args.into_db):
        return do_seed(args)
    p.print_help()
    return 64


if __name__ == "__main__":
    raise SystemExit(main())
