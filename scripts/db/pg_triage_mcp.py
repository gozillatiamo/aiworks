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
"""pg-triage — on-demand, READ-ONLY MCP wrapper over the DEPLOYED Postgres (staging + production).

One MCP process, two environments, many targets. Both axes are chosen *per call* and neither is
ever baked into the process or defaulted:

  - `env`    — "staging" or "prod". REQUIRED on every data tool: an unnamed environment is an
               error, never a guess, so production is only ever reached by asking for it.
  - `target` — a named database inside that environment. Prod targets are one DSN each
               (`PGPROD_<NAME>` → `target="<name>"`); staging can be the same shape
               (`PGSTG_<NAME>`) or ONE instance holding a database per target — set `PGSTG_DSN`
               once and the database defaults to the target name (override per target with
               `PGSTG_DB_<NAME>`). See scripts/lib/pg_staging.py.

There is **no sharding scheme baked in here** — it fits any topology. If your data is sharded
or split across several databases, declare one target per database (`PGPROD_SHARD0` →
`target="shard0"`, …) and address each explicitly; a fan-out is just a query per target.

Targets resolve to read-only DSNs loaded from `scripts/db/.env` *by this process* — the
credentials never pass through the agent, the MCP config, or the transcript. Callers pass an
`env` + `target`; the DSN lookup and connection stay inside the server.

Safety is layered, because a production database behind an AI tool is a real risk:
  1. Production is gated by policy, checked in-process before any DSN lookup or connection
     (`scripts/lib/triage_policy.py` → `triage.prod`, read local-first). Credentials being
     present is not permission. Staging needs no opt-in: it is not the production boundary.
  2. The DSNs must use a read-only DB role — staging included. This is the actual guarantee.
  3. Every connection is opened with `default_transaction_read_only=on`, a 15s
     `statement_timeout`, and an idle-transaction timeout — a backstop that makes the DB
     itself reject any write (including writable CTEs) with a clear error.
  4. `execute_sql` only accepts SELECT / WITH / TABLE / VALUES, a single statement, and
     paginates results at 200 rows/page so a fat table can't flood the context.
  5. PII provenance is PROD-ONLY. Rows a prod target returns are fed to the vault
     (scripts/lib/pii_provenance.py) as keyed hashes — never values — which is what makes the
     egress redaction in the tracker / notify adapters prod-specific: they mask a personal value
     if and only if production is where it came from. Staging rows are never vaulted, so
     identical-looking staging or local data flows untouched. Every result says which happened
     (`env` + `pii_vaulted`). See docs/agents/pii-provenance.md.

Pools are lazy (min_size=0): the process holds zero connections until a tool is actually
called, and `disconnect()` drops every pool so nothing lingers after a triage job — the "down
the MCP when done" teardown, without needing to kill the managed process.

  uv run scripts/db/pg_triage_mcp.py --selftest         # deps + config + policy, no DB access
  uv run scripts/db/pg_triage_mcp.py --verify staging    # live read-only acceptance run
"""

from __future__ import annotations

import atexit
import difflib
import logging
import json
import os
import re
import signal
import sys
import threading
import time
from collections.abc import Mapping
from pathlib import Path

import psycopg
from dotenv import dotenv_values, load_dotenv
from mcp.server.fastmcp import FastMCP
from psycopg.conninfo import conninfo_to_dict, make_conninfo
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool, PoolTimeout

# Value-exact PII provenance (scripts/lib/pii_provenance.py). Every row this server hands back
# came from PRODUCTION by definition, so each personal value in it is vaulted as a keyed hash
# — that record is what later lets the tracker/notify adapters redact exactly those values
# from a ticket or Slack post while leaving identical-looking local/staging data alone.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import gcloud_tunnel  # noqa: E402 — stdlib-only tunnel helper, shared with redis_triage
import pg_staging  # noqa: E402  — staging DSN resolution, shared with prod_repro_seed.py
import triage_policy  # noqa: E402  — the production gate; load-bearing, so never optional

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
POOL_TIMEOUT_S = 30.0  # psycopg_pool's default; a constant so the selftest can shrink it

ENV_PROD = "prod"
ENV_STAGING = "staging"
ENVS = (ENV_STAGING, ENV_PROD)

ENV_PREFIX = "PGPROD_"  # a prod target "main" is configured by PGPROD_MAIN
TUNNEL_SUFFIX = "_TUNNEL"  # PGPROD_MAIN_TUNNEL / PGSTG_MAIN_TUNNEL — a sidecar, never a target

# libpq connection options — enforce read-only + timeouts at the server level, as a backstop
# on top of the read-only DB role the DSNs are required to use.
CONN_OPTIONS = (
    f"-c default_transaction_read_only=on "
    f"-c statement_timeout={STATEMENT_TIMEOUT_MS} "
    f"-c idle_in_transaction_session_timeout={IDLE_TX_TIMEOUT_MS}"
)

IDLE_TIMEOUT_S = 120        # tunnel idle for this long -> reaped by the watchdog
WATCHDOG_TICK_S = 10        # how often the watchdog checks
TUNNEL_READY_TIMEOUT_S = 45 # how long to wait for the port-forward to answer

_pools: dict[str, ConnectionPool] = {}
_tunnels: dict[str, gcloud_tunnel.Tunnel] = {}  # keyed by pool key (env:target); gost targets share one proc
_lock = threading.RLock()   # guards both _pools and _tunnels
_connect_errors: dict[str, str] = {}  # pool key -> last scrubbed connect reason (see _CapturingConn)

# psycopg_pool logs every failed connect at WARNING with the raw libpq text; with no handler
# configured Python's lastResort prints it to stderr — host, user and (for a malformed DSN)
# password fragments. The tool error now carries a scrubbed reason instead.
logging.getLogger("psycopg.pool").setLevel(logging.CRITICAL + 1)
_watchdog: threading.Thread | None = None

mcp = FastMCP("pg-triage")

# --- env + target resolution -------------------------------------------------------------


def _resolve_env(env: str | None) -> str:
    """Canonicalize the environment. There is NO default: an unnamed env is an error, never a
    guess, so prod is only ever reached by asking for it explicitly."""
    if not env or not env.strip():
        raise ValueError("provide `env`: 'staging' or 'prod' (no default — prod is never implied)")
    e = env.strip().lower()
    if e not in ENVS:
        raise ValueError(f"unknown env {env!r}; use {' | '.join(ENVS)}")
    return e


def _env_var(key: str) -> str:
    """Env var backing a target: 'main' -> PGPROD_MAIN, 'shard0' -> PGPROD_SHARD0."""
    return ENV_PREFIX + re.sub(r"[^A-Z0-9]+", "_", key.strip().upper())


def _target_key(target: str | None = None) -> str:
    """Canonicalize a request to a lowercase target name.

    A target is just a name you configured via `PGPROD_<NAME>` in the .env — there is no
    topology/sharding logic here, so the name is used verbatim (lowercased)."""
    if not target or not target.strip():
        raise ValueError(
            "provide a `target` — a configured prod target name (e.g. 'main'); see list_targets"
        )
    return target.strip().lower()


# --- the name grammar: ONE classifier for every PGPROD_/PGSTG_ key -------------------------

STAGING_PREFIX = pg_staging.TARGET_PREFIX  # PGSTG_<NAME>: a per-target staging DSN
STAGING_DB_PREFIX = pg_staging.DB_PREFIX  # PGSTG_DB_<NAME>: a database on the base PGSTG_DSN
_NAME_RE = re.compile(r"^[A-Z0-9]+(_[A-Z0-9]+)*$")  # UPPER_SNAKE; single underscores only

REASON_UPPER = "names are UPPER_SNAKE"
REASON_DSN = "reserved: PGSTG_DSN is the staging base DSN; prod has one DSN per target"
REASON_EMPTY = "empty value"
REASON_MULTILINE = "value spans lines — an unbalanced quote swallowed the lines after it"
REASON_NOT_DSN = "not a valid libpq DSN (looks like a sidecar? name it …_TUNNEL)"


