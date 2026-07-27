# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "mcp>=1.2",
#   "redis>=5.0",
#   "python-dotenv>=1.0",
# ]
# ///
"""redis-triage — on-demand, READ-ONLY MCP over your PRODUCTION (and staging) Redis.

One MCP process, as many targets as you configure. Which Redis a tool touches is chosen *per
call* by a `target` argument — never baked into the process, and never defaulted, so a
production target is only ever reached by naming it.

Targets are declared in `scripts/redis/.env`, one variable per target (see `.env.example`):

  REDISPROD_<NAME>=host=<addr>;port=6379;local=<port>;prod=<bool>;tunnel=gcloud;vm=<vm>;zone=<zone>

addressed as `target="<name>"`. `prod=true` turns on credential masking + PII provenance for
that target; `prod=false` (a staging box) returns values as-is.

A managed Redis is usually not reachable from a laptop, so with `tunnel=gcloud` this server
OWNS the SSH port-forward: it spawns `gcloud compute ssh <vm> --zone=<zone> -- -N -L
<local>:<host>:<port>` lazily on the first call for that target and kills it on teardown. That
placement is deliberate — the agent never needs a `gcloud` Bash grant, so it can never turn
`-- -N -L` into `-- <command>` and get a shell on the production VM. Use `tunnel=none` when the
host is already reachable (a bastion you run yourself, a VPN, a local port-forward).

Safety, and why it is shaped this way. Redis has no read-only role and no read-only
transaction, and a managed Redis commonly exposes neither an ACL user you can scope to
`+@read` nor a read-only replica — so unlike pg_triage_mcp.py, whose guarantee is a read-only DB
role, EVERY layer here is client-side. (If your Redis DOES offer an ACL user or a replica, point
the target at it: that is a real server-side guarantee and strictly better than these.)
That means the layers are the guarantee, not a convenience:

  1. Typed read tools only. There is no `execute_command` passthrough, so an arbitrary
     command string never reaches Redis. A read-looking command that actually writes
     (GETDEL, GETEX, SPOP, LPOP, SORT..STORE, XREADGROUP, XAUTOCLAIM, EVAL, MIGRATE,
     RESTORE, COPY, SWAPDB) simply has no route to the wire.
  2. A `_ReadOnly` client proxy whose allow-list is checked at attribute access, so even a
     careless future edit inside a tool cannot call `.set`/`.delete`/`.xadd`.
  3. `--selftest` scans this file's own source for write-command call sites — the regression
     guard for 1 and 2.
  4. Availability guards, because on a single-threaded server an O(N) read is an outage:
     no KEYS at all (SCAN with a bounded iteration budget instead), a cardinality check
     before any bulk read, 200 items per page, and a 15s socket timeout.
  5. Secret masking at the source (PROD ONLY): a value that is a credential by key name or
     by shape comes back as `<redis-secret:sha8>`, so a live session/agent token never
     enters the transcript. Staging returns raw values — staging is not the prod boundary.
  6. Prod values are fingerprinted into the PII provenance vault (scripts/lib/pii_provenance.py)
     so the tracker / notify adapters redact exactly those values at egress. Staging is
     never vaulted, so identical-looking staging or local data stays untouched.
  7. The tunnel closes itself. A watchdog kills any tunnel idle for IDLE_TIMEOUT_S; the
     `disconnect` tool closes on demand; atexit/SIGTERM close on exit. "Must disconnect when
     done" is therefore mechanical rather than remembered.
"""

from __future__ import annotations

import atexit
import hashlib
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

import redis
from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP

# Value-exact PII provenance. Every value a PROD target hands back came from production by
# definition, so it is vaulted as a keyed hash — that record is what lets the tracker/notify
# adapters redact exactly those values from a ticket or Slack post while leaving
# identical-looking staging/local data alone.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import triage_policy  # noqa: E402  — the production gate; load-bearing, so never optional

try:
    import pii_provenance
except Exception:  # provenance is a safety net; a missing module must not break triage
    pii_provenance = None  # type: ignore[assignment]

# --- targets ------------------------------------------------------------------------------
# Declared in scripts/redis/.env, parsed by THIS process — so host names, VM names and the
# tunnel shape never pass through the agent, the MCP config, or the transcript. A machine with
# no .env has no targets, which is the per-machine opt-in.


@dataclass(frozen=True)
class Target:
    key: str
    remote_host: str
    remote_port: int
    local_port: int
    is_prod: bool
    tunnel: str  # "gcloud" | "none"
    vm: str
    zone: str


# REDIS_TRIAGE_ENV overrides the file (a test fixture, or a shared location) — the variables it
# declares can also be exported directly, in which case no file is needed at all.
ENV_PATH = Path(os.environ.get("REDIS_TRIAGE_ENV") or Path(__file__).parent / ".env")
load_dotenv(ENV_PATH)  # no-op when absent; targets then simply report as unconfigured

TARGET_PREFIX = "REDISPROD_"


def _parse_target(name: str, spec: str) -> Target:
    """Parse one `REDISPROD_<NAME>` spec: `key=value` pairs separated by `;`."""
    kv: dict[str, str] = {}
    for part in spec.split(";"):
        part = part.strip()
        if not part:
            continue
        k, _, v = part.partition("=")
        kv[k.strip().lower()] = v.strip()
    host = kv.get("host") or kv.get("remote") or ""
    if not host:
        raise ValueError(f"{TARGET_PREFIX}{name.upper()} has no host=")
    local = int(kv.get("local") or kv.get("local_port") or 0)
    if not local:
        raise ValueError(f"{TARGET_PREFIX}{name.upper()} has no local=<port> to forward to")
    tunnel = (kv.get("tunnel") or "gcloud").lower()
    if tunnel not in ("gcloud", "none"):
        raise ValueError(f"{TARGET_PREFIX}{name.upper()} tunnel={tunnel!r}; use gcloud|none")
    if tunnel == "gcloud" and not kv.get("vm"):
        raise ValueError(f"{TARGET_PREFIX}{name.upper()} needs vm=<instance> for tunnel=gcloud")
    return Target(
        key=name.lower(),
        remote_host=host,
        remote_port=int(kv.get("port") or 6379),
        local_port=local,
        is_prod=(kv.get("prod") or "true").lower() in ("true", "yes", "1"),
        tunnel=tunnel,
        vm=kv.get("vm") or "",
        zone=kv.get("zone") or "",
    )


def _load_targets() -> dict[str, Target]:
    out: dict[str, Target] = {}
    for var, spec in os.environ.items():
        if not var.startswith(TARGET_PREFIX) or not spec.strip():
            continue
        name = var[len(TARGET_PREFIX):]
        try:
            t = _parse_target(name, spec)
        except ValueError as exc:  # a broken line must name itself, not disappear
            print(f"redis-triage: ignoring {var} — {exc}", file=sys.stderr)
            continue
        out[t.key] = t
    return out


TARGETS: dict[str, Target] = _load_targets()

IDLE_TIMEOUT_S = 120  # no tool call for this long -> the tunnel is killed
WATCHDOG_TICK_S = 10
TUNNEL_READY_TIMEOUT_S = 45
SOCKET_TIMEOUT_S = 15
MAX_PAGE = 200
BULK_CARDINALITY_LIMIT = 1000  # above this, a bulk read is refused in favour of a cursor
SCAN_MAX_ITERATIONS = 10
SCAN_DEFAULT_COUNT = 500

