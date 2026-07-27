# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "redis>=5.0",
# ]
# ///
"""replay_shape — rebuild a Redis SHAPE locally from a `capture_shape` descriptor.

The companion to the `capture_shape` tool in redis_triage_mcp.py, and the only sanctioned way
production Redis state reaches a local machine: what crosses the boundary is a schema — key
type, TTL, cardinality, field names, value KINDS — and every value written here is
synthesized locally from that schema. No production value is ever in the descriptor, so
there is nothing to mask at this end.

  1. Writes to LOCAL Redis only. A non-loopback URL is refused, so a descriptor can never be
     replayed back into a deployed environment.
  2. Every key is namespaced under one prefix (default `repro:<label>:`), so `--teardown`
     removes exactly what was written and nothing else.
  3. Synthesis is deterministic (fixed seed), so two replays of one descriptor are identical
     and a repro is reproducible.

It cannot recreate consumer-group PEL state — delivery counts and idle times are server-side
history. For a wedged-consumer bug, read the live group with `stream_groups` /
`stream_pending` and fix forward with a test.

  uv run scripts/redis/replay_shape.py --shape shape.json --label OFB-123
  uv run scripts/redis/replay_shape.py --shape shape.json --label OFB-123 --dry-run
  uv run scripts/redis/replay_shape.py --label OFB-123 --teardown
"""

from __future__ import annotations

import argparse
import json
import random
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

import redis

LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1", ""}
DEFAULT_URL = "redis://127.0.0.1:6379"
MAX_STREAM_ENTRIES = 50
_rand = random.Random(20260727)

_KIND_JSON = re.compile(r"^json\{(.*)\}$", re.DOTALL)
_KIND_SIZED = re.compile(r"^(string|opaque_token|json_array)\[(\d+)\]$")


def _assert_local(url: str) -> redis.Redis:
    host = urlparse(url).hostname or ""
    if host not in LOCAL_HOSTS:
        raise SystemExit(
            f"refusing to write to {host!r}: replay_shape only writes to LOCAL Redis "
            f"({' | '.join(sorted(h for h in LOCAL_HOSTS if h))})"
        )
    return redis.Redis.from_url(url, decode_responses=True)


def _split_fields(body: str) -> list[str]:
    """Split `k:v,k2:v2` at depth 0 so a nested json{...} kind stays intact."""
    out, depth, cur = [], 0, ""
    for ch in body:
        if ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
            continue
        cur += ch
    if cur.strip():
        out.append(cur)
    return out


def _synth(kind: str | None):
    """Turn a value KIND into a synthetic value of the same shape."""
    if not kind or kind == "null":
        return ""
    if kind == "integer":
        return str(_rand.randrange(1, 10**6))
    if kind == "float":
        return f"{_rand.uniform(0, 1000):.6f}"
    m = _KIND_JSON.match(kind)
    if m:
        obj = {}
        for part in _split_fields(m.group(1)):
            if ":" not in part:
                continue
            name, _, sub = part.partition(":")
            obj[name.strip()] = _synth(sub.strip())
        return json.dumps(obj, ensure_ascii=False)
    m = _KIND_SIZED.match(kind)
    if m:
        what, size = m.group(1), int(m.group(2))
        if what == "opaque_token":
            return "".join(_rand.choice("abcdef0123456789") for _ in range(min(size, 512)))
        if what == "json_array":
            return json.dumps([_rand.randrange(1, 1000) for _ in range(min(size, 20))])
        return "x" * min(size, 512)
    return "synthetic"