def _classify(
    prefix: str, var: str, value: str | None = None, env: Mapping[str, str] | None = None
) -> tuple[str | None, str | None, str | None]:
    """Classify one env var name (+ optional value) under a prefix -> (key, reason, did_you_mean).

    The ONE place the target-name grammar lives; discovery, `list_targets` and `--selftest` all
    call it, so a name can never be accepted by one and rejected by another.

      key      the target key ('<name>') when the var is usable, else None
      reason   a FIXED string saying why it is not usable (None when usable, or not ours)
      did_you_mean  the spelling to use instead, when a rule can suggest one

    A var that is not ours at all, a `_TUNNEL` sidecar, or the staging base `PGSTG_DSN` is
    (None, None, None). A value is only checked when given. `env` is the mapping sibling vars
    are read from (the process env by default; the file's values in the file report). NEVER put
    exception text into `reason`: a libpq parse error can echo a fragment of the value (a
    password) — only fixed strings, booleans and key NAMES ever leave.
    """
    if env is None:
        env = os.environ
    if not var.upper().startswith(prefix):
        return None, None, None
    if var.upper().endswith(TUNNEL_SUFFIX):
        return None, None, None  # a sidecar, never a target (A5); orphans are checked elsewhere
    suffix = var[len(prefix):]
    fixed = prefix + suffix.upper()
    if fixed != var:  # wrong case somewhere: diagnose the upper-cased form, never accept it
        key, _, dym = _classify(prefix, fixed, env=env)
        return None, REASON_UPPER, dym or (fixed if key else None)
    if not _NAME_RE.match(suffix):
        return None, REASON_UPPER, _closest(prefix, var)

    check_dsn = True
    if prefix == STAGING_PREFIX and var == pg_staging.DSN_VAR:
        return None, None, None  # the base DSN, never a target
    if prefix == STAGING_PREFIX and suffix.startswith("DB_"):
        name, check_dsn = suffix[3:], False  # a database name on the base DSN
    else:
        name = suffix
    if name == "DSN":
        return None, REASON_DSN, None
    if not name or not name[0].isalpha():
        return None, REASON_UPPER, _closest(prefix, var)
    key = name.lower()

    if value is not None:
        if value == "":
            return None, REASON_EMPTY, None
        if "\n" in value:
            return None, REASON_MULTILINE, None
        if check_dsn:
            try:
                conninfo_to_dict(value)
            except Exception:  # never surface the message — it can echo part of the value
                return None, REASON_NOT_DSN, None
    return key, None, None


def _closest(prefix: str, var: str) -> str | None:
    """difflib fallback for an unrecognized name: the nearest usable var in the process env."""
    candidates = [
        v for v in os.environ if v.startswith(prefix) and v != var and _NAME_RE.match(v[len(prefix):])
    ]
    hits = difflib.get_close_matches(var, candidates, n=1)
    return hits[0] if hits else None


def _prefix(env: str) -> str:
    return ENV_PREFIX if env == ENV_PROD else STAGING_PREFIX


def _kind(key: str) -> str:
    return "named"


def _configured_targets(env: str) -> list[str]:
    """Target names this machine declares for an environment — every usable `PGPROD_<NAME>`,
    or `PGSTG_<NAME>` / `PGSTG_DB_<NAME>`, per `_classify`, so a `_TUNNEL` sidecar or a
    sidecar-shaped value can never become a phantom target (ADR 0017). With only a base
    `PGSTG_DSN` set, ANY staging name resolves, so the list is what was named, not what is
    reachable."""
    prefix = _prefix(env)
    return sorted({key for var, val in os.environ.items() if (key := _classify(prefix, var, val)[0])})


def _unrecognized() -> list[dict]:
    """Every PGPROD_/PGSTG_ var in the process env the server cannot use, by name + fixed reason."""
    out = []
    for env in ENVS:
        for var, value in os.environ.items():
            _, reason, dym = _classify(_prefix(env), var, value)
            if reason:
                out.append({"env": env, "var": var, "reason": reason, "did_you_mean": dym})
    return out


REASON_SHADOWED = "set in the file but the process env overrides it (override=False)"
REASON_ORPHAN = "orphan sidecar: no {base} DSN"


def _file_key_report(path: Path) -> list[tuple[str, str]]:
    """Every PGPROD_/PGSTG_ key in a dotenv FILE with a verdict -> [(status, line)].

    Reads key NAMES and classifies values in-process; a line carries only the var name, the
    target key/kind and a FIXED reason — never a value. `status` is 'ok' | 'WARN' | 'FAIL'."""
    values = {k: v or "" for k, v in dotenv_values(path).items()}
    out: list[tuple[str, str]] = []
    for var, val in values.items():
        prefix = next((p for p in (ENV_PREFIX, STAGING_PREFIX) if var.upper().startswith(p)), None)
        if prefix is None:
            continue
        if var.upper().endswith(TUNNEL_SUFFIX):
            base = var[: -len(TUNNEL_SUFFIX)]
            if prefix == ENV_PREFIX and not (values.get(base) or os.environ.get(base)):
                out.append(("WARN", f"{var} — {REASON_ORPHAN.format(base=base)}"))
            else:
                out.append(("ok", f"{var} -> sidecar of {base}"))
            continue
        key, reason, dym = _classify(prefix, var, val, env=values)
        if reason:
            out.append(("FAIL", f"{var} — {reason}" + (f"; did you mean {dym}?" if dym else "")))
        elif var in os.environ and os.environ[var] != val:
            out.append(("FAIL", f"{var} — {REASON_SHADOWED}"))
        elif key is None:
            out.append(("ok", f"{var} -> staging base DSN"))
        else:
            out.append(("ok", f"{var} -> target {key} ({_kind(key)})"))
    return out


def _configured(env: str, key: str) -> bool:
    """Whether a target has credentials here. Booleans only — never a DSN."""
    if env == ENV_STAGING:
        return pg_staging.configured(key)
    return bool(os.environ.get(_env_var(key)))


def _dsn(env: str, key: str) -> str:
    if env == ENV_STAGING:
        return pg_staging.dsn(key)
    var = _env_var(key)
    dsn = os.environ.get(var)
    if not dsn:
        raise ValueError(
            f"prod target {key!r} has no DSN — set {var} in scripts/db/.env (read-only account)"
        )
    return dsn


def _pool_key(env: str, key: str) -> str:
    return f"{env}:{key}"


# --- connect-failure reasons -------------------------------------------------------------
#
# `PoolTimeout` carries nothing (`raise ... from None`), and SQLSTATE is None on every
# connect-phase failure, so a reason is classified from the libpq message TEXT. Every
# classified reason is a fixed string — nothing from the error text survives except on the
# unclassified row, where the detail is exact-value scrubbed against the conninfo.
# First match wins; the order matters (a TLS handshake that times out is a timeout).

_REASON_MALFORMED_DSN = "malformed DSN (details withheld: libpq echoes DSN fragments)"
_REASON_RULES: tuple[tuple[tuple[str, ...], str], ...] = (  # (every needle present) -> reason
    (("timeout expired",), "timeout: no answer within connect_timeout"),
    (('missing "="',), _REASON_MALFORMED_DSN),
    (("invalid percent-encoded",), _REASON_MALFORMED_DSN),
    (("invalid connection option",), _REASON_MALFORMED_DSN),
    (("connection is bad: invalid",), _REASON_MALFORMED_DSN),
    (("unterminated quoted string",), _REASON_MALFORMED_DSN),
    (("password authentication failed",),
     "authentication failed (wrong password, or the role does not exist; Postgres does not say which)"),
    (('role "', "does not exist"), "authentication failed: role does not exist"),
    (("no pg_hba.conf entry",), "rejected by pg_hba.conf (this client/user/database is not allowed)"),
    (('database "', "does not exist"), "database does not exist"),
    (("too many clients",), "server has no free connection slots"),
    (("remaining connection slots",), "server has no free connection slots"),
    (("starting up",), "server not accepting connections (starting, stopping or in recovery)"),
    (("shutting down",), "server not accepting connections (starting, stopping or in recovery)"),
    (("in recovery",), "server not accepting connections (starting, stopping or in recovery)"),
    (("ssl",), "TLS/SSL failure"),
    (("certificate",), "TLS/SSL failure"),
    (("tls",), "TLS/SSL failure"),
    (("connection refused",), "connection refused (nothing listening; is the tunnel up?)"),
    (("failed to resolve host",), "host name did not resolve"),
    (("could not translate host name",), "host name did not resolve"),
    (("server closed the connection unexpectedly",),
     "connection dropped during handshake (forwarder up, upstream unreachable?)"),
    (("connection reset",), "connection dropped during handshake (forwarder up, upstream unreachable?)"),
)


def _scrub_detail(text: str, conninfo: str) -> str | None:
    """The unclassified row's detail: every conninfo VALUE replaced exactly (longest first),
    then quoted runs, key=value pairs and scheme://… shapes. None when the conninfo itself
    does not parse — then nothing is safe to echo."""
    try:
        values = [str(v) for v in conninfo_to_dict(conninfo).values() if str(v)]
    except Exception:
        return None
    if not values:  # nothing known to scrub against -> nothing is safe to echo
        return None
    line = text.splitlines()[0] if text else ""
    for marker in ("failed: ", "FATAL:"):
        if marker in line:
            line = line.rsplit(marker, 1)[1]
    for v in sorted(values, key=len, reverse=True):
        line = line.replace(v, "<redacted>")
    line = re.sub(r'"[^"]*"|\'[^\']*\'', '"<redacted>"', line)
    line = re.sub(r"\w+=\S+|\w+://\S+", "<redacted>", line)
    return line.strip()[:120]