mcp = FastMCP("redis-triage")


def _resolve(target: str | None) -> Target:
    """Resolve a target name. There is NO default: an unnamed target is an error, never a
    guess, so prod is only ever reached by asking for it explicitly."""
    names = " | ".join(sorted(TARGETS)) or "(none configured — see scripts/redis/.env.example)"
    if not target:
        raise ValueError(f"provide `target` ({names}) — there is no default, so a production target is never implied")
    t = target.strip().lower()
    if t not in TARGETS:
        raise ValueError(f"unknown target {target!r}; configured: {names}")
    return TARGETS[t]


# --- read-only client proxy ---------------------------------------------------------------
# Layer 2. The allow-list is checked at attribute access, so a write method is unreachable
# even from inside this file.

ALLOWED_METHODS = frozenset(
    {
        "ping",
        "info",
        "dbsize",
        "scan",
        "type",
        "ttl",
        "pttl",
        "object",
        "memory_usage",
        "exists",
        "strlen",
        "get",
        "getrange",
        "hget",
        "hgetall",
        "hkeys",
        "hlen",
        "hscan",
        "hexists",
        "hstrlen",
        "llen",
        "lrange",
        "lindex",
        "lpos",
        "scard",
        "sismember",
        "smembers",
        "sscan",
        "srandmember",
        "zcard",
        "zscore",
        "zrank",
        "zrevrank",
        "zrange",
        "zrevrange",
        "zscan",
        "zcount",
        "xlen",
        "xrange",
        "xrevrange",
        "xinfo_stream",
        "xinfo_groups",
        "xinfo_consumers",
        "xpending",
        "cluster",
        "close",
        "connection_pool",
    }
)


# `CLUSTER` is a subcommand dispatcher, and some of its subcommands write (RESET, SETSLOT,
# FORGET, MEET, FAILOVER, ...). Only the introspective ones are reachable, checked in _cluster.
CLUSTER_READ_SUBCOMMANDS = frozenset(
    {"INFO", "NODES", "SHARDS", "SLOTS", "KEYSLOT", "COUNTKEYSINSLOT", "MYID", "LINKS"}
)


class _ReadOnly:
    """Attribute-level allow-list around a redis.Redis client.

    Also the one place a cluster redirection is translated: this client is deliberately NOT
    cluster-aware (see cluster_topology), so a MOVED reply means the key lives on a node this
    tunnel does not reach — a fact the caller must see rather than a raw Redis error."""

    def __init__(self, client: redis.Redis) -> None:
        self._client = client

    def __getattr__(self, name: str):
        if name not in ALLOWED_METHODS:
            raise PermissionError(
                f"command {name!r} is not in the read-only allow-list of redis-triage"
            )
        attr = getattr(self._client, name)
        if not callable(attr):
            return attr

        def guarded(*args, **kwargs):
            try:
                return attr(*args, **kwargs)
            except redis.exceptions.ResponseError as exc:
                msg = str(exc)
                if msg.startswith(("MOVED", "ASK")):
                    owner = msg.split()[-1] if len(msg.split()) > 1 else "another node"
                    raise ValueError(
                        f"this key's slot is owned by cluster node {owner}, which this single "
                        f"port-forward does not reach. Run `cluster_topology` to see the shard "
                        f"map; a key on another shard needs that node forwarded."
                    ) from exc
                if msg.startswith("CROSSSLOT"):
                    raise ValueError(
                        "the keys span multiple hash slots — query them one key at a time"
                    ) from exc
                raise

        return guarded


# --- tunnel + connection ------------------------------------------------------------------


@dataclass
class Tunnel:
    target: Target
    proc: subprocess.Popen | None   # None for tunnel=none — nothing was spawned
    log_path: Path | None
    opened_at: float
    last_used: float
    clients: dict[int, _ReadOnly] = field(default_factory=dict)


_tunnels: dict[str, Tunnel] = {}
_lock = threading.RLock()
_watchdog: threading.Thread | None = None


def _port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def _client_name() -> str:
    who = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
    return f"claude-redis-triage-{who}"


def _spawn_tunnel(t: Target) -> Tunnel:
    """Start the gcloud SSH port-forward for a target and wait until Redis answers PING.

    argv is a list built from the frozen TARGETS entry — never a shell string — so no part of
    a tool argument can reach the command line. `ExitOnForwardFailure` makes a refused
    forward an immediate, reportable exit instead of a process that sits there doing nothing.
    """
    if t.tunnel == "none":
        # Already reachable (a bastion you run, a VPN, your own forward). Nothing to spawn and
        # nothing to reap — but the same lazy-connect and disconnect contract still applies.
        return Tunnel(target=t, proc=None, log_path=None, opened_at=time.time(), last_used=time.time())
    if _port_in_use(t.local_port):
        raise RuntimeError(
            f"127.0.0.1:{t.local_port} is already in use — refusing to adopt a tunnel this "
            f"process did not open (it may point somewhere else entirely). Inspect it with "
            f"`scripts/redis/tunnel.sh status` and clear it with `scripts/redis/tunnel.sh kill`."
        )
    log = Path(tempfile.mkstemp(prefix=f"redis-tunnel-{t.key}-", suffix=".log")[1])
    argv = [
        "gcloud",
        "compute",
        "ssh",
        t.vm,
        f"--zone={t.zone}",
        "--quiet",
        "--",
        "-N",
        "-T",
        "-o",
        "ExitOnForwardFailure=yes",
        "-o",
        "ServerAliveInterval=30",
        "-L",
        f"{t.local_port}:{t.remote_host}:{t.remote_port}",
    ]
    with log.open("wb") as fh:
        proc = subprocess.Popen(argv, stdout=fh, stderr=fh, stdin=subprocess.DEVNULL)
    tun = Tunnel(target=t, proc=proc, log_path=log, opened_at=time.time(), last_used=time.time())
    deadline = time.time() + TUNNEL_READY_TIMEOUT_S
    while time.time() < deadline:
        if proc.poll() is not None:
            tail = log.read_text(errors="replace").strip().splitlines()[-6:]
            raise RuntimeError(
                f"gcloud tunnel to {t.vm} exited (code {proc.returncode}). Last output:\n"
                + "\n".join(tail)
                + "\nCheck `gcloud auth list` and IAM/OS-Login access to the VM."
            )
        try:
            probe = redis.Redis(
                host="127.0.0.1",
                port=t.local_port,
                socket_timeout=2,
                socket_connect_timeout=2,
            )
            probe.ping()
            probe.close()
            return tun
        except Exception:
            time.sleep(0.5)
    _kill_tunnel(tun)
    raise RuntimeError(
        f"tunnel to {t.vm} did not become ready within {TUNNEL_READY_TIMEOUT_S}s "
        f"(port {t.local_port}); see {tun.log_path}"
    )


def _kill_tunnel(tun: Tunnel) -> None:
    for c in tun.clients.values():
        try:
            c.close()
        except Exception:
            pass
    tun.clients.clear()
    if tun.proc is None:
        return
    if tun.proc.poll() is None:
        tun.proc.terminate()
        try:
            tun.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            tun.proc.kill()
    try:
        if tun.log_path is not None:
            tun.log_path.unlink(missing_ok=True)
    except Exception:
        pass


