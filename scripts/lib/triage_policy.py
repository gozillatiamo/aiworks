"""triage_policy — resolve the workspace's deployed-env triage policy, in-process.

The triage MCP servers (`scripts/db/pg_triage_mcp.py`, `scripts/redis/redis_triage_mcp.py`)
reach **staging** and **production**. Staging needs no gate: it is not the prod boundary, and
reaching it costs nothing anyone has to authorize. Production does — so the policy that decides
it must be enforced where the connection is actually opened, i.e. inside the server:

    triage:
      enabled: true    # registration — false keeps the servers out of every session
      prod: false      # per-machine opt-in for PRODUCTION targets

`enabled` is read by `scripts/triage-mcp.sh` (registration is a shell concern). `prod` is read
HERE, per call, because a flag that only existed at `claude mcp add` time would freeze into
`~/.claude.json` and drift from the config that claims to own it. Reading it live means editing
the YAML has an effect immediately — no re-register, no session restart.

Resolution is LOCAL-FIRST — `workspace.config.local.yaml` (git-ignored, personal) wins over
`workspace.config.yaml` (shared) — because who may touch production is a per-person decision.
See docs/adr/0003 and docs/adr/0005.

The parse is a deliberate 20-line reader rather than a YAML dependency: it is the same
section+key scan `scripts/triage-mcp.sh` does in awk, and the two must agree on a two-key
policy. Values are cached per file mtime, so a per-call read is a `stat`, not a re-parse.

  uv run scripts/lib/triage_policy.py status      # resolved policy + where each value came from
  uv run scripts/lib/triage_policy.py projects    # this workspace's GCP project ids (monitoring.targets values)
  uv run scripts/lib/triage_policy.py targets     # <product>/<env>\\t<project-id>, one per line
  uv run scripts/lib/triage_policy.py --selftest  # parse/precedence/default cases, no config edits
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

# scripts/lib/triage_policy.py -> workspace root. TRIAGE_POLICY_ROOT overrides it, which is what
# lets --selftest exercise real files in a temp dir instead of mocking the reader.
LOCAL_FILE = "workspace.config.local.yaml"
SHARED_FILE = "workspace.config.yaml"
SECTION = "triage"
DEAD_KEY_SECTION = "prod_triage"  # the pre-0005 key; removed, never honoured (docs/adr/0005)

DEFAULTS = {"enabled": True, "prod": False}

_TRUE = {"true", "yes", "1", "on"}
_FALSE = {"false", "no", "0", "off"}

_SECTION_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
_ENTRY_RE = re.compile(r"^\s{1,4}([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$")

_cache: dict[Path, tuple[float, dict[str, dict[str, str]]]] = {}


def root() -> Path:
    override = os.environ.get("TRIAGE_POLICY_ROOT")
    if override:
        return Path(override)
    return Path(__file__).resolve().parent.parent.parent


def _clean(raw: str) -> str:
    v = re.sub(r"\s+#.*$", "", raw).strip()
    return v.strip("'\"")


def _parse(path: Path) -> dict[str, dict[str, str]]:
    """{section: {key: raw_value}} for the sections this module cares about. Cached on mtime."""
    try:
        stat = path.stat()
    except OSError:
        return {}
    hit = _cache.get(path)
    if hit and hit[0] == stat.st_mtime:
        return hit[1]
    out: dict[str, dict[str, str]] = {}
    section = ""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        top = _SECTION_RE.match(line)
        if top:
            section = top.group(1)
            continue
        if section in (SECTION, DEAD_KEY_SECTION):
            entry = _ENTRY_RE.match(line)
            if entry:
                out.setdefault(section, {})[entry.group(1)] = _clean(entry.group(2))
    _cache[path] = (stat.st_mtime, out)
    return out


def _as_bool(value: str) -> bool | None:
    v = value.lower()
    if v in _TRUE:
        return True
    if v in _FALSE:
        return False
    return None


def resolve(key: str) -> tuple[bool, str]:
    """(value, source) for one `triage.<key>`, local-first, falling back to the documented
    default. `source` is a human-readable provenance string for status output and errors."""
    for name in (LOCAL_FILE, SHARED_FILE):
        parsed = _parse(root() / name)
        raw = parsed.get(SECTION, {}).get(key)
        if raw is None:
            continue
        val = _as_bool(raw)
        if val is None:
            continue  # a non-boolean is treated as absent; the default is safer than a guess
        return val, name
    return DEFAULTS[key], f"default ({SECTION}.{key} absent)"


def enabled() -> bool:
    """Whether the triage MCP servers should be registered at all (default true)."""
    return resolve("enabled")[0]


def prod_allowed() -> bool:
    """Whether THIS machine may open a PRODUCTION connection (default false)."""
    return resolve("prod")[0]


def _parse_targets(path: Path) -> dict[str, str]:
    """Read `monitoring.targets` — a flat `<product>/<env>: <project-id>` mapping.

    Deliberately hand-parsed rather than pulling in PyYAML: the block is two levels deep and one
    value type, and a triage server that cannot start because a dependency failed to resolve is
    worse than one that understands a narrow slice of YAML. Anything more elaborate than this
    shape belongs in the example config as prose, not in the live file (docs/adr/0006). Not
    routed through `_parse()` (`SECTION`/`DEAD_KEY_SECTION` only, one level deep) — `targets` is
    two levels deep and needs its own scan.
    """
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    in_monitoring = False
    in_targets = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*:", line):  # a new top-level section
            in_monitoring = line.startswith("monitoring:")
            in_targets = False
            continue
        if not in_monitoring:
            continue
        if re.match(r"^\s{1,2}targets:\s*$", line):
            in_targets = True
            continue
        if re.match(r"^\s{1,2}[A-Za-z_]", line):  # another key at the monitoring level
            in_targets = False
            continue
        if in_targets:
            m = re.match(r"^\s{3,6}([A-Za-z0-9_.-]+/[A-Za-z0-9_-]+):\s*([A-Za-z0-9_.-]+)\s*$", line)
            if m:
                out[m.group(1)] = m.group(2)
    return out


def monitoring_targets() -> dict[str, str]:
    """`<product>/<env>` -> GCP project id, from `monitoring.targets`. Local-first per key: shared
    supplies every key, local overrides individually (same precedence as `resolve()`)."""
    merged: dict[str, str] = {}
    for name in (SHARED_FILE, LOCAL_FILE):  # shared first, then local wins per key
        merged.update(_parse_targets(root() / name))
    return merged


def workspace_projects() -> set[str]:
    """The GCP project ids this workspace declares — the k8s-triage scope allowlist. Empty means
    this workspace has not declared `monitoring.targets` anywhere (docs/adr/0039)."""
    return set(monitoring_targets().values())


def dead_key_present() -> str | None:
    """The config file still carrying the removed `prod_triage.enabled` key, if any.

    There is no fallback to it by design (docs/adr/0005) — a stale key would silently decide
    production access. Callers surface this as a loud warning instead."""
    for name in (LOCAL_FILE, SHARED_FILE):
        if "enabled" in _parse(root() / name).get(DEAD_KEY_SECTION, {}):
            return name
    return None


def assert_prod_allowed(what: str = "production") -> None:
    """Raise unless production is opted in on this machine. Called BEFORE any DSN lookup or
    connection, so a machine without the opt-in never reaches prod even with credentials
    present."""
    if prod_allowed():
        return
    value, source = resolve("prod")
    dead = dead_key_present()
    hint = (
        f" (note: {dead} still sets the REMOVED key `prod_triage.enabled` — it is ignored; "
        f"rename it to `triage.prod`)"
        if dead
        else ""
    )
    raise PermissionError(
        f"{what} is not enabled on this machine: triage.prod = {str(value).lower()} "
        f"[{source}]. Set `triage.prod: true` under `triage:` in {LOCAL_FILE} "
        f"(git-ignored, personal) to opt in — staging needs no opt-in.{hint}"
    )


# --- entrypoint ---------------------------------------------------------------------------


def _projects() -> int:
    """One workspace GCP project id per line, sorted, no header — a plain word list a shell
    script can `read` line by line. Empty output (exit 0) means unscoped."""
    for project in sorted(workspace_projects()):
        print(project)
    return 0


def _targets() -> int:
    """One `<product>/<env>\\t<project-id>` line per monitoring.targets entry, sorted by key.
    Empty output (exit 0) means none declared — monitoring-only bootstrap fails closed on that."""
    for key, project in sorted(monitoring_targets().items()):
        print(f"{key}\t{project}")
    return 0


def _status() -> int:
    print(f"root: {root()}")
    for key in ("enabled", "prod"):
        value, source = resolve(key)
        print(f"  triage.{key:<8} = {str(value).lower():<5} ({source})")
    dead = dead_key_present()
    if dead:
        print(f"  ! {dead} still sets `prod_triage.enabled` — REMOVED key, ignored (docs/adr/0005)")
    return 0


def _selftest() -> int:
    import shutil
    import tempfile

    failures = 0

    def check(label: str, cond: bool, detail: str = "") -> None:
        nonlocal failures
        if not cond:
            failures += 1
        print(f"  {'ok  ' if cond else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")

    tmp = Path(tempfile.mkdtemp(prefix="triage-policy-selftest-"))
    prev = os.environ.get("TRIAGE_POLICY_ROOT")
    os.environ["TRIAGE_POLICY_ROOT"] = str(tmp)
    try:
        # 1) no config at all -> documented defaults
        _cache.clear()
        check("no config: enabled defaults true", enabled() is True)
        check("no config: prod defaults false", prod_allowed() is False)

        # 2) shared file alone is honoured
        (tmp / SHARED_FILE).write_text("language: en\ntriage:\n  enabled: true\n  prod: true\n")
        _cache.clear()
        check("shared file: prod true", prod_allowed() is True, resolve("prod")[1])

        # 3) local file wins over shared (ADR-0003)
        (tmp / LOCAL_FILE).write_text("triage:\n  prod: false\n")
        _cache.clear()
        check("local overrides shared", prod_allowed() is False, resolve("prod")[1])
        check("shared still supplies untouched keys", resolve("enabled") == (True, SHARED_FILE))

        # 4) a comment on the value line must not leak into the parse
        (tmp / LOCAL_FILE).write_text("triage:\n  prod: true   # temporary, for APP-123\n")
        _cache.clear()
        check("inline comment stripped", prod_allowed() is True)

        # 5) mtime cache must not serve a stale value after an edit
        (tmp / LOCAL_FILE).write_text("triage:\n  prod: false\n")
        os.utime(tmp / LOCAL_FILE, (0, 0))  # force a different mtime than the write above
        check("edit is picked up without clearing the cache", prod_allowed() is False)

        # 6) the removed key is reported, never honoured — in BOTH files, so a leftover key
        # cannot grant prod through either resolution step
        (tmp / LOCAL_FILE).write_text("prod_triage:\n  enabled: true\n")
        (tmp / SHARED_FILE).write_text("language: en\nprod_triage:\n  enabled: true\n")
        _cache.clear()
        check("removed prod_triage.enabled does NOT grant prod", prod_allowed() is False)
        check("removed key is reported", dead_key_present() == LOCAL_FILE)

        # 7) assert_prod_allowed raises with the new key named, and passes when opted in
        try:
            assert_prod_allowed("prod pg triage")
            check("assert_prod_allowed raises when off", False)
        except PermissionError as exc:
            check("assert_prod_allowed raises when off", "triage.prod: true" in str(exc))
            check("error names the removed key when present", "prod_triage.enabled" in str(exc))
        (tmp / LOCAL_FILE).write_text("triage:\n  prod: true\n")
        _cache.clear()
        try:
            assert_prod_allowed()
            check("assert_prod_allowed passes when on", True)
        except PermissionError as exc:
            check("assert_prod_allowed passes when on", False, str(exc))

        # 8) a non-boolean value falls back rather than guessing
        (tmp / LOCAL_FILE).write_text("triage:\n  prod: maybe\n")
        (tmp / SHARED_FILE).write_text("triage:\n  prod: false\n")
        _cache.clear()
        check("non-boolean falls through to the next file", prod_allowed() is False)

        # 9) monitoring.targets absent -> empty mapping and empty project set
        _cache.clear()
        check("no monitoring.targets: empty mapping", monitoring_targets() == {})
        check("no monitoring.targets: empty project set", workspace_projects() == set())

        # 10) shared-only block parsed; a key after `targets:` at the monitoring level ends it,
        # so anything indented under THAT key is not mistaken for another target
        (tmp / LOCAL_FILE).write_text("")
        (tmp / SHARED_FILE).write_text(
            "monitoring:\n"
            "  targets:\n"
            "    app/staging: proj-a\n"
            "    app/prod: proj-a\n"
            "  other_key: ignored\n"
            "    app/leaked: proj-x\n"
        )
        _cache.clear()
        check(
            "shared-only targets parsed, a later monitoring key ends the block",
            monitoring_targets() == {"app/staging": "proj-a", "app/prod": "proj-a"},
        )
        check("workspace_projects is the set of values", workspace_projects() == {"proj-a"})

        # 11) local overrides one key's project; shared supplies the rest (same precedence as
        # every other key this module resolves)
        (tmp / LOCAL_FILE).write_text("monitoring:\n  targets:\n    app/prod: proj-b\n")
        _cache.clear()
        check(
            "local overrides one key, shared supplies the rest",
            monitoring_targets() == {"app/staging": "proj-a", "app/prod": "proj-b"},
        )
        check("workspace_projects reflects the override", workspace_projects() == {"proj-a", "proj-b"})

        import contextlib
        import io

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            _targets()
        check(
            "targets CLI prints key\\tproject sorted",
            buf.getvalue() == "app/prod\tproj-b\napp/staging\tproj-a\n",
        )

        # 12) a comment line or a blank line inside the block is ignored, not treated as an entry
        (tmp / LOCAL_FILE).write_text("")
        (tmp / SHARED_FILE).write_text(
            "monitoring:\n"
            "  targets:\n"
            "    # a comment inside the block\n"
            "\n"
            "    app/staging: proj-a\n"
        )
        _cache.clear()
        check(
            "comment/blank line inside targets: is ignored",
            monitoring_targets() == {"app/staging": "proj-a"},
        )

        # 13) a malformed entry (no product/env slash) is skipped, not raised
        (tmp / SHARED_FILE).write_text(
            "monitoring:\n  targets:\n    noSlashHere: proj-a\n    app/staging: proj-b\n"
        )
        _cache.clear()
        check(
            "a malformed entry with no '/' is skipped",
            monitoring_targets() == {"app/staging": "proj-b"},
        )
    finally:
        if prev is None:
            os.environ.pop("TRIAGE_POLICY_ROOT", None)
        else:
            os.environ["TRIAGE_POLICY_ROOT"] = prev
        _cache.clear()
        shutil.rmtree(tmp, ignore_errors=True)

    print("selftest ok" if not failures else f"{failures} check(s) FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    if len(sys.argv) > 1 and sys.argv[1] == "projects":
        raise SystemExit(_projects())
    if len(sys.argv) > 1 and sys.argv[1] == "targets":
        raise SystemExit(_targets())
    raise SystemExit(_status())