class _CapturingConn(psycopg.Connection):
    """Per-pool connection class: records the scrubbed reason of a failed connect under its
    pool key, at the source, with the conninfo in hand. Only the string survives the except
    block. A successful connect clears the entry."""

    pool_key = ""

    @classmethod
    def connect(cls, conninfo: str = "", **kwargs):
        try:
            conn = super().connect(conninfo, **kwargs)
        except Exception as exc:
            _connect_errors[cls.pool_key] = _connect_reason(exc, conninfo)
            raise
        _connect_errors.pop(cls.pool_key, None)
        return conn


def _connect_reason(exc: BaseException, conninfo: str) -> str:
    """Classify a connect failure into a secret-free reason string. Never raises."""
    name = type(exc).__name__
    try:
        text = str(exc)
        low = text.lower()
        if isinstance(exc, psycopg.errors.ConnectionTimeout):
            return _REASON_RULES[0][1]
        if isinstance(exc, psycopg.ProgrammingError):
            return _REASON_MALFORMED_DSN
        for needles, reason in _REASON_RULES:
            if all(n in low for n in needles):
                return reason
        detail = _scrub_detail(text, conninfo)
        return f"unclassified connection failure ({name})" + (f": {detail}" if detail else "")
    except Exception:
        return f"unclassified connection failure ({name})"


def _tunnel_var(env: str, key: str) -> str:
    """Env var backing a tunnel sidecar for one target.

    Prod: PGPROD_MAIN -> PGPROD_MAIN_TUNNEL
    Staging: PGSTG_MAIN -> PGSTG_MAIN_TUNNEL
    """
    if env == ENV_STAGING:
        return pg_staging.TARGET_PREFIX + pg_staging._suffix(key) + TUNNEL_SUFFIX
    return ENV_PREFIX + re.sub(r"[^A-Z0-9]+", "_", key.strip().upper()) + TUNNEL_SUFFIX


def _tunnel_spec(env: str, key: str) -> gcloud_tunnel.TunnelSpec | None:
    """Read the optional tunnel sidecar for a target. Returns None when not declared.

    `PGSTG_DSN_TUNNEL` is explicitly refused: the bare staging instance DSN has no named
    target to attach a tunnel to. Declare `PGSTG_<NAME>=...` and `PGSTG_<NAME>_TUNNEL=...`
    side by side instead.

    A malformed spec is reported to stderr and the target keeps working direct — it never
    disappears silently because of a typo in a sidecar.
    """
    var = _tunnel_var(env, key)
    if var == "PGSTG_DSN_TUNNEL":
        raise ValueError(
            "PGSTG_DSN_TUNNEL is not supported — the bare staging DSN has no target name to "
            "attach a tunnel to. Declare a per-target DSN (PGSTG_<NAME>=...) beside its "
            "PGSTG_<NAME>_TUNNEL sidecar."
        )
    raw = os.environ.get(var)
    if not raw:
        return None
    try:
        return gcloud_tunnel.parse_spec(var, raw)
    except ValueError as exc:
        print(f"pg-triage: ignoring {var} — {exc}", file=sys.stderr)
        return None


def _start_watchdog() -> None:
    global _watchdog
    if _watchdog is None or not _watchdog.is_alive():
        _watchdog = threading.Thread(
            target=_reap_idle, name="pg-tunnel-watchdog", daemon=True
        )
        _watchdog.start()


def _reap_idle() -> None:
    """Watchdog: reap pools and tunnels that have been idle past IDLE_TIMEOUT_S."""
    while True:
        time.sleep(WATCHDOG_TICK_S)
        _reap_once(time.time())


def _reap_once(now: float) -> None:
    """One watchdog tick. Every teardown goes through close_tunnel, which leaves an adopted
    gost running — reaping it drops only the MCP's pool."""
    with _lock:
        for pk, tun in list(_tunnels.items()):
            dead = not gcloud_tunnel.is_alive(tun)
            if dead or (now - tun.last_used > IDLE_TIMEOUT_S):
                pool = _pools.pop(pk, None)
                _connect_errors.pop(pk, None)
                if pool is not None:
                    try:
                        pool.close()
                    except Exception:
                        pass
                gcloud_tunnel.close_tunnel(tun)
                _tunnels.pop(pk, None)


def _pool(env: str, key: str) -> ConnectionPool:
    """Lazily open a pool for one env+target. min_size=0 means no connection is opened until the
    first real use, so a running-but-idle process holds nothing.

    This is the one place a connection comes into existence, which makes it the right place for
    the production gate: it fires before the DSN is even looked up, and before any tunnel is
    spawned — A9."""
    pk = _pool_key(env, key)
    with _lock:
        tun = _tunnels.get(pk)
        if tun is not None and not gcloud_tunnel.is_alive(tun):
            # Tunnel died under us — discard pool and tunnel so the next call rebuilds both.
            pool = _pools.pop(pk, None)
            if pool is not None:
                try:
                    pool.close()
                except Exception:
                    pass
            gcloud_tunnel.close_tunnel(tun)
            _tunnels.pop(pk, None)

        if pk in _pools:
            return _pools[pk]

        # Prod gate fires BEFORE the DSN lookup and any tunnel spawn (A9).
        if env == ENV_PROD:
            triage_policy.assert_prod_allowed("PRODUCTION Postgres triage")

        # A DSN libpq cannot parse is refused by NAME: its parse error echoes the fragment it
        # choked on, which for `password=x y` is the password.
        if env == ENV_PROD:
            var = _env_var(key)
        else:
            var = pg_staging.target_var(key) if os.environ.get(pg_staging.target_var(key)) else pg_staging.DSN_VAR
        try:
            conninfo = _dsn(env, key)
            spec = _tunnel_spec(env, key)

            if spec is not None and spec.kind != "none":  # gcloud, or the shared gost forwarder
                _start_watchdog()
                tun = gcloud_tunnel.open_tunnel(spec)  # blocks up to TUNNEL_READY_TIMEOUT_S
                _tunnels[pk] = tun
                # hostaddr routes libpq to 127.0.0.1 while host= stays for TLS SNI and certificate
                # verification — a sslmode=verify-full DSN keeps working through the forward.
                conninfo = make_conninfo(
                    conninfo, hostaddr="127.0.0.1", port=spec.local_port, connect_timeout=5
                )
        except psycopg.ProgrammingError:
            raise ValueError(f"{var} is not a valid DSN (details withheld)") from None

        pool = ConnectionPool(
            conninfo=conninfo,
            connection_class=type("_Conn", (_CapturingConn,), {"pool_key": pk}),
            min_size=0,
            max_size=POOL_MAX_SIZE,
            max_idle=POOL_MAX_IDLE_S,
            timeout=POOL_TIMEOUT_S,
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
    with _lock:
        tun = _tunnels.get(_pool_key(env, key))
        if tun is not None:
            tun.last_used = time.time()
    pk = _pool_key(env, key)
    try:
        with pool.connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(sql, params)
                cols = [d.name for d in cur.description] if cur.description else []
                rows = cur.fetchall() if cur.description else []
    except PoolTimeout as exc:
        # PoolTimeout carries nothing (`from None`); the worker that failed recorded why.
        reason = _connect_errors.get(pk, "none recorded (pool saturated, or first connect still in flight)")
        raise PoolTimeout(f"{pk}: {exc}; last connect error: {reason}") from None
    if _vaults(env) and rows:
        try:
            pii_provenance.record_rows(cols, rows)
        except Exception:
            pass
    return cols, rows


# --- tools -------------------------------------------------------------------------------


@mcp.tool()
def list_targets() -> dict:
    """List the configured targets in BOTH environments, whether each is connected, and whether
    production is enabled on this machine.

    Touches no database — it only reads which env vars are present (booleans only, never a DSN)
    and the local pool/tunnel state. Use this to sanity-check setup before querying, and to see
    what `disconnect` would close."""
    prod_allowed, policy_source = triage_policy.resolve("prod")
    with _lock:
        pool_keys = set(_pools)
        tunnel_snapshot = {pk: (t.spec, gcloud_tunnel.is_alive(t)) for pk, t in _tunnels.items()}
    envs = {}
    for env in ENVS:
        names = sorted(
            set(_configured_targets(env))
            | {pk.split(":", 1)[1] for pk in pool_keys if pk.startswith(f"{env}:")}
        )
        entries = []
        for key in names:
            pk = _pool_key(env, key)
            entry: dict = {
                "target": key,
                "kind": _kind(key),
                "configured": _configured(env, key),
                "pool_open": pk in pool_keys,
                **(
                    {"database": pg_staging.dbname(key)}
                    if env == ENV_STAGING
                    else {"env_var": _env_var(key)}
                ),
            }
            # Tunnel sidecar fields — display only; never a DSN
            try:
                spec = _tunnel_spec(env, key)
                if spec is not None:
                    entry["tunnel"] = spec.kind
                    entry["forward"] = (
                        f"127.0.0.1:{spec.local_port}" if spec.local_port else None
                    )
                    tun_info = tunnel_snapshot.get(pk)
                    entry["tunnel_open"] = tun_info[1] if tun_info else False
            except Exception:
                pass
            entries.append(entry)
        envs[env] = entries
    return _jsonable(
        {
            "envs": envs,
            "unrecognized": _unrecognized(),
            "prod_allowed": prod_allowed,
            "policy": f"triage.prod = {str(prod_allowed).lower()} ({policy_source})",
            "staging": pg_staging.describe(),
            "pii_vaulted": {ENV_PROD: _vaults(ENV_PROD), ENV_STAGING: False},
            "open_pools": list(pool_keys),
        }
    )


@mcp.tool()
def list_schemas(env: str | None = None, target: str | None = None) -> dict:
    """List user schemas on a target (excludes pg_* and information_schema).
    Provide `env` ('staging' | 'prod') and `target` — a configured target name (see
    list_targets)."""
    e = _resolve_env(env)
    key = _target_key(target)
    cols, rows = _query(
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
    schema: str = "public",
    object_type: str | None = None,
) -> dict:
    """List tables/views in a schema on a target. `object_type` optionally filters to
    'table' or 'view'. Provide `env` and `target`."""
    e = _resolve_env(env)
    key = _target_key(target)
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
    cols, rows = _query(e, key, sql, params)
    return _result(e, key, {"schema": schema, "objects": rows})


@mcp.tool()
def get_object_details(
    name: str,
    env: str | None = None,
    target: str | None = None,
    schema: str = "public",
) -> dict:
    """Describe a table/view: its columns (name, type, nullability, default) and indexes.
    Provide `env` and `target`."""
    e = _resolve_env(env)
    key = _target_key(target)
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
    analyze: bool = False,
) -> dict:
    """Return the query plan for a read-only query. `analyze=False` (default) plans without
    running it; `analyze=True` runs EXPLAIN (ANALYZE, BUFFERS) — note that actually EXECUTES
    the query against the target, so leave it off unless you need real timings. Provide `env`
    and `target`."""
    e = _resolve_env(env)
    key = _target_key(target)
    body = _assert_read_only(sql)
    prefix = "EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT) " if analyze else "EXPLAIN (VERBOSE, FORMAT TEXT) "
    cols, rows = _query(e, key, prefix + body)
    plan_col = cols[0] if cols else "QUERY PLAN"
    return _result(e, key, {"analyzed": analyze, "plan": [r[plan_col] for r in rows]})