def _reap_idle() -> None:
    """Layer 7. The tunnel closes itself, so 'must disconnect when done' never depends on the
    model, the skill, or a clean session exit."""
    while True:
        time.sleep(WATCHDOG_TICK_S)
        now = time.time()
        with _lock:
            for key, tun in list(_tunnels.items()):
                dead = tun.proc is not None and tun.proc.poll() is not None
                if now - tun.last_used > IDLE_TIMEOUT_S or dead:
                    _kill_tunnel(tun)
                    _tunnels.pop(key, None)


def _connect(t: Target, db: int) -> _ReadOnly:
    global _watchdog
    # Being able to reach the box (cloud IAM, a VPN, your own forward) is not permission:
    # a target declared `prod=true` requires the per-machine opt-in, checked before a tunnel
    # is spawned. A `prod=false` target (staging/test) is ungated. See docs/adr/0005.
    if t.is_prod:
        triage_policy.assert_prod_allowed("PRODUCTION Redis triage")
    with _lock:
        if _watchdog is None:
            _watchdog = threading.Thread(target=_reap_idle, name="redis-tunnel-watchdog", daemon=True)
            _watchdog.start()
        tun = _tunnels.get(t.key)
        if tun is not None and tun.proc is not None and tun.proc.poll() is not None:  # died under us
            _kill_tunnel(tun)
            _tunnels.pop(t.key, None)
            tun = None
        if tun is None:
            tun = _spawn_tunnel(t)
            _tunnels[t.key] = tun
        tun.last_used = time.time()
        if db not in tun.clients:
            tun.clients[db] = _ReadOnly(
                redis.Redis(
                    host="127.0.0.1",
                    port=t.local_port,
                    db=db,
                    socket_timeout=SOCKET_TIMEOUT_S,
                    socket_connect_timeout=5,
                    client_name=_client_name(),
                    decode_responses=False,
                )
            )
        return tun.clients[db]


def _close_all() -> list[str]:
    with _lock:
        closed = []
        for key, tun in list(_tunnels.items()):
            _kill_tunnel(tun)
            _tunnels.pop(key, None)
            closed.append(key)
        return closed


atexit.register(_close_all)


def _on_signal(signum, _frame):  # pragma: no cover - process teardown
    _close_all()
    raise SystemExit(128 + signum)


for _sig in (signal.SIGTERM, signal.SIGINT):
    try:
        signal.signal(_sig, _on_signal)
    except (ValueError, OSError):
        pass


# --- egress: secret masking + provenance --------------------------------------------------

SECRET_KEY_HINT = re.compile(
    r"token|session|sso|auth|passwd|password|secret|otp|jwt|api[_-]?key|credential|cookie|bearer",
    re.IGNORECASE,
)
_JWT = re.compile(r"^[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}$")
_LONG_HEX = re.compile(r"^[0-9a-fA-F]{32,}$")
_OPAQUE = re.compile(r"^[A-Za-z0-9+/=_-]{40,}$")


def _force_mask() -> bool:
    """Verification hook: exercise the prod masking path against staging without reading a
    real production credential."""
    return os.environ.get("REDIS_TRIAGE_FORCE_MASK") == "1"


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8", "replace")).hexdigest()[:8]


def _is_secret_value(value: str) -> bool:
    v = value.strip()
    return bool(_JWT.match(v) or _LONG_HEX.match(v) or _OPAQUE.match(v))


def _mask_json(obj):
    """Mask secret-named FIELDS and credential-shaped values inside a JSON payload, and leave
    the rest readable.

    Masking inside a payload is decided per FIELD, never from the outer key name: a
    `session:<id>` blob carries the inner-system id and status a triage is actually reading, and
    blanket-masking the whole payload because its key says "session" would destroy the
    evidence to protect the one field that needs it."""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if isinstance(v, str) and SECRET_KEY_HINT.search(str(k)):
                out[k] = f"<redis-secret:{_digest(v)}>"
            else:
                out[k] = _mask_json(v)
        return out
    if isinstance(obj, list):
        return [_mask_json(v) for v in obj]
    if isinstance(obj, str) and _is_secret_value(obj):
        return f"<redis-secret:{_digest(obj)}>"
    return obj


def _decode(raw) -> str:
    if raw is None:
        return None  # type: ignore[return-value]
    if isinstance(raw, (int, float)):
        return raw  # type: ignore[return-value]
    if isinstance(raw, bytes):
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError:
            return f"<binary:{len(raw)}B:{hashlib.sha256(raw).hexdigest()[:8]}>"
    return str(raw)


def _emit(t: Target, key: str, value):
    """THE choke point every returned value passes through — which makes it the single place
    that masks credentials and records provenance. Prod only: staging is not the prod
    boundary, so staging values are returned and vaulted as-is."""
    val = _decode(value)
    if val is None or not isinstance(val, str):
        return val
    if not (t.is_prod or _force_mask()):
        return val
    key_is_secret = bool(SECRET_KEY_HINT.search(key or ""))
    stripped = val.strip()
    if stripped.startswith(("{", "[")):
        try:
            masked = _mask_json(json.loads(stripped))
            out = json.dumps(masked, ensure_ascii=False)
        except (ValueError, TypeError):
            out = f"<redis-secret:{_digest(val)}>" if (key_is_secret or _is_secret_value(val)) else val
    elif key_is_secret or _is_secret_value(val):
        out = f"<redis-secret:{_digest(val)}>"
    else:
        out = val
    if t.is_prod and pii_provenance is not None:
        try:  # what survived masking is still production data; vault it for egress redaction
            pii_provenance.record_text(out)
        except Exception:
            pass
    return out


def _emit_many(t: Target, key: str, values: list) -> list:
    return [_emit(t, key, v) for v in values]


# --- shared helpers -----------------------------------------------------------------------


def _key_type(client: _ReadOnly, key: str) -> str:
    return _decode(client.type(key)) or "none"


def _cardinality(client: _ReadOnly, key: str, ktype: str) -> int | None:
    """Cheap size probe used by the bulk-read guard. O(1) for every type below."""
    if ktype == "hash":
        return int(client.hlen(key))
    if ktype == "list":
        return int(client.llen(key))
    if ktype == "set":
        return int(client.scard(key))
    if ktype == "zset":
        return int(client.zcard(key))
    if ktype == "stream":
        return int(client.xlen(key))
    if ktype == "string":
        return int(client.strlen(key))
    return None


def _guard_bulk(client: _ReadOnly, key: str, ktype: str, cursor_tool: str) -> int:
    """Layer 4. Refuse a bulk read that would hammer a single-threaded server or flood the
    context, and name the cursor tool to use instead."""
    n = _cardinality(client, key, ktype)
    if n is not None and n > BULK_CARDINALITY_LIMIT:
        raise ValueError(
            f"{key!r} holds {n} elements (> {BULK_CARDINALITY_LIMIT}) — refusing a bulk read. "
            f"Use `{cursor_tool}` to page through it, or narrow the question."
        )
    return n or 0


def _page(page: int, page_size: int) -> tuple[int, int]:
    page = max(1, int(page))
    page_size = max(1, min(int(page_size), MAX_PAGE))
    return page, page_size


def _touch(t: Target) -> None:
    with _lock:
        tun = _tunnels.get(t.key)
        if tun:
            tun.last_used = time.time()


def _ok(t: Target, payload: dict) -> dict:
    _touch(t)
    payload["target"] = t.key
    payload["masking"] = "on" if (t.is_prod or _force_mask()) else "off (staging)"
    return json.loads(json.dumps(payload, default=str))


# --- tools: session ----------------------------------------------------------------------


