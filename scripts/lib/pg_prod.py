"""pg_prod — which PRODUCTION env var backs a shard, by DECLARED role rather than by spelling.

Production has one read-only DSN per target. Sharding is OPT-IN: a target only plays a shard
role when its var declares one, in one of two ways, both valid at once:

    PGPROD_<LABEL>_SHARD_<HEX>=<dsn>             the literal SHARD token, then one hex, as the
                                                 LAST segment; the label is free-form and never
                                                 inspected (PGPROD_HOST1_SHARD_0, PGPROD_SHARD_0)
    PGPROD_<NAME>=<dsn>                          any UPPER_SNAKE name with no SHARD segment ...
    PGPROD_<NAME>_SHARD=<hex>                    ... plus a sidecar declaring its shard role

So a label rename (`PGPROD_HOST1_SHARD_0` -> `PGPROD_HOST12_SHARD_0`) needs no source change. A
name with no SHARD segment and no sidecar (`PGPROD_REPORTING`) is an ordinary named target and
claims nothing. A SHARD segment anywhere else (`PGPROD_X_SHARD_00`, `PGPROD_X_SHARD_0_OLD`) is
refused outright — never guessed. A sidecar value is exactly ONE hex `0-f`: one DSN opens one
shard database, so a list (`0,1`) is refused. A token name already declares its own role, so a
`_SHARD` sidecar on it is refused.

Two vars claiming one hex — by any mix of token and sidecar — is a CONFLICT and fails closed:
the shard reads unconfigured and `shard_var` raises naming both vars. The server never picks one
silently — two DSNs for one hex could point shard queries at the wrong database.

It lives in `scripts/lib/` because two tools must agree on it exactly: the read-only triage MCP
(`scripts/db/pg_triage_mcp.py`) and the repro seeder (`scripts/db/prod_repro_seed.py`). Every
message carries var NAMES and fixed strings only — never a value.

  python3 scripts/lib/pg_prod.py --selftest   # synthetic env dicts, no DB access
"""

from __future__ import annotations

import os
import re
import sys
from collections.abc import Mapping

PREFIX = "PGPROD_"
SHARD_SUFFIX = "_SHARD"
TUNNEL_SUFFIX = "_TUNNEL"
TOKEN = "SHARD"
HEX = "0123456789abcdef"
NAME_RE = re.compile(r"^[A-Z0-9]+(_[A-Z0-9]+)*$")  # UPPER_SNAKE; single underscores only

REASON_EMPTY = "empty value"
REASON_MULTILINE = "value spans lines — an unbalanced quote swallowed the lines after it"
REASON_LIST = "one DSN is one database: name ONE hex"
REASON_SHARD = "shard is one hex 0-f"
REASON_SHARD_TOKEN = "SHARD must be followed by exactly one hex 0-f, as the last segment"
REASON_SHARD_SIDECAR_REFUSED = "a name carrying SHARD_<hex> already declares its role; drop the _SHARD sidecar"
REASON_CONFLICT = "shard {hex} is claimed by more than one DSN: {vars}"


def default_var(hex_: str) -> str:
    """The advised var name for a hex nothing claims: 0 -> PGPROD_SHARD_0 (itself a valid name)."""
    return f"{PREFIX}{TOKEN}_{hex_.upper()}"


def name_hex(var: str) -> tuple[str | None, str | None]:
    """Parse the shard role out of a var NAME -> (hex, reason). Never reads a value.

    (None, None)  no SHARD segment: not a shard by name (a named target, or sidecar-declared)
    (hex, None)   exactly one SHARD segment, second-to-last, followed by one hex as the last segment
    (None, reason) a SHARD segment that breaks that rule — refused, never guessed"""
    segs = var[len(PREFIX):].split("_")
    if TOKEN not in segs:
        return None, None
    if segs.count(TOKEN) == 1 and len(segs) >= 2 and segs[-2] == TOKEN and len(segs[-1]) == 1 and segs[-1].lower() in HEX:
        return segs[-1].lower(), None
    return None, REASON_SHARD_TOKEN


def shard_value(raw: str | None) -> tuple[str | None, str | None]:
    """Validate a `_SHARD` sidecar value -> (hex, reason). Exactly one of the two is set."""
    if raw is None or raw.strip() == "":
        return None, REASON_EMPTY
    if "\n" in raw:
        return None, REASON_MULTILINE
    v = raw.strip().lower()
    if len(v) > 1 and any(c in v for c in ",; "):
        return None, REASON_LIST
    if len(v) != 1 or v not in HEX:
        return None, REASON_SHARD
    return v, None


def shard_claims(env: Mapping[str, str]) -> dict[str, list[str]]:
    """hex -> sorted var names claiming it. A claimant is an UPPER_SNAKE `PGPROD_` var with a
    value that either carries a valid SHARD token in its name (and no `_SHARD` sidecar), or has
    a valid `PGPROD_X_SHARD` sidecar. Sidecars and refused names never count."""
    claims: dict[str, list[str]] = {}
    for var, value in env.items():
        if not var.startswith(PREFIX) or not value:
            continue
        if not NAME_RE.match(var[len(PREFIX):]) or var.endswith((SHARD_SUFFIX, TUNNEL_SUFFIX)):
            continue
        hex_, bad = name_hex(var)
        if bad:
            continue
        if hex_:
            if not env.get(var + SHARD_SUFFIX):
                claims.setdefault(hex_, []).append(var)
            continue
        hex_, _ = shard_value(env.get(var + SHARD_SUFFIX))
        if hex_:
            claims.setdefault(hex_, []).append(var)
    return {h: sorted(v) for h, v in claims.items()}