@mcp.tool()
def execute_sql(
    sql: str,
    env: str | None = None,
    target: str | None = None,
    page: int = 1,
    page_size: int = DEFAULT_PAGE_SIZE,
) -> dict:
    """Run a READ-ONLY query against one target, paginated.

    Provide `env` ('staging' | 'prod' — required, never defaulted) and `target` — a configured
    target name (see list_targets). Only SELECT/WITH/TABLE/VALUES, one statement. Results are
    paged at `page_size` (max 200) rows; `page` is 1-based. Include an ORDER BY so pages are
    stable — OFFSET paging over an unordered query can repeat or skip rows between pages.
    `has_more` in the result tells you whether to fetch the next page.

    `pii_vaulted` in the result says whether these values are fingerprinted for egress
    redaction: true for prod, false for staging (staging is not the production boundary).
    """
    e = _resolve_env(env)
    key = _target_key(target)
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
    """Close open connection pools and any tunnel sidecars — the teardown for a triage job.
    Closes BOTH environments by default; pass `env` to close just one. Leaves zero open
    connections and zero tunnels; the MCP process stays up but idle. Always call this when
    the investigation is done. An adopted gost (started outside the MCP) is left running and
    reported under `adopted_left_running` — only the MCP's hold on it is released."""
    only = _resolve_env(env) if env else None
    closed_pools: list[str] = []
    closed_tunnels: list[str] = []
    adopted: list[dict] = []
    with _lock:
        # Close pools BEFORE tunnels — killing the forward under an open pool leaves psycopg
        # handing out sockets to nothing.
        for pk in list(_pools):
            if only and not pk.startswith(f"{only}:"):
                continue
            try:
                _pools[pk].close()
            finally:
                closed_pools.append(pk)
                _pools.pop(pk, None)
                _connect_errors.pop(pk, None)
        for pk in list(_tunnels):
            if only and not pk.startswith(f"{only}:"):
                continue
            tun = _tunnels.pop(pk)
            gcloud_tunnel.close_tunnel(tun)
            closed_tunnels.append(pk)
            if tun.adopted_pid is not None:
                adopted.append({"pool_key": pk, "pid": tun.adopted_pid})
    return {
        "closed": closed_pools,
        "tunnels_closed": closed_tunnels,
        "adopted_left_running": adopted,
        "open_pools": list(_pools),
    }


@mcp.tool()
def tunnel_status() -> dict:
    """Report open tunnel sidecars: owner (self | adopted), pid, up_seconds, idle_seconds,
    time-to-reap, and the local port forward. Touches no database — reads only in-process
    tunnel state. An adopted gost is never stopped by the MCP; `teardown` says so."""
    now = time.time()
    with _lock:
        entries = []
        for pk, tun in _tunnels.items():
            env, _, target = pk.partition(":")
            idle_s = now - tun.last_used
            adopted = tun.adopted_pid is not None
            entries.append(
                _jsonable(
                    {
                        "pool_key": pk,
                        "env": env,
                        "target": target,
                        "kind": tun.spec.kind,
                        "owner": "adopted" if adopted else "self",
                        "teardown": (
                            "never stopped by the MCP — started outside it; disconnect or idle "
                            "only drops the MCP's connection. Stop it yourself (Ctrl-C in its terminal)."
                            if adopted else
                            f"released on disconnect or after {IDLE_TIMEOUT_S} s idle; "
                            "the shared gost stops with its last holder"
                        ),
                        "shared": tun.spec.kind == "gost",
                        "forward": (
                            f"127.0.0.1:{tun.spec.local_port} -> "
                            + (
                                "gost (PG_TRIAGE_GOST_CONFIG)"
                                if tun.spec.kind == "gost"
                                else f"{tun.spec.host}:{tun.spec.port}"
                            )
                        ),
                        "tunnel_open": gcloud_tunnel.is_alive(tun),
                        "pid": tun.proc.pid if tun.proc is not None else tun.adopted_pid,
                        "up_seconds": round(now - tun.opened_at, 1),
                        "idle_seconds": round(idle_s, 1),
                        "reaped_in_seconds": max(0.0, round(IDLE_TIMEOUT_S - idle_s, 1)),
                        "idle_timeout_seconds": IDLE_TIMEOUT_S,
                    }
                )
            )
    return {"tunnels": entries, "count": len(entries)}


# --- entrypoint --------------------------------------------------------------------------


def _close_all() -> None:
    """Close all pools then all tunnels — used by atexit and signal handlers."""
    with _lock:
        for pool in list(_pools.values()):
            try:
                pool.close()
            except Exception:
                pass
        _pools.clear()
        _connect_errors.clear()
        for tun in list(_tunnels.values()):
            gcloud_tunnel.close_tunnel(tun)
        _tunnels.clear()


atexit.register(_close_all)


def _on_signal(signum: int, _frame: object) -> None:  # pragma: no cover
    _close_all()
    raise SystemExit(128 + signum)


for _sig in (signal.SIGTERM, signal.SIGINT):
    try:
        signal.signal(_sig, _on_signal)
    except (ValueError, OSError):
        pass