@mcp.tool()
def list_targets() -> dict:
    """List every Redis target, its tunnel spec, and whether a tunnel is currently open.

    Touches nothing remote — use it to sanity-check setup before querying and to see what
    `disconnect` would close."""
    out = []
    if not TARGETS:
        return {
            "targets": [],
            "hint": "no targets configured — copy scripts/redis/.env.example to scripts/redis/.env "
                    "and declare a REDISPROD_<NAME> spec (see scripts/redis/README.md)",
        }
    for key, t in TARGETS.items():
        tun = _tunnels.get(key)
        out.append(
            {
                "target": key,
                "vm": t.vm or None,
                "zone": t.zone or None,
                "forward": f"127.0.0.1:{t.local_port} -> {t.remote_host}:{t.remote_port}",
                "tunnel": t.tunnel,
                "is_prod": t.is_prod,
                "tunnel_open": tun is not None and (t.tunnel == "none" or (tun.proc is not None and tun.proc.poll() is None)),
                "idle_seconds": round(time.time() - tun.last_used, 1) if tun else None,
            }
        )
    return {"targets": out, "idle_timeout_seconds": IDLE_TIMEOUT_S}


@mcp.tool()
def tunnel_status() -> dict:
    """Report the live tunnel state: which targets are open, how long they have been idle, and
    how long until the watchdog reaps them."""
    with _lock:
        return {
            "open": [
                {
                    "target": k,
                    "pid": tun.proc.pid if tun.proc else None,
                    "up_seconds": round(time.time() - tun.opened_at, 1),
                    "idle_seconds": round(time.time() - tun.last_used, 1),
                    "reaped_in_seconds": round(IDLE_TIMEOUT_S - (time.time() - tun.last_used), 1),
                }
                for k, tun in _tunnels.items()
            ],
            "idle_timeout_seconds": IDLE_TIMEOUT_S,
        }


@mcp.tool()
def disconnect() -> dict:
    """Close every open tunnel and connection — the teardown for a triage job. Call it when the
    investigation is done; the watchdog also reaps anything idle past the timeout."""
    return {"closed": _close_all(), "open": list(_tunnels)}


# --- tools: server + keyspace -------------------------------------------------------------


@mcp.tool()
def server_info(section: str, target: str | None = None) -> dict:
    """Read one INFO section (e.g. 'server', 'clients', 'memory', 'stats', 'replication',
    'keyspace', 'cluster'). A section is required — the default INFO output is long enough to
    crowd out the investigation."""
    t = _resolve(target)
    client = _connect(t, 0)
    raw = client.info(section)
    return _ok(t, {"section": section, "info": {_decode(k): _decode(v) for k, v in raw.items()}})


def _cluster(client: _ReadOnly, sub: str, *args):
    up = sub.upper()
    if up not in CLUSTER_READ_SUBCOMMANDS:
        raise PermissionError(
            f"CLUSTER {up} is not read-only; allowed: {', '.join(sorted(CLUSTER_READ_SUBCOMMANDS))}"
        )
    return client.cluster(up, *args)


@mcp.tool()
def cluster_topology(target: str | None = None) -> dict:
    """Map the cluster and state what this session can actually see.

This server reaches ONE node per target. Read this before concluding a key is missing:
    with cluster mode enabled and more than one master, `scan_keys` and `dbsize` cover the
    reached node's slots only, and a key on another shard answers with a redirection rather than
    data. `keyslot_of` tells you which shard a specific key belongs to. A single-master cluster
    (or a non-cluster instance) covers the whole keyspace, which `coverage` states outright.
    """
    t = _resolve(target)
    client = _connect(t, 0)
    # redis-py applies response callbacks to CLUSTER INFO/NODES on some versions and hands
    # back the raw text on others — accept both rather than depend on the client version.
    raw_info = _cluster(client, "INFO")
    if isinstance(raw_info, dict):
        info = {str(_decode(k)): str(_decode(v)) for k, v in raw_info.items()}
    else:
        info = dict(
            line.split(":", 1) for line in (_decode(raw_info) or "").splitlines() if ":" in line
        )
    raw_nodes = _cluster(client, "NODES")
    nodes = []
    if isinstance(raw_nodes, dict):
        for addr, meta in raw_nodes.items():
            flags = str(_decode(meta.get("flags", "")))
            slots = meta.get("slots") or []
            nodes.append(
                {
                    "id": str(_decode(meta.get("node_id", "")))[:8],
                    "endpoint": str(_decode(addr)).split("@")[0],
                    "flags": flags,
                    "role": "master" if "master" in flags else "replica",
                    "link": str(_decode(meta.get("connected", ""))),
                    "slots": ",".join("-".join(str(x) for x in s) for s in slots),
                    "is_this_node": "myself" in flags,
                }
            )
    else:
        for line in (_decode(raw_nodes) or "").splitlines():
            parts = line.split()
            if len(parts) < 8:
                continue
            nodes.append(
                {
                    "id": parts[0][:8],
                    "endpoint": parts[1].split("@")[0],
                    "flags": parts[2],
                    "role": "master" if "master" in parts[2] else "replica",
                    "link": parts[7],
                    "slots": " ".join(parts[8:]) if len(parts) > 8 else "",
                    "is_this_node": "myself" in parts[2],
                }
            )
    masters = [n for n in nodes if n["role"] == "master"]
    mine = next((n for n in nodes if n["is_this_node"]), None)
    # cluster_enabled lives in INFO cluster, not CLUSTER INFO.
    enabled = str(_decode(client.info("cluster").get("cluster_enabled", "?")))
    return _ok(
        t,
        {
            "cluster_enabled": enabled,
            "cluster_state": info.get("cluster_state", "?").strip(),
            "known_nodes": int(info.get("cluster_known_nodes", "0").strip() or 0),
            "slots_assigned": info.get("cluster_slots_assigned", "?").strip(),
            "masters": len(masters),
            "nodes": nodes,
            "forwarded_node": mine,
            "coverage": (
                "whole keyspace — single-master cluster"
                if len(masters) <= 1
                else f"PARTIAL — this tunnel reaches 1 of {len(masters)} masters; "
                f"scan_keys/dbsize see only slots {mine['slots'] if mine else '?'}"
            ),
        },
    )


@mcp.tool()
def keyslot_of(key: str, target: str | None = None) -> dict:
    """Which hash slot a key belongs to, and whether the forwarded node owns that slot.

    Use it when a key read fails or comes back empty on a multi-node cluster — a hash tag such
    as `token:{agent:<id>}:x` pins the whole family to one slot, so a family either is or is
    not on the forwarded node."""
    t = _resolve(target)
    client = _connect(t, 0)
    slot = int(_cluster(client, "KEYSLOT", key))
    return _ok(t, {"key": key, "slot": slot, "keys_in_slot": int(_cluster(client, "COUNTKEYSINSLOT", slot))})


@mcp.tool()
def dbsize(target: str | None = None, db: int = 0) -> dict:
    """Number of keys in a logical DB **on the forwarded node** (see `cluster_topology`). The
    cheapest orientation call there is."""
    t = _resolve(target)
    return _ok(t, {"db": db, "keys": int(_connect(t, db).dbsize()), "scope": "forwarded node only"})