def _write(client: redis.Redis, key: str, shape: dict, dry: bool, log: list[str]) -> None:
    ktype = shape.get("type")
    card = shape.get("cardinality") or 0
    ttl = shape.get("ttl_seconds", -1)
    if ktype == "string":
        value = _synth(shape.get("value_kind"))
        log.append(f"SET {key} ({len(value)}B synthetic)")
        if not dry:
            client.set(key, value)
    elif ktype == "hash":
        fields = {name: _synth(kind) for name, kind in (shape.get("fields") or {}).items()}
        log.append(f"HSET {key} ({len(fields)} synthetic fields)")
        if not dry and fields:
            client.hset(key, mapping=fields)
    elif ktype == "list":
        n = min(card, MAX_STREAM_ENTRIES)
        log.append(f"RPUSH {key} x{n}")
        if not dry and n:
            client.rpush(key, *[f"item-{i}" for i in range(n)])
    elif ktype == "set":
        n = min(card, MAX_STREAM_ENTRIES)
        log.append(f"SADD {key} x{n}")
        if not dry and n:
            client.sadd(key, *[f"member-{i}" for i in range(n)])
    elif ktype == "zset":
        scores = shape.get("score_sample") or [float(i) for i in range(min(card, 5) or 1)]
        log.append(f"ZADD {key} x{len(scores)} (score sample preserved)")
        if not dry:
            client.zadd(key, {f"member-{i}": s for i, s in enumerate(scores)})
    elif ktype == "stream":
        fields = shape.get("fields") or {}
        n = min(card, MAX_STREAM_ENTRIES)
        log.append(f"XADD {key} x{n} ({len(fields)} fields) — server-generated ids, PEL not reproducible")
        if not dry:
            for _ in range(max(n, 1)):
                client.xadd(key, {name: _synth(kind) for name, kind in fields.items()} or {"_": "1"})
            for group in shape.get("groups") or []:
                try:
                    client.xgroup_create(key, group, id="0", mkstream=True)
                    log.append(f"XGROUP CREATE {key} {group} (empty PEL — delivery counts cannot be replayed)")
                except redis.ResponseError:
                    pass
    else:
        log.append(f"skip {key} (unsupported type {ktype!r})")
        return
    if isinstance(ttl, int) and ttl > 0:
        log.append(f"EXPIRE {key} {ttl}")
        if not dry:
            client.expire(key, ttl)


def _teardown(client: redis.Redis, prefix: str) -> int:
    cursor, removed = 0, 0
    while True:
        cursor, batch = client.scan(cursor=cursor, match=f"{prefix}*", count=500)
        if batch:
            removed += client.delete(*batch)
        if cursor == 0:
            return removed


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Replay a captured Redis shape into LOCAL Redis.")
    ap.add_argument("--shape", help="capture_shape JSON file ('-' for stdin)")
    ap.add_argument("--label", required=True, help="repro label, e.g. a ticket key")
    ap.add_argument("--url", default=DEFAULT_URL, help=f"local Redis URL (default {DEFAULT_URL})")
    ap.add_argument("--db", type=int, default=0)
    ap.add_argument("--dry-run", action="store_true", help="print what would be written, write nothing")
    ap.add_argument("--teardown", action="store_true", help="delete every key under the label's prefix")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return _selftest()

    prefix = f"repro:{args.label}:"
    client = _assert_local(args.url)
    if args.db:
        client = redis.Redis.from_url(args.url, db=args.db, decode_responses=True)

    if args.teardown:
        removed = _teardown(client, prefix)
        print(f"teardown: removed {removed} key(s) under {prefix}")
        return 0

    if not args.shape:
        ap.error("--shape is required unless --teardown")
    raw = sys.stdin.read() if args.shape == "-" else Path(args.shape).read_text()
    doc = json.loads(raw)
    shapes = doc.get("shapes", doc if isinstance(doc, list) else [])
    log: list[str] = []
    written = 0
    for shape in shapes:
        if not shape.get("exists"):
            continue
        _write(client, prefix + shape["key"], shape, args.dry_run, log)
        written += 1
    for line in log:
        print(f"  {line}")
    print(
        f"{'would write' if args.dry_run else 'wrote'} {written} key(s) under {prefix} "
        f"— teardown with: --label {args.label} --teardown"
    )
    return 0


def _selftest() -> int:
    failures = []

    def check(desc: str, cond: bool) -> None:
        print(f"  {'ok  ' if cond else 'FAIL'} {desc}")
        if not cond:
            failures.append(desc)

    print("replay_shape selftest (no Redis access)")
    try:
        _assert_local("redis://10.148.0.60:6379")
        check("refuses a non-local URL", False)
    except SystemExit:
        check("refuses a non-local URL", True)
    check("integer kind synthesizes a number", _synth("integer").isdigit())
    check("token kind keeps the length", len(_synth("opaque_token[64]")) == 64)
    nested = json.loads(_synth("json{player_code:string[13],balance:integer}"))
    check("json kind rebuilds the field set", set(nested) == {"player_code", "balance"})
    check("json kind keeps field length", len(nested["player_code"]) == 13)
    check("split handles a nested json kind", len(_split_fields("a:json{x:integer,y:integer},b:integer")) == 2)
    _rand.seed(1)
    first = _synth("integer")
    _rand.seed(1)
    check("synthesis is deterministic", _synth("integer") == first)
    print("selftest ok" if not failures else f"selftest FAILED ({len(failures)})")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