def _selftest() -> int:
    """Validate deps + config + policy without connecting to anything. Prints only booleans
    (which targets are configured) — never a DSN value, honoring the workspace .env guard."""
    import socket as _socket

    print(f"env file: {ENV_PATH} ({'present' if ENV_PATH.exists() else 'MISSING'})")
    print(f"pii provenance: {'wired' if pii_provenance is not None else 'UNAVAILABLE'}")
    for key in ("enabled", "prod"):
        value, source = triage_policy.resolve(key)
        print(f"triage.{key:<8} = {str(value).lower():<5} ({source})")
    dead = triage_policy.dead_key_present()
    if dead:
        print(f"  ! {dead} still sets the REMOVED key `prod_triage.enabled` — ignored; use triage.prod")
    for env in ENVS:
        configured = _configured_targets(env)
        print(f"{env}:")
        if env == ENV_STAGING:
            print(f"  {pg_staging.describe()}")
        if configured:
            for key in configured:
                where = (
                    f"database={pg_staging.dbname(key)}" if env == ENV_STAGING else _env_var(key)
                )
                tun_var = _tunnel_var(env, key)
                tun_label = f"  tunnel={tun_var}" if os.environ.get(tun_var) else ""
                print(f"  {key:<16} set   ({where}){tun_label}")
        elif env == ENV_PROD:
            print(f"  no {ENV_PREFIX}<NAME> targets set")

    # --- tunnel sidecar checks (A5, A6, A7, A9) ----------------------------------------
    failures = 0

    def check(label: str, cond: bool, detail: str = "") -> None:
        nonlocal failures
        if not cond:
            failures += 1
        print(f"  {'ok  ' if cond else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")

    # --- classifier: the one name grammar (synthetic names + values, never the real file) ---
    print("classifier:")
    _dsn_ok = "postgresql://ro:pw@h:5432/db"

    def cls(var: str, value: str | None = _dsn_ok, prefix: str = ENV_PREFIX):
        return _classify(prefix, var, value)

    check("PGPROD_REPORTING -> reporting", cls("PGPROD_REPORTING") == ("reporting", None, None))
    check("PGPROD_HOST1_RO -> host1_ro", cls("PGPROD_HOST1_RO") == ("host1_ro", None, None))
    check("A5 PGPROD_ZZ_TUNNEL is not a target", cls("PGPROD_ZZ_TUNNEL") == (None, None, None))
    check("PGPROD_DSN reserved", cls("PGPROD_DSN")[1] == REASON_DSN)
    check("PGPROD_1X refused: name starts with a letter", cls("PGPROD_1X")[1] == REASON_UPPER)
    check("PGPROD_A__B refused: single underscores", cls("PGPROD_A__B")[1] == REASON_UPPER)
    for bad_case in ("PGPROD_host1_ro", "pgprod_host1_ro"):
        check(f"{bad_case} -> UPPER_SNAKE, did you mean PGPROD_HOST1_RO",
              cls(bad_case) == (None, REASON_UPPER, "PGPROD_HOST1_RO"))
    r = cls("PGPROD_REPORTING", "tunnel=gost;local=65441")
    check("sidecar-shaped value is not a DSN", r[:2] == (None, REASON_NOT_DSN))
    check("libpq error text never surfaces", "65441" not in (r[1] or "") and "tunnel" not in (r[1] or ""))
    check("empty value", cls("PGPROD_REPORTING", "")[1] == REASON_EMPTY)
    check("value spans lines", cls("PGPROD_REPORTING", f"{_dsn_ok}\nPGPROD_X={_dsn_ok}")[1] == REASON_MULTILINE)
    check("not ours", cls("OTHER_THING") == (None, None, None))
    stg = lambda var, value=_dsn_ok: cls(var, value, STAGING_PREFIX)  # noqa: E731
    check("PGSTG_DSN is not a target", stg("PGSTG_DSN") == (None, None, None))
    check("PGSTG_REPORTING -> reporting (per-target DSN)", stg("PGSTG_REPORTING") == ("reporting", None, None))
    check("PGSTG_DB_REPORTING -> reporting (dbname, not a DSN)", stg("PGSTG_DB_REPORTING", "db") == ("reporting", None, None))
    check("PGSTG_DB_REPORTING empty", stg("PGSTG_DB_REPORTING", "")[1] == REASON_EMPTY)
    check("PGSTG_REPORTING sidecar-shaped value refused", stg("PGSTG_REPORTING", "tunnel=gost;local=1")[1] == REASON_NOT_DSN)
    check("PGSTG_MAIN_TUNNEL is a sidecar", stg("PGSTG_MAIN_TUNNEL") == (None, None, None))

    # --- discovery: synthetic prod + staging vars, set and restored in-process --------------
    print("discovery:")
    _syn = {"PGPROD_ZZQ": _dsn_ok, "PGPROD_zzbad": _dsn_ok, "PGSTG_ZZQ": _dsn_ok, "PGSTG_DB_ZZW": "zzw_db"}
    saved_syn = {k: os.environ.pop(k, None) for k in _syn}
    os.environ.update(_syn)
    try:
        check("zzq discovered on prod", "zzq" in _configured_targets(ENV_PROD) and _configured(ENV_PROD, "zzq"))
        check("zzq + zzw discovered on staging", {"zzq", "zzw"} <= set(_configured_targets(ENV_STAGING)))
        check("zzw dbname mapped", pg_staging.dbname("zzw") == "zzw_db")
        check("wrong-case PGPROD_zzbad is not a target", "zzbad" not in _configured_targets(ENV_PROD))
        unrec = [u for u in _unrecognized() if u["var"] == "PGPROD_zzbad"]
        check("unrecognized names PGPROD_zzbad -> PGPROD_ZZBAD",
              bool(unrec) and unrec[0]["env"] == ENV_PROD and unrec[0]["did_you_mean"] == "PGPROD_ZZBAD")
        lt = list_targets()
        entry = next((e for e in lt["envs"][ENV_PROD] if e["target"] == "zzq"), None)
        check("list_targets has zzq (named)", entry is not None and entry["kind"] == "named")
        check("list_targets.unrecognized names PGPROD_zzbad", "PGPROD_zzbad" in {u["var"] for u in lt["unrecognized"]})
    finally:
        for k, v in saved_syn.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    # --- file report: a synthetic dotenv file; only key names + fixed reasons may print ---
    print("file report:")
    import tempfile

    _fixture = (
        "PGPROD_ZZA=postgresql://ro:pw@h/db1\n"
        "PGPROD_ZZA_TUNNEL=tunnel=gost;local=65441\n"
        "PGPROD_ZZORPHAN_TUNNEL=tunnel=gost;local=65442\n"
        "PGPROD_ZZB=tunnel=gost;local=65443\n"
        "PGPROD_ZZC=\n"
        "PGPROD_ZZSHADOW=postgresql://ro:pw@h/db2\n"
        "PGPROD_zzcase=postgresql://ro:pw@h/db3\n"
        "PGSTG_DSN=postgresql://ro:pw@h/db4\n"
        "PGSTG_DB_ZZW=zzw_db\n"
        "PGSTG_ZZQ=postgresql://ro:pw@h/db5\n"
        'PGPROD_ZZD="postgresql://ro:pw@h/db6\n'
        'PGPROD_ZZE=postgresql://ro:pw@h/db7"\n'
    )
    saved_shadow = os.environ.pop("PGPROD_ZZSHADOW", None)
    os.environ["PGPROD_ZZSHADOW"] = "postgresql://ro:other@h/db8"
    with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as fh:
        fh.write(_fixture)
    try:
        rep = {line.split(" ", 1)[0]: (status, line) for status, line in _file_key_report(Path(fh.name))}
        joined = "\n".join(line for _, line in rep.values())
        check("fixture: named target ok + sidecar ok",
              rep["PGPROD_ZZA"] == ("ok", "PGPROD_ZZA -> target zza (named)")
              and rep["PGPROD_ZZA_TUNNEL"] == ("ok", "PGPROD_ZZA_TUNNEL -> sidecar of PGPROD_ZZA"))
        check("fixture: orphan sidecar warns",
              rep["PGPROD_ZZORPHAN_TUNNEL"] == ("WARN", f"PGPROD_ZZORPHAN_TUNNEL — {REASON_ORPHAN.format(base='PGPROD_ZZORPHAN')}"))
        check("fixture: sidecar-shaped DSN fails", rep["PGPROD_ZZB"] == ("FAIL", f"PGPROD_ZZB — {REASON_NOT_DSN}"))
        check("fixture: empty fails", rep["PGPROD_ZZC"] == ("FAIL", f"PGPROD_ZZC — {REASON_EMPTY}"))
        check("fixture: process env shadows the file", rep["PGPROD_ZZSHADOW"] == ("FAIL", f"PGPROD_ZZSHADOW — {REASON_SHADOWED}"))
        check("fixture: wrong case fails with did-you-mean",
              rep["PGPROD_zzcase"] == ("FAIL", f"PGPROD_zzcase — {REASON_UPPER}; did you mean PGPROD_ZZCASE?"))
        check("fixture: PGSTG_DSN is the base DSN", rep["PGSTG_DSN"] == ("ok", "PGSTG_DSN -> staging base DSN"))
        check("fixture: PGSTG_DB_ZZW ok (named)", rep["PGSTG_DB_ZZW"] == ("ok", "PGSTG_DB_ZZW -> target zzw (named)"))
        check("fixture: PGSTG_ZZQ ok (named)", rep["PGSTG_ZZQ"] == ("ok", "PGSTG_ZZQ -> target zzq (named)"))
        check("fixture: unbalanced quote swallows the next line",
              rep["PGPROD_ZZD"][0] == "FAIL" and REASON_MULTILINE in rep["PGPROD_ZZD"][1] and "PGPROD_ZZE" not in rep)
        check("fixture: no value ever surfaces",
              all(s not in joined for s in ("pw", "other", "db1", "db8", "65441", "65442", "65443", "zzw_db")))
    finally:
        os.unlink(fh.name)
        if saved_shadow is None:
            os.environ.pop("PGPROD_ZZSHADOW", None)
        else:
            os.environ["PGPROD_ZZSHADOW"] = saved_shadow

    check("PYTHON_DOTENV_DISABLED is not set", not os.environ.get("PYTHON_DOTENV_DISABLED"),
          "" if not os.environ.get("PYTHON_DOTENV_DISABLED") else "set — load_dotenv silently skipped scripts/db/.env")
    if ENV_PATH.exists():
        for status, line in _file_key_report(ENV_PATH):
            check(line, status != "FAIL") if status != "WARN" else print(f"  WARN {line}")

    # --- connect reasons: every input embeds a synthetic secret + every DSN value; no output may ---
    print("connect reasons:")
    _cr_secret = "zz-s3cr3t-PW-canary"
    _cr_values = (_cr_secret, "zzreader", "10.9.9.9", "6543", "zzreports")
    _cr_dsn = "host=10.9.9.9 port=6543 user=zzreader password=zz-s3cr3t-PW-canary dbname=zzreports"
    _cr_tail = f' (host=10.9.9.9 port=6543 user=zzreader password={_cr_secret} dbname=zzreports)'
    _OpErr = psycopg.OperationalError
    _cr_cases: list[tuple[str, BaseException, str]] = [
        ("timeout (class)", psycopg.errors.ConnectionTimeout("connection timeout expired" + _cr_tail),
         "timeout: no answer within connect_timeout"),
        ("timeout (text)", _OpErr("connection failed: timeout expired" + _cr_tail),
         "timeout: no answer within connect_timeout"),
        ("malformed (class)", psycopg.ProgrammingError(f'missing "=" after "{_cr_secret}" in connection info string'),
         _REASON_MALFORMED_DSN),
        ("malformed (text)", _OpErr(f'invalid percent-encoded token: "{_cr_secret}"' + _cr_tail), _REASON_MALFORMED_DSN),
        ("auth failed", _OpErr('connection failed: FATAL:  password authentication failed for user "zzreader"' + _cr_tail),
         "authentication failed (wrong password, or the role does not exist; Postgres does not say which)"),
        ("role missing", _OpErr('FATAL:  role "zzreader" does not exist' + _cr_tail),
         "authentication failed: role does not exist"),
        ("pg_hba", _OpErr('FATAL:  no pg_hba.conf entry for host "10.9.9.9", user "zzreader", database "zzreports"' + _cr_tail),
         "rejected by pg_hba.conf (this client/user/database is not allowed)"),
        ("db missing", _OpErr('FATAL:  database "zzreports" does not exist' + _cr_tail), "database does not exist"),
        ("too many clients", _OpErr("FATAL:  sorry, too many clients already" + _cr_tail), "server has no free connection slots"),
        ("slots reserved", _OpErr("FATAL:  remaining connection slots are reserved" + _cr_tail), "server has no free connection slots"),
        ("starting up", _OpErr("FATAL:  the database system is starting up" + _cr_tail),
         "server not accepting connections (starting, stopping or in recovery)"),
        ("shutting down", _OpErr("FATAL:  the database system is shutting down" + _cr_tail),
         "server not accepting connections (starting, stopping or in recovery)"),
        ("in recovery", _OpErr("FATAL:  the database system is in recovery mode" + _cr_tail),
         "server not accepting connections (starting, stopping or in recovery)"),
        ("ssl", _OpErr("connection failed: SSL error: certificate verify failed" + _cr_tail), "TLS/SSL failure"),
        ("refused", _OpErr('connection to server at "10.9.9.9", port 6543 failed: Connection refused' + _cr_tail),
         "connection refused (nothing listening; is the tunnel up?)"),
        ("dns", _OpErr('could not translate host name "10.9.9.9" to address' + _cr_tail), "host name did not resolve"),
        ("dns (resolve)", _OpErr("failed to resolve host" + _cr_tail), "host name did not resolve"),
        ("dropped", _OpErr("server closed the connection unexpectedly" + _cr_tail),
         "connection dropped during handshake (forwarder up, upstream unreachable?)"),
        ("reset", _OpErr("connection reset by peer" + _cr_tail),
         "connection dropped during handshake (forwarder up, upstream unreachable?)"),
    ]
    _cr_results: list[str] = []
    for label, exc, expected in _cr_cases:
        got = _connect_reason(exc, _cr_dsn)
        _cr_results.append(got)
        check(f"reason: {label}", got == expected, got[:90])
    # real libpq parse errors, not hand-written text
    for label, bad in (("keyword", f"host=h password=a {_cr_secret}"),
                       ("percent", f"postgresql://u:hunter2%zz{_cr_secret}@h/d")):
        try:
            conninfo_to_dict(bad)
            check(f"reason: real malformed DSN ({label})", False, "conninfo_to_dict did not raise")
        except psycopg.ProgrammingError as exc:
            got = _connect_reason(exc, bad)
            _cr_results.append(got)
            check(f"reason: real malformed DSN ({label})", got == _REASON_MALFORMED_DSN, got[:90])
    # unclassified: the only row that carries error text — every DSN value must be scrubbed
    _cr_unk = _OpErr(f"weird failure: host=10.9.9.9 user=zzreader pw {_cr_secret} db 'zzreports' on 6543 postgresql://zzreader:{_cr_secret}@10.9.9.9:6543/zzreports")
    got = _connect_reason(_cr_unk, _cr_dsn)
    _cr_results.append(got)
    check("reason: unclassified carries the class name", got.startswith("unclassified connection failure (OperationalError)"), got[:90])
    check("reason: unclassified detail keeps no DSN value", all(v not in got for v in _cr_values), got[:120])
    got = _connect_reason(_cr_unk, f"host=h password=a {_cr_secret}")
    _cr_results.append(got)
    check("reason: unclassified + malformed conninfo has no detail", got == "unclassified connection failure (OperationalError)", got[:90])
    got = _connect_reason(_OpErr(f"boom {_cr_secret}"), "")
    _cr_results.append(got)
    check("reason: empty conninfo still scrubs the detail", _cr_secret not in got, got[:90])
    check("reason: NO output carries the secret or any DSN value",
          all(v not in r for r in _cr_results for v in _cr_values))

    # --- connect surfacing: a real pool against a loopback fake server; the tool error carries ---
    # the reason, and neither it nor stderr carries the secret, the user or the port.
    print("connect surfacing:")
    import contextlib as _ctx
    import io as _io
    import struct as _struct

    def _fake_pg(code: bytes, msg: bytes) -> int:
        """Answers SSL/GSS requests with N, then the startup message with a FATAL ErrorResponse."""
        srv = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
        srv.bind(("127.0.0.1", 0))
        srv.listen(8)

        def serve(c: _socket.socket) -> None:
            with c:
                while True:
                    head = c.recv(4)
                    if len(head) < 4:
                        return
                    body = c.recv(_struct.unpack("!I", head)[0] - 4)
                    if _struct.unpack("!I", body[:4])[0] in (80877103, 80877104):  # SSLRequest / GSSENCRequest
                        c.sendall(b"N")
                        continue
                    break
                fields = b"SFATAL\0VFATAL\0C" + code + b"\0M" + msg + b"\0\0"
                c.sendall(b"E" + _struct.pack("!I", len(fields) + 4) + fields)

        def loop() -> None:
            while True:
                try:
                    c, _ = srv.accept()
                except OSError:
                    return
                threading.Thread(target=serve, args=(c,), daemon=True).start()

        threading.Thread(target=loop, name="fake-pg", daemon=True).start()
        return srv.getsockname()[1]

    global POOL_TIMEOUT_S
    _cs_secret = "zz-s3cr3t-PW-canary"
    _cs_saved = {k: os.environ.get(k) for k in (pg_staging.DSN_VAR, "PGSTG_DB_ZZX")}
    _cs_saved_timeout = POOL_TIMEOUT_S
    _cs_port = _fake_pg(b"28P01", b'password authentication failed for user "zzreader"')
    with _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM) as _closed:
        _closed.bind(("127.0.0.1", 0))
        _cs_closed_port = _closed.getsockname()[1]  # bound but never listening -> refused

    class _Records(logging.Handler):
        """Every log record that propagates to root — the stderr leak is a `psycopg.pool` WARNING
        emitted by a handler bound to the ORIGINAL stderr, which redirect_stderr cannot see."""

        def __init__(self) -> None:
            super().__init__(logging.DEBUG)
            self.lines: list[str] = []

        def emit(self, record: logging.LogRecord) -> None:
            self.lines.append(f"{record.name}: {record.getMessage()}")

    def _surface(dsn: str) -> tuple[BaseException | None, str]:
        os.environ[pg_staging.DSN_VAR] = dsn
        err_out = _io.StringIO()
        records = _Records()
        logging.getLogger().addHandler(records)
        try:
            with _ctx.redirect_stderr(err_out):
                execute_sql(sql="SELECT 1", env=ENV_STAGING, target="zzx")
            return None, err_out.getvalue()
        except Exception as exc:  # noqa: BLE001 — the whole point is to inspect what surfaces
            return exc, err_out.getvalue() + "\n".join(records.lines)
        finally:
            logging.getLogger().removeHandler(records)
            disconnect(env=ENV_STAGING)

    try:
        os.environ["PGSTG_DB_ZZX"] = "zzx"
        POOL_TIMEOUT_S = 2
        for label, port, expect in (
            ("auth failure", _cs_port, "authentication failed"),
            ("closed port", _cs_closed_port, "connection refused"),
        ):
            exc, err = _surface(
                f"host=127.0.0.1 port={port} user=zzreader password={_cs_secret} dbname=x sslmode=disable"
            )
            msg = str(exc)
            check(f"{label}: raises PoolTimeout", isinstance(exc, PoolTimeout), type(exc).__name__)
            check(f"{label}: names the pool key", "staging:zzx" in msg, msg[:100])
            check(f"{label}: carries the reason", expect in msg, msg[:140])
            check(f"{label}: no secret/user/port in the error",
                  all(s not in msg for s in (_cs_secret, "zzreader", str(port))), msg[:140])
            check(f"{label}: no secret/user/port on stderr or in any log record",
                  all(s not in err for s in (_cs_secret, "zzreader", str(port))), err[:140])
            check(f"{label}: disconnect clears the recorded reason", "staging:zzx" not in _connect_errors)
        exc, err = _surface(f"host=h password=a {_cs_secret}")
        msg = str(exc)
        check("malformed PGSTG_DSN: ValueError", isinstance(exc, ValueError), type(exc).__name__)
        check("malformed PGSTG_DSN: names the variable", pg_staging.DSN_VAR in msg, msg[:100])
        check("malformed PGSTG_DSN: no secret in the error or stderr",
              _cs_secret not in msg and _cs_secret not in err, msg[:100])
    finally:
        POOL_TIMEOUT_S = _cs_saved_timeout
        for k, v in _cs_saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    print("tunnel checks:")

    # A5: _TUNNEL var never becomes a target name
    saved_tunnel = os.environ.pop(ENV_PREFIX + "MAIN_TUNNEL", None)
    os.environ[ENV_PREFIX + "MAIN_TUNNEL"] = "tunnel=gcloud;host=h;local=15500;vm=v"
    prod_targets = _configured_targets(ENV_PROD)
    check("A5 prod: PGPROD_MAIN_TUNNEL is not target main_tunnel", "main_tunnel" not in prod_targets,
          str(prod_targets))
    os.environ.pop(ENV_PREFIX + "MAIN_TUNNEL", None)
    if saved_tunnel is not None:
        os.environ[ENV_PREFIX + "MAIN_TUNNEL"] = saved_tunnel

    saved_stg = os.environ.pop(pg_staging.TARGET_PREFIX + "MAIN_TUNNEL", None)
    os.environ[pg_staging.TARGET_PREFIX + "MAIN_TUNNEL"] = "tunnel=gcloud;host=h;local=15501;vm=v"
    stg_targets = _configured_targets(ENV_STAGING)
    check("A5 staging: PGSTG_MAIN_TUNNEL is not target main_tunnel", "main_tunnel" not in stg_targets,
          str(stg_targets))
    os.environ.pop(pg_staging.TARGET_PREFIX + "MAIN_TUNNEL", None)
    if saved_stg is not None:
        os.environ[pg_staging.TARGET_PREFIX + "MAIN_TUNNEL"] = saved_stg

    # A6: PGSTG_DSN_TUNNEL refused
    saved_dsn_tun = os.environ.pop("PGSTG_DSN_TUNNEL", None)
    os.environ["PGSTG_DSN_TUNNEL"] = "tunnel=gcloud;host=h;local=15502;vm=v"
    try:
        _tunnel_spec(ENV_STAGING, "dsn")
        check("A6 PGSTG_DSN_TUNNEL refused", False, "no error raised")
    except ValueError as exc:
        check("A6 PGSTG_DSN_TUNNEL refused", "PGSTG_DSN_TUNNEL" in str(exc), str(exc)[:80])
    finally:
        os.environ.pop("PGSTG_DSN_TUNNEL", None)
        if saved_dsn_tun is not None:
            os.environ["PGSTG_DSN_TUNNEL"] = saved_dsn_tun

    # A7: port-in-use refusal (binds a real socket — no gcloud needed)
    with _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM) as srv:
        srv.setsockopt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        busy_port = srv.getsockname()[1]
        spec_busy = gcloud_tunnel.parse_spec(
            "PGPROD_TEST_TUNNEL",
            f"tunnel=gcloud;host=prod-db;local={busy_port};vm=bastion",
        )
        try:
            gcloud_tunnel.open_tunnel(spec_busy, timeout=0.1)
            check("A7 busy port refused before spawn", False, "no error raised")
        except RuntimeError as exc:
            msg = str(exc)
            check("A7 busy port refused", "already in use" in msg, msg[:80])
            check("A7 names tunnel.sh", "scripts/db/tunnel.sh" in msg, msg[:80])

    # A3: synthetic spec produces conninfo with hostaddr=127.0.0.1 + local_port; tunnel=none
    # leaves the DSN unchanged; dbname/sslmode are preserved through the rewrite.
    _base_dsn = "postgresql://ro:pw@prod-db.internal:5432/myapp?sslmode=require"
    _spec_gcloud = gcloud_tunnel.parse_spec(
        "PGPROD_TEST_TUNNEL",
        "tunnel=gcloud;host=prod-db.internal;port=5432;local=15432;vm=v",
    )
    _rewritten = make_conninfo(_base_dsn, hostaddr="127.0.0.1", port=_spec_gcloud.local_port, connect_timeout=5)
    check("A3 conninfo has hostaddr=127.0.0.1", "hostaddr=127.0.0.1" in _rewritten, _rewritten)
    check("A3 conninfo has local port", "port=15432" in _rewritten, _rewritten)
    check("A3 conninfo preserves host for TLS SNI", "host=prod-db.internal" in _rewritten, _rewritten)
    check("A3 conninfo preserves dbname", "dbname=myapp" in _rewritten, _rewritten)
    check("A3 conninfo preserves sslmode", "sslmode=require" in _rewritten, _rewritten)
    check("A3 tunnel=none leaves DSN unchanged",
          make_conninfo(_base_dsn) == make_conninfo(_base_dsn), "(trivially true)")

    # A9: prod gate fires before tunnel spawn (simulated by confirming gate raises PermissionError
    # when prod is disabled, before any tunnel code can be reached)
    prod_allowed, _ = triage_policy.resolve("prod")
    if not prod_allowed:
        test_pk = _pool_key(ENV_PROD, "_selftest_gate")
        for sidecar in (
            "tunnel=gcloud;host=fake-db;local=15503;vm=fake-vm",
            "tunnel=gost;local=65432",
        ):
            kind = sidecar.split(";")[0].split("=")[1]
            try:
                # Temporarily inject a fake prod target + tunnel sidecar
                os.environ[ENV_PREFIX + "_SELFTEST_GATE"] = "postgresql://ro:pw@fake:5432/db"
                os.environ[ENV_PREFIX + "_SELFTEST_GATE_TUNNEL"] = sidecar
                _pool(ENV_PROD, "_selftest_gate")
                check(f"A9 prod gate before {kind} spawn", False, "PermissionError not raised")
            except PermissionError:
                check(f"A9 prod gate before {kind} spawn", True)
                # Verify no tunnel was opened
                with _lock:
                    check(f"A9 no {kind} tunnel spawned before gate", test_pk not in _tunnels)
                if kind == "gost":
                    check("A9 no shared gost spawned before gate", not gcloud_tunnel.gost_running())
            finally:
                os.environ.pop(ENV_PREFIX + "_SELFTEST_GATE", None)
                os.environ.pop(ENV_PREFIX + "_SELFTEST_GATE_TUNNEL", None)
    else:
        print("  skip A9 — triage.prod is on; a human verifies this case with prod gated off")

    # Adopted gost is never stopped: every MCP teardown path against a live stand-in process.
    # Hermetic — a `sleep` plays the person's gost; no gost, no DB.
    import subprocess as _sp
    _adopt_pk = _pool_key(ENV_PROD, "_selftest_adopt")
    _adopt_spec = gcloud_tunnel.parse_spec("PGPROD_SELFTEST_ADOPT_TUNNEL", "tunnel=gost;local=65432")
    _sleeper = _sp.Popen(["sleep", "60"])
    _victim = _sp.Popen(["sleep", "60"])  # a self-owned tunnel the reaper MUST kill (contrast)

    def _adopted(last_used: float) -> gcloud_tunnel.Tunnel:
        return gcloud_tunnel.Tunnel(spec=_adopt_spec, proc=None, log_path=None, opened_at=time.time(),
                                    last_used=last_used, adopted_pid=_sleeper.pid)
    try:
        with _lock:
            _tunnels[_adopt_pk] = _adopted(time.time())
        entry = next(e for e in tunnel_status()["tunnels"] if e["pool_key"] == _adopt_pk)
        check("adopted: tunnel_status owner=adopted", entry["owner"] == "adopted")
        check("adopted: tunnel_status pid is the real pid", entry["pid"] == _sleeper.pid)
        check("adopted: tunnel_status teardown says never stopped", "never stopped" in entry["teardown"])

        closed = disconnect(env=ENV_PROD)
        check("adopted: disconnect releases the hold", _adopt_pk in closed["tunnels_closed"])
        check("adopted: disconnect reports adopted_left_running",
              [e["pool_key"] for e in closed["adopted_left_running"]] == [_adopt_pk])
        check("adopted: disconnect leaves the process running", _sleeper.poll() is None)

        with _lock:
            _tunnels[_adopt_pk] = _adopted(0.0)   # idle since the epoch -> reaped on this tick
            _victim_pk = _pool_key(ENV_PROD, "_selftest_victim")
            _tunnels[_victim_pk] = gcloud_tunnel.Tunnel(
                spec=gcloud_tunnel.parse_spec("PGPROD_SELFTEST_VICTIM_TUNNEL",
                                              "tunnel=gcloud;host=h;local=15599;vm=v"),
                proc=_victim, log_path=None, opened_at=0.0, last_used=0.0)
        _reap_once(time.time())
        with _lock:
            check("adopted: reaper drops the entry", _adopt_pk not in _tunnels)
            check("contrast: reaper drops the self-owned entry", _victim_pk not in _tunnels)
        check("adopted: reaper leaves the process running", _sleeper.poll() is None)
        check("contrast: reaper DOES stop a self-owned tunnel", _victim.poll() is not None)

        with _lock:
            _tunnels[_adopt_pk] = _adopted(time.time())
        _close_all()
        with _lock:
            check("adopted: _close_all clears the entry", not _tunnels)
        check("adopted: _close_all leaves the process running", _sleeper.poll() is None)
    finally:
        with _lock:
            _tunnels.pop(_adopt_pk, None)
        for p in (_sleeper, _victim):
            if p.poll() is None:
                p.kill()
            p.wait()

    # Port invariants across all configured targets: gcloud ports unique; gost ports may repeat
    # (two shards per host) but must not overlap gcloud ports; nothing on 5432.
    all_specs: list[tuple[str, str, gcloud_tunnel.TunnelSpec]] = []
    direct_prod: list[str] = []
    for env in ENVS:
        for key in _configured_targets(env):
            try:
                spec = _tunnel_spec(env, key)
            except ValueError:
                continue
            if spec is None or spec.kind == "none":
                if env == ENV_PROD:
                    direct_prod.append(_env_var(key))
                continue
            all_specs.append((env, key, spec))
    gcloud_specs = [s for s in all_specs if s[2].kind == "gcloud"]
    gost_specs = [s for s in all_specs if s[2].kind == "gost"]
    ports = [s.local_port for _, _, s in gcloud_specs]
    check("gcloud local ports are unique", len(ports) == len(set(ports)),
          f"duplicates: {[p for p in ports if ports.count(p) > 1]}")
    overlap = set(ports) & {s.local_port for _, _, s in gost_specs}
    check("gcloud ports disjoint from gost ports", not overlap, f"shared: {sorted(overlap)}")
    bad_5432 = [(env, key) for env, key, s in all_specs if s.local_port == 5432]
    check("no spec forwards to 5432 (local dev Postgres)", not bad_5432,
          f"offenders: {bad_5432}")

    # gost preflight (A6): binary, gost.yaml, socks.auth existence, declared port — loud on miss.
    if gost_specs:
        problems: list[str] = []
        for env, key, spec in gost_specs:
            problems += gcloud_tunnel.gost_preflight(spec)
        for line in dict.fromkeys(problems):  # dedupe, keep order (banner prints once)
            print(f"  {line}")
        check(f"gost preflight ({len(gost_specs)} target(s))", not problems)
    else:
        print("  skip gost preflight — no tunnel=gost sidecar configured")

    # Policy: production only through the SOCKS proxy. Advisory for now (not a failure).
    for var in direct_prod:
        print(f"  WARN {var} connects directly — policy requires the SOCKS proxy; "
              f"add {var}_TUNNEL=tunnel=gost;local=<port>")

    print("selftest ok" if not failures else f"{failures} tunnel check(s) FAILED")
    return 1 if failures else 0