@mcp.tool()
def scan_keys(
    match: str,
    target: str | None = None,
    db: int = 0,
    cursor: int = 0,
    count: int = SCAN_DEFAULT_COUNT,
) -> dict:
    """Find keys by glob pattern with SCAN, bounded.

    KEYS is not available here at all: it blocks a single-threaded server for the length of
    the scan, which on prod is an outage. SCAN is incremental — this call spends at most
    SCAN_MAX_ITERATIONS iterations and returns at most 200 keys plus the `cursor` to resume
    from (`cursor: 0` in the result means the keyspace is exhausted).

    Pass a pattern from your own keyspace, e.g. `session:*`, `cache:user:*`, `<stream-name>`,
    `rate_limit:*` — `scan_keys "*"` first if you do not know the namespaces yet.
    """
    t = _resolve(target)
    client = _connect(t, db)
    keys: list[str] = []
    cur = int(cursor)
    iterations = 0
    while iterations < SCAN_MAX_ITERATIONS and len(keys) < MAX_PAGE:
        cur, batch = client.scan(cursor=cur, match=match, count=max(1, min(int(count), 1000)))
        keys.extend(_decode(k) for k in batch)
        iterations += 1
        if cur == 0:
            break
    truncated = len(keys) > MAX_PAGE
    return _ok(
        t,
        {
            "db": db,
            "match": match,
            "keys": keys[:MAX_PAGE],
            "cursor": cur,
            "exhausted": cur == 0 and not truncated,
            "iterations": iterations,
            "note": "key NAMES are inner-system identity and safe to quote; VALUES are not",
        },
    )


@mcp.tool()
def inspect_key(key: str, target: str | None = None, db: int = 0) -> dict:
    """Describe a key without reading its contents: type, TTL, cardinality, encoding, memory.

    Cheap and O(1) for every type. Run this before any bulk read — it is what tells you
    whether a key is a 12-field hash or a two-million-member set."""
    t = _resolve(target)
    client = _connect(t, db)
    ktype = _key_type(client, key)
    if ktype == "none":
        return _ok(t, {"key": key, "db": db, "exists": False})
    ttl = int(client.ttl(key))
    try:
        encoding = _decode(client.object("encoding", key))
    except Exception:
        encoding = None
    try:
        memory = int(client.memory_usage(key) or 0)
    except Exception:
        memory = None
    return _ok(
        t,
        {
            "key": key,
            "db": db,
            "exists": True,
            "type": ktype,
            "ttl_seconds": ttl,  # -1 = no expiry, -2 = gone
            "cardinality": _cardinality(client, key, ktype),
            "encoding": encoding,
            "memory_bytes": memory,
            "secret_by_name": bool(SECRET_KEY_HINT.search(key)),
        },
    )


# --- tools: strings -----------------------------------------------------------------------


@mcp.tool()
def get_value(key: str, target: str | None = None, db: int = 0, max_bytes: int = 8192) -> dict:
    """Read a string key, truncated to `max_bytes`.

    On prod, a credential-shaped value (or one under a credential-shaped key) comes back as
    `<redis-secret:sha8>` — stable across calls, so you can still tell "same token" from
    "different token" without the token itself entering the transcript."""
    t = _resolve(target)
    client = _connect(t, db)
    ktype = _key_type(client, key)
    if ktype == "none":
        return _ok(t, {"key": key, "exists": False})
    if ktype != "string":
        raise ValueError(f"{key!r} is a {ktype}, not a string — use the matching tool for {ktype}")
    size = int(client.strlen(key))
    cap = max(1, min(int(max_bytes), 65536))
    raw = client.getrange(key, 0, cap - 1) if size > cap else client.get(key)
    return _ok(
        t,
        {
            "key": key,
            "exists": True,
            "bytes": size,
            "truncated": size > cap,
            "value": _emit(t, key, raw),
        },
    )


# --- tools: hashes ------------------------------------------------------------------------


@mcp.tool()
def hget_field(key: str, field: str, target: str | None = None, db: int = 0) -> dict:
    """Read one field of a hash."""
    t = _resolve(target)
    client = _connect(t, db)
    raw = client.hget(key, field)
    return _ok(t, {"key": key, "field": field, "value": _emit(t, f"{key}:{field}", raw)})


@mcp.tool()
def hgetall_fields(key: str, target: str | None = None, db: int = 0) -> dict:
    """Read a whole hash. Refused above the cardinality limit — page with `hscan_fields`."""
    t = _resolve(target)
    client = _connect(t, db)
    ktype = _key_type(client, key)
    if ktype == "none":
        return _ok(t, {"key": key, "exists": False})
    if ktype != "hash":
        raise ValueError(f"{key!r} is a {ktype}, not a hash")
    n = _guard_bulk(client, key, ktype, "hscan_fields")
    raw = client.hgetall(key)
    return _ok(
        t,
        {
            "key": key,
            "exists": True,
            "field_count": n,
            "fields": {_decode(f): _emit(t, f"{key}:{_decode(f)}", v) for f, v in raw.items()},
        },
    )


@mcp.tool()
def hscan_fields(
    key: str, target: str | None = None, db: int = 0, cursor: int = 0, match: str | None = None
) -> dict:
    """Page through a hash's fields with HSCAN — the way to read a hash too big for
    `hgetall_fields`."""
    t = _resolve(target)
    client = _connect(t, db)
    cur, batch = client.hscan(key, cursor=int(cursor), match=match, count=MAX_PAGE)
    return _ok(
        t,
        {
            "key": key,
            "cursor": cur,
            "exhausted": cur == 0,
            "fields": {_decode(f): _emit(t, f"{key}:{_decode(f)}", v) for f, v in batch.items()},
        },
    )


# --- tools: lists -------------------------------------------------------------------------


@mcp.tool()
def list_length(key: str, target: str | None = None, db: int = 0) -> dict:
    """Length of a list."""
    t = _resolve(target)
    return _ok(t, {"key": key, "length": int(_connect(t, db).llen(key))})


@mcp.tool()
def list_range(
    key: str, target: str | None = None, db: int = 0, page: int = 1, page_size: int = MAX_PAGE
) -> dict:
    """Read a window of a list, paged at 200 elements. Page 1 is the head."""
    t = _resolve(target)
    client = _connect(t, db)
    page, page_size = _page(page, page_size)
    start = (page - 1) * page_size
    items = client.lrange(key, start, start + page_size - 1)
    total = int(client.llen(key))
    return _ok(
        t,
        {
            "key": key,
            "length": total,
            "page": page,
            "page_size": page_size,
            "has_more": start + len(items) < total,
            "items": _emit_many(t, key, items),
        },
    )


# --- tools: sets --------------------------------------------------------------------------


@mcp.tool()
def set_card(key: str, target: str | None = None, db: int = 0) -> dict:
    """Member count of a set."""
    t = _resolve(target)
    return _ok(t, {"key": key, "members": int(_connect(t, db).scard(key))})


@mcp.tool()
def set_is_member(key: str, member: str, target: str | None = None, db: int = 0) -> dict:
    """Is a specific member in a set? The cheap way to answer a membership question without
    reading the set."""
    t = _resolve(target)
    return _ok(t, {"key": key, "member": member, "is_member": bool(_connect(t, db).sismember(key, member))})


@mcp.tool()
def set_members(key: str, target: str | None = None, db: int = 0) -> dict:
    """Read a whole set. Refused above the cardinality limit — page with `set_scan`."""
    t = _resolve(target)
    client = _connect(t, db)
    ktype = _key_type(client, key)
    if ktype == "none":
        return _ok(t, {"key": key, "exists": False})
    if ktype != "set":
        raise ValueError(f"{key!r} is a {ktype}, not a set")
    n = _guard_bulk(client, key, ktype, "set_scan")
    return _ok(
        t,
        {"key": key, "exists": True, "member_count": n, "members": _emit_many(t, key, list(client.smembers(key)))},
    )


