# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "mcp>=1.2,<2",
#   "redis>=5.0",
#   "python-dotenv>=1.0",
# ]
# ///
# # The <2 bound is load-bearing: mcp 2.0 removed `mcp.server.fastmcp`, so an unbounded `mcp>=1.2`
# # resolves to a release this file cannot import. It only looks fine on a machine whose uv cache
# # still holds a 1.x environment — a fresh clone gets ModuleNotFoundError on the import below.
"""redis-triage — on-demand, READ-ONLY MCP over your PRODUCTION (and staging) Redis.

One MCP process, as many targets as you configure. Which Redis a tool touches is chosen *per
call* by a `target` argument — never baked into the process, and never defaulted, so a
production target is only ever reached by naming it.

Targets are declared in `scripts/redis/.env`, one variable per target (see `.env.example`):

  REDISPROD_<NAME>=host=<addr>;port=6379;local=<port>;tunnel=gcloud;vm=<vm>;zone=<zone>
  REDISSTG_<NAME>=host=<addr>;port=6379;local=<port>;tunnel=gcloud;vm=<vm>;zone=<zone>

addressed as `target="prod:<name>"` / `target="staging:<name>"` (a bare `<name>` only when one
environment declares it). The PREFIX decides, same as PGPROD_/PGSTG_ for pg_triage: REDISPROD_
turns on credential masking + PII provenance and the per-machine prod gate; REDISSTG_ (a
staging box) returns values as-is, ungated. A `prod=` key inside a value is refused by name.

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
import difflib
import hashlib
import json
import os
import re
import signal
import sys
import threading
import time
from collections.abc import Mapping
from dataclasses import dataclass
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
import gcloud_tunnel  # noqa: E402  — stdlib-only tunnel helper, shared with pg_triage

gcloud_tunnel.TUNNEL_SH = "scripts/redis/tunnel.sh"   # the status|kill remedy named in refusals

try:
    import pii_provenance
except Exception:  # provenance is a safety net; a missing module must not break triage
    pii_provenance = None  # type: ignore[assignment]

# --- targets ------------------------------------------------------------------------------
# Declared in scripts/redis/.env, parsed by THIS process — so host names, VM names and the
# tunnel shape never pass through the agent, the MCP config, or the transcript. A machine with
# no .env has no targets, which is the per-machine opt-in.


ENV_PROD = "prod"
ENV_STAGING = "staging"
# The PREFIX decides whether a target is production — same convention as pg_triage_mcp.py
# (PGPROD_/PGSTG_). Only a variable literally named REDISSTG_* can ever be ungated, so a typo
# or a copied line can never silently downgrade a production box.
PREFIXES = {ENV_PROD: "REDISPROD_", ENV_STAGING: "REDISSTG_"}


@dataclass(frozen=True)
class Target:
    name: str
    remote_host: str
    remote_port: int
    local_port: int
    env: str  # ENV_PROD | ENV_STAGING — from the prefix, never from the value
    tunnel: str  # "gcloud" | "none"
    vm: str
    zone: str
    project: str = ""
    iap: bool = False

    @property
    def is_prod(self) -> bool:
        return self.env == ENV_PROD

    @property
    def key(self) -> str:
        return f"{self.env}:{self.name}"

    @property
    def var(self) -> str:
        return PREFIXES[self.env] + self.name.upper()


# REDIS_TRIAGE_ENV overrides the file (a test fixture, or a shared location) — the variables it
# declares can also be exported directly, in which case no file is needed at all.
ENV_PATH = Path(os.environ.get("REDIS_TRIAGE_ENV") or Path(__file__).parent / ".env")
load_dotenv(ENV_PATH)  # no-op when absent; targets then simply report as unconfigured

_NAME_RE = re.compile(r"^[A-Z][A-Z0-9]*(_[A-Z0-9]+)*$")  # UPPER_SNAKE; single underscores only
# Fixed reasons only — a report names the VARIABLE, never its value.
REASON_UPPER = "names are UPPER_SNAKE"
REASON_PROD_KEY = (
    "prod= is not a key: the PREFIX decides — move the line to REDISPROD_<NAME> for a "
    "production box or REDISSTG_<NAME> for staging, and delete prod="
)


def _classify(var: str, env: Mapping[str, str]) -> tuple[str | None, str | None, str | None, str | None]:
    """Classify one env var name -> (env, name, reason, did_you_mean). Mirrors pg_triage's
    `_classify`: a var that is not ours is (None, None, None, None); a usable one carries its
    env + lower-cased name; an unusable one a FIXED reason and, where a rule can suggest one,
    the spelling to use instead."""
    hit = next(((e, p) for e, p in PREFIXES.items() if var.upper().startswith(p)), None)
    if hit is None:
        return None, None, None, None
    env_name, prefix = hit
    suffix = var[len(prefix):]
    fixed = prefix + suffix.upper()
    if fixed != var:  # wrong case somewhere: diagnose the upper-cased form, never accept it
        _, name, _, dym = _classify(fixed, env)
        return None, None, REASON_UPPER, dym or (fixed if name else None)
    if not _NAME_RE.match(suffix):
        return None, None, REASON_UPPER, _closest(prefix, var, env)
    return env_name, suffix.lower(), None, None


def _closest(prefix: str, var: str, env: Mapping[str, str]) -> str | None:
    """difflib fallback for an unrecognized name: the nearest usable var under the same prefix."""
    candidates = [v for v in env if v.startswith(prefix) and v != var and _NAME_RE.match(v[len(prefix):])]
    hits = difflib.get_close_matches(var, candidates, n=1)
    return hits[0] if hits else None


def _parse_target(env: str, name: str, spec: str) -> Target:
    """Parse one `REDISPROD_<NAME>` / `REDISSTG_<NAME>` spec: `key=value` pairs separated by `;`."""
    var = PREFIXES[env] + name.upper()
    kv: dict[str, str] = {}
    for part in spec.split(";"):
        part = part.strip()
        if not part:
            continue
        k, _, v = part.partition("=")
        kv[k.strip().lower()] = v.strip()
    if "prod" in kv:
        raise ValueError(REASON_PROD_KEY)
    host = kv.get("host") or kv.get("remote") or ""
    if not host:
        raise ValueError(f"{var} has no host=")
    local = int(kv.get("local") or kv.get("local_port") or 0)
    if not local:
        raise ValueError(f"{var} has no local=<port> to forward to")
    tunnel = (kv.get("tunnel") or "gcloud").lower()
    if tunnel not in ("gcloud", "none"):
        raise ValueError(f"{var} tunnel={tunnel!r}; use gcloud|none")
    if tunnel == "gcloud" and not kv.get("vm"):
        raise ValueError(f"{var} needs vm=<instance> for tunnel=gcloud")
    return Target(
        name=name.lower(),
        remote_host=host,
        remote_port=int(kv.get("port") or 6379),
        local_port=local,
        env=env,
        tunnel=tunnel,
        vm=kv.get("vm") or "",
        zone=kv.get("zone") or "",
        project=kv.get("project") or "",
        iap=(kv.get("iap") or "false").lower() in ("true", "yes", "1"),
    )


def _load_targets(env: Mapping[str, str] | None = None) -> tuple[dict[str, Target], list[dict]]:
    """-> (targets keyed `env:name`, unrecognized [{var, reason, did_you_mean}]). An unusable
    variable is REPORTED, never silently dropped — and the report carries only its name."""
    if env is None:
        env = os.environ
    out: dict[str, Target] = {}
    bad: list[dict] = []
    for var, spec in env.items():
        env_name, name, reason, dym = _classify(var, env)
        if env_name is None and reason is None:
            continue
        if env_name is not None:
            try:
                out[f"{env_name}:{name}"] = _parse_target(env_name, name, spec)
                continue
            except ValueError as exc:
                reason = str(exc)
        bad.append({"var": var, "reason": reason, "did_you_mean": dym})
        print(f"redis-triage: unrecognized {var} — {reason}" + (f"; did you mean {dym}?" if dym else ""),
              file=sys.stderr)
    return out, bad


TARGETS, UNRECOGNIZED = _load_targets()


def _env_mtime() -> float:
    try:
        return ENV_PATH.stat().st_mtime
    except OSError:
        return 0.0


_env_loaded_mtime = _env_mtime()


def _refresh_targets() -> None:
    """Re-read .env when it changed since the last load, so an edit (a swapped vm, a new target)
    takes effect without restarting the session. Skipped while any tunnel is open — rebinding a
    target under a live forward would leave it pointing at the old VM. ponytail: a variable
    DELETED from .env stays loaded until restart (os.environ is never pruned)."""
    global TARGETS, UNRECOGNIZED, _env_loaded_mtime
    mtime = _env_mtime()
    if mtime == _env_loaded_mtime or _tunnels:
        return
    load_dotenv(ENV_PATH, override=True)
    TARGETS, UNRECOGNIZED = _load_targets()
    _env_loaded_mtime = mtime

IDLE_TIMEOUT_S = 120  # no tool call for this long -> the tunnel is killed
WATCHDOG_TICK_S = 10
SOCKET_TIMEOUT_S = 15
MAX_PAGE = 200
BULK_CARDINALITY_LIMIT = 1000  # above this, a bulk read is refused in favour of a cursor
SCAN_MAX_ITERATIONS = 10
SCAN_DEFAULT_COUNT = 500

mcp = FastMCP("redis-triage")


def _resolve(target: str | None, targets: dict[str, Target] | None = None) -> Target:
    """Resolve `[<env>:]<name>` (`prod:main`, `staging:main`). There is NO default: an unnamed
    target is an error, never a guess, and a bare name resolves only when exactly one
    environment declares it — one declared under both prefixes is refused, never defaulted to
    prod, so prod is only ever reached by asking for it explicitly."""
    if targets is None:
        _refresh_targets()
        targets = TARGETS
    names = " | ".join(sorted(targets)) or "(none configured — see scripts/redis/.env.example)"
    if not target:
        raise ValueError(f"provide `target` ({names}) — there is no default, so a production target is never implied")
    t = target.strip().lower()
    if t in targets:
        return targets[t]
    hits = [k for k in sorted(targets) if k.split(":", 1)[1] == t]
    if len(hits) == 1:
        return targets[hits[0]]
    if hits:
        raise ValueError(f"target {target!r} exists in more than one environment — name one: {' | '.join(hits)}")
    raise ValueError(f"unknown target {target!r}; configured: {names}")


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
# The forward itself (spawn, adopt-or-refuse, process-group teardown, ownership signature) is
# scripts/lib/gcloud_tunnel.py, shared with pg_triage. This file keeps only what is Redis:
# the PING readiness probe, the per-db clients, and the idle watchdog.

_tunnels: dict[str, gcloud_tunnel.Tunnel] = {}      # target key -> forward
_clients: dict[str, dict[int, _ReadOnly]] = {}       # target key -> db -> client
_lock = threading.RLock()
_watchdog: threading.Thread | None = None


def _port_in_use(port: int) -> bool:
    return gcloud_tunnel._port_in_use(port)


def _client_name() -> str:
    who = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
    return f"claude-redis-triage-{who}"


def _spec(t: Target) -> gcloud_tunnel.TunnelSpec:
    return gcloud_tunnel.TunnelSpec(
        label=t.var, kind=t.tunnel, host=t.remote_host, port=t.remote_port,
        local_port=t.local_port, vm=t.vm, zone=t.zone, project=t.project, iap=t.iap,
    )


def _ping_probe(t: Target):
    """Readiness = Redis answers PING through the forward, not merely a listening port — the
    same end-to-end probe a forward must pass to be ADOPTED (a stale forward is refused)."""
    def ready() -> bool:
        probe = redis.Redis(host="127.0.0.1", port=t.local_port, socket_timeout=2, socket_connect_timeout=2)
        try:
            return bool(probe.ping())
        finally:
            probe.close()
    return ready


def _drop(key: str) -> gcloud_tunnel.Tunnel | None:
    """Close the clients, then the forward (an adopted one is left running). Caller holds _lock."""
    for c in _clients.pop(key, {}).values():
        try:
            c.close()
        except Exception:
            pass
    tun = _tunnels.pop(key, None)
    if tun is not None:
        gcloud_tunnel.close_tunnel(tun)
    return tun


def _reap_idle() -> None:
    """Layer 7. The tunnel closes itself, so 'must disconnect when done' never depends on the
    model, the skill, or a clean session exit."""
    while True:
        time.sleep(WATCHDOG_TICK_S)
        _reap_once(time.time())


def _reap_once(now: float) -> None:
    with _lock:
        for key, tun in list(_tunnels.items()):
            if now - tun.last_used > IDLE_TIMEOUT_S or not gcloud_tunnel.is_alive(tun):
                _drop(key)


def _connect(t: Target, db: int) -> _ReadOnly:
    global _watchdog
    # Being able to reach the box (cloud IAM, a VPN, your own forward) is not permission:
    # a REDISPROD_ target requires the per-machine opt-in, checked before a tunnel is spawned
    # or an existing forward is even inspected. A REDISSTG_ target is ungated. See docs/adr/0005.
    if t.is_prod:
        triage_policy.assert_prod_allowed("PRODUCTION Redis triage")
    with _lock:
        if _watchdog is None:
            _watchdog = threading.Thread(target=_reap_idle, name="redis-tunnel-watchdog", daemon=True)
            _watchdog.start()
        tun = _tunnels.get(t.key)
        if tun is not None and not gcloud_tunnel.is_alive(tun):  # died under us
            _drop(t.key)
            tun = None
        if tun is None:
            tun = gcloud_tunnel.open_tunnel(_spec(t), ready=_ping_probe(t))  # spawn, or adopt a proven forward
            _tunnels[t.key] = tun
        tun.last_used = time.time()
        clients = _clients.setdefault(t.key, {})
        if db not in clients:
            clients[db] = _ReadOnly(
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
        return clients[db]


def _close_all() -> list[str]:
    with _lock:
        closed = list(_tunnels)
        for key in closed:
            _drop(key)
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
    payload["env"] = t.env
    payload["masking"] = "on" if (t.is_prod or _force_mask()) else "off (staging)"
    return json.loads(json.dumps(payload, default=str))


# --- tools: session ----------------------------------------------------------------------


@mcp.tool()
def list_targets() -> dict:
    """List every Redis target, its tunnel spec, and whether a tunnel is currently open.

    Touches nothing remote — use it to sanity-check setup before querying and to see what
    `disconnect` would close."""
    _refresh_targets()
    out = []
    if not TARGETS:
        return {
            "targets": [],
            "unrecognized": UNRECOGNIZED,
            "prod_allowed": triage_policy.prod_allowed(),
            "hint": "no targets configured — copy scripts/redis/.env.example to scripts/redis/.env "
                    "and declare a REDISPROD_<NAME> (production) or REDISSTG_<NAME> (staging) "
                    "spec (see scripts/redis/README.md)",
        }
    for key, t in TARGETS.items():
        tun = _tunnels.get(key)
        out.append(
            {
                "target": key,
                "env": t.env,
                "env_var": t.var,
                "vm": t.vm or None,
                "zone": t.zone or None,
                "forward": f"127.0.0.1:{t.local_port} -> {t.remote_host}:{t.remote_port}",
                "tunnel": t.tunnel,
                "is_prod": t.is_prod,
                "tunnel_open": tun is not None and gcloud_tunnel.is_alive(tun),
                "idle_seconds": round(time.time() - tun.last_used, 1) if tun else None,
            }
        )
    return {
        "targets": out,
        "unrecognized": UNRECOGNIZED,
        "prod_allowed": triage_policy.prod_allowed(),
        "idle_timeout_seconds": IDLE_TIMEOUT_S,
    }


@mcp.tool()
def tunnel_status() -> dict:
    """Report the live tunnel state: which targets are open, who owns each forward (self |
    adopted), how long they have been idle, and how long until the watchdog reaps them. An
    adopted forward (a person's own, identified and proven) is never stopped by the MCP."""
    now = time.time()
    with _lock:
        entries = []
        for k, tun in _tunnels.items():
            adopted = tun.adopted_pid is not None
            idle_s = now - tun.last_used
            entries.append({
                "target": k,
                "env": k.split(":", 1)[0],
                "env_var": tun.spec.label,
                "owner": "adopted" if adopted else "self",
                "owner_detail": tun.owner_detail or None,
                "teardown": (
                    "never stopped by the MCP — started outside it; disconnect or idle only drops "
                    "the MCP's connection. Stop it yourself (Ctrl-C in its terminal)."
                    if adopted else
                    f"released on disconnect or after {IDLE_TIMEOUT_S} s idle"
                ),
                "tunnel_open": gcloud_tunnel.is_alive(tun),
                "pid": tun.proc.pid if tun.proc is not None else tun.adopted_pid,
                "up_seconds": round(now - tun.opened_at, 1),
                "idle_seconds": round(idle_s, 1),
                "reaped_in_seconds": max(0.0, round(IDLE_TIMEOUT_S - idle_s, 1)),
            })
    return {"open": entries, "idle_timeout_seconds": IDLE_TIMEOUT_S}


@mcp.tool()
def disconnect() -> dict:
    """Close every open tunnel and connection — the teardown for a triage job. Call it when the
    investigation is done; the watchdog also reaps anything idle past the timeout. An adopted
    forward (started outside the MCP) is left running and reported under
    `adopted_left_running` — only the MCP's hold on it is released."""
    with _lock:
        adopted = [{"target": k, "pid": tun.adopted_pid}
                   for k, tun in _tunnels.items() if tun.adopted_pid is not None]
        closed = _close_all()
    return {"closed": closed, "open": list(_tunnels), "adopted_left_running": adopted}


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
    _prefix_cases(check)
    offenders = _scan_own_source()
    check(f"no write-command call sites in source ({offenders or 'none'})", not offenders)
    check("no passthrough tool exposed", "execute_command" not in ALLOWED_METHODS)
    check(
        "read-only proxy blocks a write method",
        _proxy_blocks("set") and _proxy_blocks("delete") and _proxy_blocks("xadd"),
    )
    # Synthetic targets: the masking rules must be testable on a machine with no .env at all.
    prod = Target("t_prod", "127.0.0.1", 6379, 6399, "prod", "none", "", "")
    staging = Target("t_stg", "127.0.0.1", 6379, 6398, "staging", "none", "", "")
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
    check("refusals name THIS script's tunnel.sh", gcloud_tunnel.TUNNEL_SH == "scripts/redis/tunnel.sh")
    _t_iap = _parse_target("staging", "X", "host=h;local=6390;vm=v;project=p;iap=true")
    check("target parses project= and iap=", _t_iap.project == "p" and _t_iap.iap is True)
    check("iap defaults off (argv unchanged for existing specs)",
          _parse_target("staging", "X", "host=h;local=6390;vm=v").iap is False)
    check("spec carries zone/project/iap into the helper argv",
          "--tunnel-through-iap" in gcloud_tunnel.argv(_spec(_t_iap))
          and "--project=p" in gcloud_tunnel.argv(_spec(_t_iap)))

    # Adopted forward is never stopped: every MCP teardown path against a live stand-in process.
    # Hermetic — a `sleep` plays the person's ssh; no gcloud, no Redis.
    import subprocess as _sp
    _adopt_t = Target("_selftest_adopt", "h", 6379, 65431, "staging", "gcloud", "v", "", "", False)
    _sleeper = _sp.Popen(["sleep", "60"])
    _victim = _sp.Popen(["sleep", "60"])  # a self-owned tunnel the reaper MUST kill (contrast)

    def _adopted(last_used: float) -> gcloud_tunnel.Tunnel:
        return gcloud_tunnel.Tunnel(spec=_spec(_adopt_t), proc=None, log_path=None, opened_at=time.time(),
                                    last_used=last_used, adopted_pid=_sleeper.pid, owner_detail="stand-in")
    try:
        with _lock:
            _tunnels[_adopt_t.key] = _adopted(time.time())
        entry = next(e for e in tunnel_status()["open"] if e["target"] == _adopt_t.key)
        check("adopted: tunnel_status owner=adopted", entry["owner"] == "adopted")
        check("adopted: tunnel_status pid is the real pid", entry["pid"] == _sleeper.pid)
        check("adopted: tunnel_status carries owner_detail", entry["owner_detail"] == "stand-in")
        check("adopted: tunnel_status teardown says never stopped", "never stopped" in entry["teardown"])

        closed = disconnect()
        check("adopted: disconnect releases the hold", _adopt_t.key in closed["closed"])
        check("adopted: disconnect reports adopted_left_running",
              [e["target"] for e in closed["adopted_left_running"]] == [_adopt_t.key])
        check("adopted: disconnect leaves the process running", _sleeper.poll() is None)

        _victim_t = Target("_selftest_victim", "h", 6379, 65430, "staging", "gcloud", "v", "", "", False)
        with _lock:
            _tunnels[_adopt_t.key] = _adopted(0.0)   # idle since the epoch -> reaped on this tick
            _tunnels[_victim_t.key] = gcloud_tunnel.Tunnel(
                spec=_spec(_victim_t), proc=_victim, log_path=None, opened_at=0.0, last_used=0.0)
        _reap_once(time.time())
        with _lock:
            check("adopted: reaper drops the entry", _adopt_t.key not in _tunnels)
            check("contrast: reaper drops the self-owned entry", _victim_t.key not in _tunnels)
        check("adopted: reaper leaves the process running", _sleeper.poll() is None)
        check("contrast: reaper DOES stop a self-owned tunnel", _victim.poll() is not None)

        with _lock:
            _tunnels[_adopt_t.key] = _adopted(time.time())
        _close_all()
        with _lock:
            check("adopted: _close_all clears the entry", not _tunnels)
        check("adopted: _close_all leaves the process running", _sleeper.poll() is None)
    finally:
        with _lock:
            _tunnels.pop(_adopt_t.key, None)
        for _p in (_sleeper, _victim):
            if _p.poll() is None:
                _p.kill()
            _p.wait()
    print("selftest ok" if not failures else f"selftest FAILED ({len(failures)} check(s))")
    return 1 if failures else 0


def _bad_spec_reported() -> bool:
    """A malformed target spec must raise a named error rather than resolve to something odd."""
    try:
        _parse_target("staging", "BROKEN", "port=6379")
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
    """With the opt-in off, connecting to a REDISPROD_ target must be refused BEFORE a tunnel is
    spawned — asserted on a synthetic target, so it holds on a machine with no env file. With
    the opt-in on there is nothing to assert offline."""
    if triage_policy.prod_allowed():
        return True
    try:
        _connect(Target("_selftest_gate", "127.0.0.1", 6379, 65429, "prod", "gcloud", "v", "z"), 0)
        return False
    except PermissionError:
        return True
    except Exception:
        return False  # anything else means it got past the gate and tried to connect


def _prefix_cases(check) -> None:
    """The REDISPROD_/REDISSTG_ split, on a synthetic environment: the PREFIX decides whether a
    target is production — never a key inside the value."""
    spec = "host=h;local={};tunnel=none"
    env = {
        "REDISPROD_MAIN": spec.format(6390),
        "REDISSTG_MAIN": spec.format(6391),
        "REDISSTG_ONLY": spec.format(6392),
        "REDISPROD_OLD": spec.format(6393) + ";prod=false",      # old-style line
        "REDISSTG_LEFTOVER": spec.format(6394) + ";prod=true",   # leftover key
        "REDISPROD_wrong_case": spec.format(6395),
        "REDISSTG_MAIN_": spec.format(6396),                     # malformed name
        "REDISPROD_": spec.format(6397),
        "UNRELATED": "x",
    }
    targets, bad = _load_targets(env)
    check("REDISPROD_ declares a prod target", targets.get("prod:main") is not None and targets["prod:main"].is_prod)
    check("REDISSTG_ declares a staging target",
          targets.get("staging:main") is not None and not targets["staging:main"].is_prod)
    check("target carries its env and its real variable name",
          targets["prod:main"].env == "prod" and targets["prod:main"].var == "REDISPROD_MAIN"
          and targets["staging:only"].var == "REDISSTG_ONLY")
    check("same NAME under both prefixes is two targets", targets["prod:main"] is not targets["staging:main"])
    check("qualified form resolves each", _resolve("prod:main", targets).is_prod
          and not _resolve("staging:main", targets).is_prod)
    try:
        _resolve("main", targets)
        ambiguous = False
    except ValueError as exc:
        ambiguous = "prod:main" in str(exc) and "staging:main" in str(exc)
    check("bare ambiguous name is refused, listing both qualified forms", ambiguous)
    check("bare unambiguous name resolves", _resolve("only", targets).key == "staging:only")
    by_var = {b["var"]: b for b in bad}
    check("no silent drop: every unusable var is reported",
          set(by_var) == {"REDISPROD_OLD", "REDISSTG_LEFTOVER", "REDISPROD_wrong_case", "REDISSTG_MAIN_", "REDISPROD_"})
    check("leftover prod= key is refused with the fixed reason",
          by_var.get("REDISSTG_LEFTOVER", {}).get("reason") == REASON_PROD_KEY
          and by_var.get("REDISPROD_OLD", {}).get("reason") == REASON_PROD_KEY)
    check("old-style prod=false never becomes a gated prod target",
          "prod:old" not in targets and "staging:old" not in targets)
    check("wrong-case name is reported with a did-you-mean",
          by_var.get("REDISPROD_wrong_case", {}).get("reason") == REASON_UPPER
          and by_var["REDISPROD_wrong_case"].get("did_you_mean") == "REDISPROD_WRONG_CASE")
    check("malformed name is reported with the closest configured var",
          by_var.get("REDISSTG_MAIN_", {}).get("did_you_mean") == "REDISSTG_MAIN")
    check("a report never carries a value",
          all("h;local" not in json.dumps(b) for b in bad))
    check("masking keys on the prefix: prod on, staging off",
          _ok(targets["prod:main"], {})["masking"] == "on"
          and _ok(targets["staging:main"], {})["masking"].startswith("off"))
    check("staging target is not gated",
          not _gate_refuses(targets["staging:main"]))
    check("tunnel label carries the real variable name",
          _spec(targets["prod:main"]).label == "REDISPROD_MAIN"
          and _spec(targets["staging:main"]).label == "REDISSTG_MAIN")


def _gate_refuses(t: Target) -> bool:
    try:
        triage_policy.assert_prod_allowed("x") if t.is_prod else None
        return False
    except PermissionError:
        return True


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