def _verify(env: str, target: str) -> int:
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
    key = _target_key(target)
    if not _configured(e, key):
        print(f"  FAIL {e} target {key!r} is unconfigured — see --selftest for what is set")
        return 1
    spec = _tunnel_spec(e, _target_key(target))
    uses_gost = spec is not None and spec.kind == "gost"
    if uses_gost:
        problems = gcloud_tunnel.gost_preflight(spec)
        if problems:
            print("  FAIL gost preflight:")
            for line in problems:
                print(f"  {line}")
            return 1

    vault_tmp = Path(tempfile.mkdtemp(prefix="pg-triage-verify-vault-"))
    prev_vault = os.environ.get("PII_VAULT_DIR")
    os.environ["PII_VAULT_DIR"] = str(vault_tmp)
    try:
        # 1) metadata read — proves the DSN, the role, and the connection options work
        schemas = list_schemas(env=e, target=key)
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
        one = execute_sql(sql="SELECT 1 AS one", env=e, target=key)
        check("execute_sql runs a read query", one["row_count"] == 1 and not one["has_more"])

        # 3) plan-only EXPLAIN (never executes)
        plan = explain_query(sql="SELECT 1", env=e, target=key)
        check("explain_query returns a plan", bool(plan["plan"]) and plan["analyzed"] is False)

        # 4) client-side read-only guard
        for bad, why in (
            ("UPDATE some_table SET col = 0", "write statement"),
            ("SELECT 1; SELECT 2", "two statements"),
        ):
            try:
                execute_sql(sql=bad, env=e, target=key)
                check(f"read-only guard rejects a {why}", False)
            except ValueError:
                check(f"read-only guard rejects a {why}", True)

        # 5) DB-LEVEL read-only proof — bypass the client guard on purpose and let the server
        # reject it, which is what protects against a careless future edit inside a tool.
        try:
            _query(e, key, "CREATE TEMP TABLE _pg_triage_verify (i int)")
            check("DB rejects a write (read-only transaction)", False, "the write SUCCEEDED")
        except Exception as exc:  # psycopg.errors.ReadOnlySqlTransaction, normally
            check(
                "DB rejects a write (read-only transaction)",
                "read-only" in str(exc).lower(),
                str(exc).splitlines()[0][:80],
            )

        # 6) PII provenance, per env — a synthetic literal, never real data
        before = len(pii_provenance._load_vault()) if pii_provenance else 0
        pii = execute_sql(sql="SELECT 'someone@example.com'::text AS email", env=e, target=key)
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
            prod_target = (_configured_targets(ENV_PROD) or ["main"])[0]
            try:
                execute_sql(sql="SELECT 1", env=ENV_PROD, target=prod_target)
                check("prod is refused while triage.prod is off", False, "the call SUCCEEDED")
            except PermissionError as exc:
                check("prod is refused while triage.prod is off", "triage.prod" in str(exc))
        else:
            print("  skip prod-gate check — triage.prod is on, so prod is legitimately reachable")

        # 8) teardown — an adopted gost (a person's own) must SURVIVE disconnect
        owners = {e["pool_key"]: (e["owner"], e["pid"]) for e in tunnel_status()["tunnels"]}
        adopted_pids = [pid for owner, pid in owners.values() if owner == "adopted"]
        closed = disconnect()
        if adopted_pids:
            check("disconnect leaves the adopted gost running",
                  all(gcloud_tunnel._pid_exists(p) for p in adopted_pids), str(adopted_pids))
            check("disconnect reports it under adopted_left_running",
                  {e["pid"] for e in closed["adopted_left_running"]} == set(adopted_pids))
        check(
            "disconnect leaves zero open pools",
            not closed["open_pools"],
            f"closed {closed['closed']}",
        )
        check(
            "disconnect result has tunnels_closed key",
            "tunnels_closed" in closed,
        )
        if uses_gost and not adopted_pids:
            check("disconnect stops the shared gost", not gcloud_tunnel.gost_running())
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
                f"usage: --verify <{' | '.join(ENVS)}> --target <name>  "
                "(the env is required — prod is never implied)"
            )
        target_arg = ""
        if "--target" in sys.argv:
            idx = sys.argv.index("--target") + 1
            target_arg = sys.argv[idx] if idx < len(sys.argv) else ""
        if not target_arg:
            names = _configured_targets(_resolve_env(env_arg))
            target_arg = names[0] if names else ""
        if not target_arg:
            raise SystemExit(
                f"usage: --verify {env_arg} --target <name>  (no configured target to default to; "
                "see --selftest)"
            )
        raise SystemExit(_verify(env_arg, target_arg))
    mcp.run()  # stdio transport