@mcp.tool()
def set_scan(
    key: str, target: str | None = None, db: int = 0, cursor: int = 0, match: str | None = None
) -> dict:
    """Page through a set with SSCAN."""
    t = _resolve(target)
    client = _connect(t, db)
    cur, batch = client.sscan(key, cursor=int(cursor), match=match, count=MAX_PAGE)
    return _ok(t, {"key": key, "cursor": cur, "exhausted": cur == 0, "members": _emit_many(t, key, batch)})


# --- tools: sorted sets -------------------------------------------------------------------


@mcp.tool()
def zset_card(key: str, target: str | None = None, db: int = 0) -> dict:
    """Member count of a sorted set."""
    t = _resolve(target)
    return _ok(t, {"key": key, "members": int(_connect(t, db).zcard(key))})


@mcp.tool()
def zset_score(key: str, member: str, target: str | None = None, db: int = 0) -> dict:
    """Score and rank of one sorted-set member — the targeted way to check a leaderboard entry."""
    t = _resolve(target)
    client = _connect(t, db)
    score = client.zscore(key, member)
    rank = client.zrank(key, member)
    return _ok(
        t,
        {
            "key": key,
            "member": member,
            "score": None if score is None else float(score),
            "rank": None if rank is None else int(rank),
        },
    )


@mcp.tool()
def zset_range(
    key: str,
    target: str | None = None,
    db: int = 0,
    page: int = 1,
    page_size: int = MAX_PAGE,
    descending: bool = False,
) -> dict:
    """Read a window of a sorted set with scores, paged at 200. `descending=True` starts from
    the top score."""
    t = _resolve(target)
    client = _connect(t, db)
    page, page_size = _page(page, page_size)
    start = (page - 1) * page_size
    stop = start + page_size - 1
    pairs = (
        client.zrevrange(key, start, stop, withscores=True)
        if descending
        else client.zrange(key, start, stop, withscores=True)
    )
    total = int(client.zcard(key))
    return _ok(
        t,
        {
            "key": key,
            "members": total,
            "page": page,
            "page_size": page_size,
            "descending": descending,
            "has_more": start + len(pairs) < total,
            "entries": [{"member": _emit(t, key, m), "score": float(s)} for m, s in pairs],
        },
    )


# --- tools: streams -----------------------------------------------------------------------
# When a service publishes events with XADD and others consume them through consumer groups,
# the group state (lag, pending entries, per-consumer idle time) is usually where a "the event
# never arrived" bug actually lives. XREAD/XREADGROUP/XAUTOCLAIM are absent by design — they
# block and/or advance group state, which is a write.


@mcp.tool()
def stream_length(key: str, target: str | None = None, db: int = 0) -> dict:
    """Entry count of a stream."""
    t = _resolve(target)
    return _ok(t, {"key": key, "entries": int(_connect(t, db).xlen(key))})


@mcp.tool()
def stream_range(
    key: str,
    target: str | None = None,
    db: int = 0,
    start: str = "-",
    end: str = "+",
    count: int = MAX_PAGE,
    newest_first: bool = True,
) -> dict:
    """Read stream entries between two IDs, capped at 200 per call.

    `newest_first=True` (XREVRANGE) is what a triage usually wants — the tail is what just
    happened. To page backwards, pass the last id you saw as `end` with `newest_first=True`."""
    t = _resolve(target)
    client = _connect(t, db)
    n = max(1, min(int(count), MAX_PAGE))
    entries = (
        client.xrevrange(key, max=end, min=start, count=n)
        if newest_first
        else client.xrange(key, min=start, max=end, count=n)
    )
    return _ok(
        t,
        {
            "key": key,
            "newest_first": newest_first,
            "count": len(entries),
            "entries": [
                {
                    "id": _decode(eid),
                    "fields": {_decode(f): _emit(t, f"{key}:{_decode(f)}", v) for f, v in fields.items()},
                }
                for eid, fields in entries
            ],
        },
    )


@mcp.tool()
def stream_info(key: str, target: str | None = None, db: int = 0) -> dict:
    """Stream metadata: length, last-generated id, first/last entry, radix-tree stats."""
    t = _resolve(target)
    client = _connect(t, db)
    raw = client.xinfo_stream(key)
    return _ok(t, {"key": key, "info": {_decode(k): _decode(v) for k, v in raw.items()}})


@mcp.tool()
def stream_groups(key: str, target: str | None = None, db: int = 0) -> dict:
    """Consumer groups on a stream, with each group's pending count and lag — the first place
    to look when a subscribing service has fallen behind or stalled."""
    t = _resolve(target)
    client = _connect(t, db)
    groups = client.xinfo_groups(key)
    return _ok(
        t,
        {"key": key, "groups": [{_decode(k): _decode(v) for k, v in g.items()} for g in groups]},
    )


@mcp.tool()
def stream_consumers(key: str, group: str, target: str | None = None, db: int = 0) -> dict:
    """Consumers in a group: pending count and idle time per consumer — this is what shows a
    dead or wedged consumer holding entries."""
    t = _resolve(target)
    client = _connect(t, db)
    consumers = client.xinfo_consumers(key, group)
    return _ok(
        t,
        {
            "key": key,
            "group": group,
            "consumers": [{_decode(k): _decode(v) for k, v in c.items()} for c in consumers],
        },
    )


@mcp.tool()
def stream_pending(key: str, group: str, target: str | None = None, db: int = 0) -> dict:
    """PEL summary for a group: how many entries are pending, the id range, and the per-consumer
    counts. Summary form only — the detailed form is unbounded."""
    t = _resolve(target)
    client = _connect(t, db)
    raw = client.xpending(key, group)
    return _ok(t, {"key": key, "group": group, "pending": {_decode(k): _decode(v) for k, v in raw.items()}})


# --- tools: shape capture -----------------------------------------------------------------


@mcp.tool()
def capture_shape(keys: list[str], target: str | None = None, db: int = 0) -> dict:
    """Describe keys as a *shape* — type, TTL, cardinality, field names, value kinds — with
    every value synthesized, so a local repro can be built without moving production data.

    This is the only sanctioned way to get production Redis state onto a local machine: what
    crosses the boundary is a schema, not values, and the synthesis happens here rather than
    in someone's head. Feed the result to `scripts/redis/replay_shape.py`, which writes the
    synthetic keys into LOCAL Redis under one prefix and tears them down by that prefix.

    It cannot reproduce consumer-group state (a PEL entry's delivery count and idle time) —
    for a wedged-consumer bug, read the live group with `stream_groups` / `stream_pending`
    and fix forward with a test instead.
    """
    t = _resolve(target)
    client = _connect(t, db)
    shapes = []
    for key in keys[:MAX_PAGE]:
        ktype = _key_type(client, key)
        if ktype == "none":
            shapes.append({"key": key, "exists": False})
            continue
        entry: dict = {
            "key": key,
            "exists": True,
            "type": ktype,
            "ttl_seconds": int(client.ttl(key)),
            "cardinality": _cardinality(client, key, ktype),
        }
        if ktype == "hash":
            fields = [_decode(f) for f in list(client.hkeys(key))[:MAX_PAGE]]
            entry["fields"] = {f: _kind(_decode(client.hget(key, f))) for f in fields}
        elif ktype == "string":
            entry["value_kind"] = _kind(_decode(client.get(key)))
        elif ktype == "zset":
            pairs = client.zrange(key, 0, 4, withscores=True)
            entry["score_sample"] = [float(s) for _, s in pairs]
        elif ktype == "stream":
            entries = client.xrevrange(key, count=1)
            entry["fields"] = (
                {_decode(f): _kind(_decode(v)) for f, v in entries[0][1].items()} if entries else {}
            )
            entry["groups"] = [_decode(g.get("name")) for g in client.xinfo_groups(key)] if entry["cardinality"] else []
        shapes.append(entry)
    return _ok(t, {"db": db, "shapes": shapes, "values": "synthesized — no production value is included"})