def shard_var(hex_: str, env: Mapping[str, str] | None = None) -> str:
    """The ONE env var backing shard `hex_`; `default_var` when nothing claims it (advice that
    works: that name is itself a valid shard name); ValueError naming every claimant on a conflict."""
    env = os.environ if env is None else env
    claimants = shard_claims(env).get(hex_.lower(), [])
    if len(claimants) > 1:
        raise ValueError(REASON_CONFLICT.format(hex=hex_.lower(), vars=" + ".join(claimants)))
    return claimants[0] if claimants else default_var(hex_)


def _selftest() -> int:
    failures = 0

    def check(label: str, cond: bool, detail: str = "") -> None:
        nonlocal failures
        if not cond:
            failures += 1
        print(f"  {'ok  ' if cond else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")

    dsn = "postgresql://ro:pw@h/db"
    for var, want in (("PGPROD_HOST1_SHARD_0", "0"), ("PGPROD_HOST12_SHARD_0", "0"), ("PGPROD_HOST8_SHARD_F", "f"),
                      ("PGPROD_SHARD_3", "3")):
        check(f"name_hex({var}) -> {want}", name_hex(var) == (want, None), str(name_hex(var)))
    for var in ("PGPROD_HOST1", "PGPROD_HOST1_SHARDS_0", "PGPROD_REPORTING"):
        check(f"name_hex({var}) -> no token", name_hex(var) == (None, None), str(name_hex(var)))
    for var in ("PGPROD_HOST9_SHARD_G", "PGPROD_X_SHARD_00", "PGPROD_X_SHARD_0_OLD", "PGPROD_SHARD_0_SHARD_1",
                "PGPROD_SHARD", "PGPROD_SHARD_MAP"):
        check(f"name_hex({var}) refused", name_hex(var) == (None, REASON_SHARD_TOKEN), str(name_hex(var)))

    check("no claimant -> PGPROD_SHARD_A", shard_var("a", {}) == "PGPROD_SHARD_A")
    check("embedded only", shard_var("0", {"PGPROD_HOST1_SHARD_0": dsn}) == "PGPROD_HOST1_SHARD_0")
    check("named target alone claims nothing", shard_var("0", {"PGPROD_REPORTING": dsn}) == "PGPROD_SHARD_0"
          and shard_claims({"PGPROD_REPORTING": dsn}) == {})
    check("sidecar only", shard_var("0", {"PGPROD_EU1_S0": dsn, "PGPROD_EU1_S0_SHARD": "0"}) == "PGPROD_EU1_S0")
    check("sidecar on a named target is a claim", shard_var("1", {"PGPROD_REPORTING": dsn, "PGPROD_REPORTING_SHARD": "1"})
          == "PGPROD_REPORTING")
    check("sidecar value A accepted as a", shard_var("a", {"PGPROD_X": dsn, "PGPROD_X_SHARD": " A "}) == "PGPROD_X")
    for label, both in (("embedded + embedded", {"PGPROD_HOST1_SHARD_0": dsn, "PGPROD_HOST12_SHARD_0": dsn}),
                        ("embedded + sidecar", {"PGPROD_HOST1_SHARD_0": dsn, "PGPROD_X": dsn, "PGPROD_X_SHARD": "0"})):
        try:
            shard_var("0", both)
            check(f"{label} conflict raises", False, "no error raised")
        except ValueError as exc:
            names = [v for v in both if not v.endswith(SHARD_SUFFIX)]
            check(f"{label} conflict raises naming both vars", all(n in str(exc) for n in names), str(exc))
            check(f"{label} conflict message carries no value", "pw" not in str(exc) and dsn not in str(exc))
            check(f"{label} shard_claims lists both", shard_claims(both) == {"0": sorted(names)})
    for raw, reason in (("0,1", REASON_LIST), ("g", REASON_SHARD), ("", REASON_EMPTY), (None, REASON_EMPTY),
                        ("0\n1", REASON_MULTILINE), ("00", REASON_SHARD)):
        got = shard_value(raw)
        check(f"shard_value({raw!r}) refused", got == (None, reason), str(got))
    for label, env in (("invalid sidecar", {"PGPROD_X": dsn, "PGPROD_X_SHARD": "0,1"}),
                       ("sidecar with no base DSN", {"PGPROD_X_SHARD": "0"}),
                       ("sidecar with empty base DSN", {"PGPROD_X": "", "PGPROD_X_SHARD": "0"}),
                       ("_SHARD on an embedded name", {"PGPROD_HOST1_SHARD_0": dsn, "PGPROD_HOST1_SHARD_0_SHARD": "0"}),
                       ("_SHARD on a malformed token", {"PGPROD_HOST9_SHARD_G": dsn, "PGPROD_HOST9_SHARD_G_SHARD": "0"}),
                       ("_SHARD on a _TUNNEL", {"PGPROD_X_TUNNEL": "tunnel=gost", "PGPROD_X_TUNNEL_SHARD": "0"}),
                       ("lower-case name", {"PGPROD_host1_SHARD_0": dsn}),
                       ("empty embedded var", {"PGPROD_HOST1_SHARD_0": ""})):
        check(f"{label} is not a claimant", shard_claims(env) == {}, str(shard_claims(env)))

    print("selftest ok" if not failures else f"{failures} check(s) FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    claims = shard_claims(os.environ)
    for h in HEX:
        vars_ = claims.get(h, [])
        print(f"  shard {h} -> {' + '.join(vars_) if vars_ else 'unset'}{'  CONFLICT' if len(vars_) > 1 else ''}")
    raise SystemExit(0)