def _kind(value) -> str:
    """Classify a value without disclosing it: what a replay needs is the shape."""
    if value is None:
        return "null"
    s = str(value)
    if _JWT.match(s.strip()) or _LONG_HEX.match(s.strip()) or _OPAQUE.match(s.strip()):
        return f"opaque_token[{len(s)}]"
    if s.strip().startswith(("{", "[")):
        try:
            parsed = json.loads(s)
        except ValueError:
            return f"string[{len(s)}]"
        if isinstance(parsed, dict):
            return "json{" + ",".join(f"{k}:{_kind(v)}" for k, v in list(parsed.items())[:20]) + "}"
        return f"json_array[{len(parsed)}]"
    try:
        int(s)
        return "integer"
    except ValueError:
        pass
    try:
        float(s)
        return "float"
    except ValueError:
        pass
    return f"string[{len(s)}]"


# --- selftest / verify --------------------------------------------------------------------

# Write-command call sites this file must never contain. Split so the tokens do not match
# themselves during the source scan.
_WRITE_CALLS = [
    ".s" + "et(", ".del" + "ete(", ".hs" + "et(", ".hd" + "el(", ".lp" + "ush(", ".rp" + "ush(",
    ".lp" + "op(", ".rp" + "op(", ".sa" + "dd(", ".sr" + "em(", ".sp" + "op(", ".za" + "dd(",
    ".zr" + "em(", ".xa" + "dd(", ".xd" + "el(", ".xgroup" + "_create(", ".xread" + "group(",
    ".xauto" + "claim(", ".exp" + "ire(", ".ren" + "ame(", ".flush" + "all(", ".flush" + "db(",
    ".ev" + "al(", ".mig" + "rate(", ".rest" + "ore(", ".du" + "mp(", ".config" + "_set(",
    ".getd" + "el(", ".getx" + "x(", ".gete" + "x(", ".co" + "py(", ".swap" + "db(",
    ".execute_" + "command(", ".pub" + "lish(", ".s" + "ort(",
]


def _scan_own_source() -> list[str]:
    src = Path(__file__).read_text()
    lines = [l for l in src.splitlines() if "selftest-allow" not in l]
    body = "\n".join(lines)
    return [tok for tok in _WRITE_CALLS if tok in body]


def _selftest() -> int:
    failures: list[str] = []

    def check(desc: str, cond: bool) -> None:
        print(f"  {'ok  ' if cond else 'FAIL'} {desc}")
        if not cond:
            failures.append(desc)

    print("redis-triage selftest (no network access)")
    check("redis + mcp imported", redis is not None and mcp is not None)
    check("triage policy wired", hasattr(triage_policy, "assert_prod_allowed"))
    for _k in ("enabled", "prod"):
        _v, _src = triage_policy.resolve(_k)
        print(f"  ..   triage.{_k} = {str(_v).lower()} ({_src})")
    _dead = triage_policy.dead_key_present()
    if _dead:
        print(f"  ..   ! {_dead} still sets the REMOVED key `prod_triage.enabled` — ignored")
    check("a prod target is gated unless triage.prod is on", _prod_gated())
    check("pii provenance wired", pii_provenance is not None)
    ports = [t.local_port for t in TARGETS.values()]
    check("target local ports unique", len(ports) == len(set(ports)))
    check(
        f"{len(TARGETS)} target(s) configured from {ENV_PATH.name}"
        + ("" if TARGETS else " — copy .env.example to .env to declare some"),
        True,
    )
    check(
        "no target forwards to the default 6379 (which is usually the LOCAL dev Redis)",
        6379 not in ports,
    )
    check("a bad spec is reported, not silently dropped", _bad_spec_reported())
    check("prod target is explicit-only (no default)", _no_default_target())
    offenders = _scan_own_source()
    check(f"no write-command call sites in source ({offenders or 'none'})", not offenders)
    check("no passthrough tool exposed", "execute_command" not in ALLOWED_METHODS)
    check(
        "read-only proxy blocks a write method",
        _proxy_blocks("set") and _proxy_blocks("delete") and _proxy_blocks("xadd"),
    )
    # Synthetic targets: the masking rules must be testable on a machine with no .env at all.
    prod = Target("t_prod", "127.0.0.1", 6379, 6399, True, "none", "", "")
    staging = Target("t_stg", "127.0.0.1", 6379, 6398, False, "none", "", "")
    # Assembled rather than written out, so a secret scanner does not flag a test fixture.
    jwt = ".".join(["eyJ" + "hbGciOiJIUzI1NiJ9", "eyJzdWIiOiJ0ZXN0In0", "c2lnbmF0dXJlLXBsYWNlaG9sZGVy"])
    check("prod masks a JWT value", str(_emit(prod, "sso:abc", jwt)).startswith("<redis-secret:"))
    check(
        "prod masks a value under a credential-shaped key",
        str(_emit(prod, "token:{agent:9}:x", "plainish-value")).startswith("<redis-secret:"),
    )
    check(
        "prod masks a secret FIELD inside JSON, keeps the rest",
        _json_field_masked(prod),
    )
    check("prod leaves a money integer alone", _emit(prod, "user_balance:P1", "100000000") == "100000000")
    check("staging returns a JWT unmasked (PII bypass)", _emit(staging, "sso:abc", jwt) == jwt)
    check("digest is stable across calls", _digest("abc") == _digest("abc"))
    check("bulk limit below page cap is meaningless", BULK_CARDINALITY_LIMIT > MAX_PAGE)
    check("idle timeout set", 0 < IDLE_TIMEOUT_S <= 600)
    print("selftest ok" if not failures else f"selftest FAILED ({len(failures)} check(s))")
    return 1 if failures else 0


def _bad_spec_reported() -> bool:
    """A malformed target spec must raise a named error rather than resolve to something odd."""
    try:
        _parse_target("broken", "port=6379")
        return False
    except ValueError:
        return True


def _no_default_target() -> bool:
    try:
        _resolve(None)
        return False
    except ValueError:
        return True


def _prod_gated() -> bool:
    """With the opt-in off, connecting to a `prod=true` target must be refused BEFORE a tunnel is
    spawned. With it on — or with no prod target declared — there is nothing to assert offline."""
    if triage_policy.prod_allowed():
        return True
    prod_targets = [t for t in TARGETS.values() if t.is_prod]
    if not prod_targets:
        return True
    try:
        _connect(prod_targets[0], 0)
        return False
    except PermissionError:
        return True
    except Exception:
        return False  # anything else means it got past the gate and tried to connect


def _proxy_blocks(method: str) -> bool:
    proxy = _ReadOnly.__new__(_ReadOnly)
    try:
        getattr(proxy, method)
        return False
    except PermissionError:
        return True
    except Exception:
        return False


def _json_field_masked(t: Target) -> bool:
    out = _emit(t, "session:abc", json.dumps({"account_code": "AC78900000021", "access_token": "abc123"}))
    return "AC78900000021" in out and "abc123" not in out


def _verify(target_name: str, wait_for_idle: bool = False) -> int:
    """Live, read-only acceptance run against one target. Everything here is a read; the
    tunnel is closed at the end either way."""
    failures: list[str] = []

    def check(desc: str, cond: bool, detail: str = "") -> None:
        print(f"  {'ok  ' if cond else 'FAIL'} {desc}{(' — ' + detail) if detail else ''}")
        if not cond:
            failures.append(desc)

    t = _resolve(target_name)
    print(f"redis-triage verify: {t.key} ({t.vm} -> {t.remote_host}:{t.remote_port})")
    prod_allowed, policy_source = triage_policy.resolve("prod")
    print(f"  ..   triage.prod = {str(prod_allowed).lower()} ({policy_source})")
    if not prod_allowed and not t.is_prod:
        _prod = [x for x in TARGETS.values() if x.is_prod]
        if _prod:
            try:
                _connect(_prod[0], 0)
                check("a prod target is refused while triage.prod is off", False, "the connect SUCCEEDED")
            except PermissionError as exc:
                check("a prod target is refused while triage.prod is off", "triage.prod" in str(exc))

    try:
        info = server_info("server", t.key)
        check("tunnel up + INFO server", "redis_version" in info["info"], info["info"].get("redis_version", ""))
        topo = cluster_topology(t.key)
        check(
            "cluster topology readable + state ok",
            topo["cluster_state"] == "ok",
            f"enabled:{topo['cluster_enabled']} masters:{topo['masters']} nodes:{topo['known_nodes']}",
        )
        print(f"  ..   coverage: {topo['coverage']}")
        size = dbsize(t.key)
        check("DBSIZE", size["keys"] >= 0, f"{size['keys']} keys on the forwarded node")
        scan = scan_keys("*", t.key)
        check("SCAN bounded", len(scan["keys"]) <= MAX_PAGE, f"{len(scan['keys'])} keys, cursor {scan['cursor']}")
        biggest = None  # largest key overall, for the report
        bulkiest = None  # largest hash/set — the only types with an unbounded reader to guard
        for k in scan["keys"][:MAX_PAGE]:
            got = inspect_key(k, t.key)
            if not got.get("exists") or got.get("cardinality") is None:
                continue
            if biggest is None or got["cardinality"] > biggest[1]:
                biggest = (k, got["cardinality"], got["type"])
            if got["type"] in ("hash", "set") and (bulkiest is None or got["cardinality"] > bulkiest[1]):
                bulkiest = (k, got["cardinality"], got["type"])
        check("inspect_key on real keys", biggest is not None, f"largest: {biggest}" if biggest else "no keys")
        streams = [k for k in scan["keys"] if _key_type(_connect(t, 0), k) == "stream"]
        if streams:
            sk = streams[0]
            sinfo = stream_info(sk, t.key)
            entries = stream_range(sk, t.key, count=2)
            groups = stream_groups(sk, t.key)
            check(
                "stream read (info + range + groups)",
                "length" in sinfo["info"] and entries["count"] >= 0,
                f"{sk}: len={sinfo['info'].get('length')} groups={len(groups['groups'])}",
            )
        else:
            check("stream read", False, "no stream key found in the scanned page — rerun with a match")
        if bulkiest and bulkiest[1] > BULK_CARDINALITY_LIMIT:
            try:
                hgetall_fields(bulkiest[0], t.key) if bulkiest[2] == "hash" else set_members(bulkiest[0], t.key)
                check("big-key guard refuses a bulk read", False, f"guard did not fire on {bulkiest}")
            except ValueError as exc:
                check("big-key guard refuses a bulk read", "refusing a bulk read" in str(exc), bulkiest[0])
        else:
            print(
                "  ..   skip big-key guard — no hash/set above "
                f"{BULK_CARDINALITY_LIMIT} in this sample (streams/lists/zsets are read paged, "
                "so they have no unbounded reader to guard)"
            )
        if _force_mask():
            probe = [k for k in scan["keys"] if SECRET_KEY_HINT.search(k)]
            if probe:
                got = get_value(probe[0], t.key) if _key_type(_connect(t, 0), probe[0]) == "string" else None
                masked = got is None or str(got.get("value", "")).startswith("<redis-secret:")
                check("masking path active (REDIS_TRIAGE_FORCE_MASK=1)", masked, probe[0])
            else:
                print("  skip  masking on a live key — no credential-shaped key in this sample")
        if wait_for_idle:
            print(f"  .. waiting {IDLE_TIMEOUT_S + WATCHDOG_TICK_S}s for the idle watchdog")
            time.sleep(IDLE_TIMEOUT_S + WATCHDOG_TICK_S + 2)
            check("watchdog reaped the idle tunnel", not _port_in_use(t.local_port))
    finally:
        closed = _close_all()
        print(f"  ok   disconnect closed: {closed or 'nothing'}")
        if _port_in_use(t.local_port):
            failures.append("port still listening after disconnect")
            print(f"  FAIL port {t.local_port} still listening after disconnect")
    print("verify ok" if not failures else f"verify FAILED ({len(failures)} check(s))")
    return 1 if failures else 0


def _smoke(target_name: str) -> int:
    """Minimal proof that a target's tunnel + spec work: three cheap reads, then teardown.

    This is what gets pointed at PRODUCTION — enough to know the forward, the credentials and
    the cluster coverage are real, without running an investigation nobody asked for."""
    t = _resolve(target_name)
    leaked = False
    print(f"redis-triage smoke: {t.key} ({t.vm} -> {t.remote_host}:{t.remote_port})")
    try:
        info = server_info("server", t.key)
        print(f"  ok   INFO server — redis {info['info'].get('redis_version')}, uptime "
              f"{info['info'].get('uptime_in_days')}d")
        topo = cluster_topology(t.key)
        print(f"  ok   topology — enabled:{topo['cluster_enabled']} state:{topo['cluster_state']} "
              f"masters:{topo['masters']} nodes:{topo['known_nodes']}")
        print(f"  ..   coverage: {topo['coverage']}")
        print(f"  ok   DBSIZE — {dbsize(t.key)['keys']} keys on the forwarded node")
        print(f"  ok   masking — {'on' if t.is_prod else 'off (staging)'}")
    finally:
        print(f"  ok   disconnect closed: {_close_all() or 'nothing'}")
        leaked = _port_in_use(t.local_port)
        print(f"  {'FAIL' if leaked else 'ok  '} port {t.local_port} {'STILL LISTENING' if leaked else 'released'}")
    return 1 if leaked else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    if "--smoke" in sys.argv:
        idx = sys.argv.index("--smoke")
        raise SystemExit(_smoke(sys.argv[idx + 1] if len(sys.argv) > idx + 1 else ""))
    if "--verify" in sys.argv:
        idx = sys.argv.index("--verify")
        name = sys.argv[idx + 1] if len(sys.argv) > idx + 1 else ""
        raise SystemExit(_verify(name, wait_for_idle="--verify-idle" in sys.argv))
    mcp.run()  # stdio transport
