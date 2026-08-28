#!/usr/bin/env python3
"""Reconcile machine-local triage MCP registrations for Codex and Cursor."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path

from config import active, registry


SERVERS = {
    "pg_triage": "scripts/db/pg_triage_mcp.py",
    "redis_triage": "scripts/redis/redis_triage_mcp.py",
    "k8s_triage": "scripts/k8s/k8s_triage_mcp.py",
    "monitoring_triage": "scripts/monitoring/monitoring_triage_mcp.py",
}


def selected(root: Path) -> set[str]:
    entries = registry()
    values = active(
        root / "workspace.config.yaml",
        root / "workspace.config.local.yaml",
        entries,
        fallback=True,
    )
    return set(values or [])


def expected(root: Path, relative: str) -> dict:
    return {"command": "uv", "args": ["run", "--quiet", str(root / relative)]}


def ours(command: str, args: list[str], relative: str) -> bool:
    """True for a DEAD registration this script wrote from a workspace root that is gone.

    Two conditions, and the second is not optional. The shape
    `uv run --quiet <anything>/<relative>` — exactly three args, no extra flags — is only ever
    produced here, so an entry matching it is this script's own past output. But shape alone
    does not make it stale: Codex has no per-project scope and Cursor's config
    (`~/.cursor/mcp.json`) is a single machine-global file, so a SIBLING checkout on the same
    machine sees a perfectly live registration in exactly this shape. Repointing that one takes
    a working server away from the other root — and with `triage.enabled: false` here, the
    deregister branch would delete it outright. So the path must also be GONE, which is the only
    state where "this registration is dead and nothing else wants it" is actually true, and the
    only claim the doctor's finding makes.

    Without the shape test, somebody's hand-made command wins, as it should. Without the
    existence test, a live sibling's registration loses. Both tests, or neither is safe.
    """
    return command == "uv" and args[:2] == ["run", "--quiet"] and len(args) == 3 \
        and args[2].endswith(f"/{relative}") and not Path(args[2]).exists()


def codex_list() -> dict[str, dict]:
    try:
        output = subprocess.run(["codex", "mcp", "list", "--json"], check=True, text=True, capture_output=True).stdout
        return {str(item.get("name")): item for item in json.loads(output)}
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return {}


def codex_args(item: dict) -> tuple[str, list[str]]:
    transport = item.get("transport") or {}
    return str(transport.get("command") or ""), [str(value) for value in transport.get("args") or []]


def reconcile_codex(root: Path, action: str, want: bool, dry: bool) -> int:
    current = codex_list()
    failed = 0
    for name, relative in SERVERS.items():
        desired = expected(root, relative)
        item = current.get(name)
        matches = bool(item) and codex_args(item) == (desired["command"], desired["args"])
        stale = bool(item) and not matches and ours(*codex_args(item), relative)
        if action == "status":
            # "not registered" and "registered at a path that no longer exists" need different
            # words: they read the same in the doctor's output but only one of them is closed by
            # registering something, and the other looks like a foreign entry nobody may touch.
            state = "registered" if matches else ("STALE path; sync repoints it" if stale else "not registered")
            print(f"    {'✓' if matches else '-'} codex/{name} — {state}")
            continue
        if want and matches or not want and not item:
            continue
        if item and not matches and not stale:
            print(f"    ! codex/{name} has a command this script does not own; left unchanged")
            continue
        command = ["codex", "mcp", "add", name, "--", "uv", "run", "--quiet", str(root / relative)] if want else ["codex", "mcp", "remove", name]
        if dry:
            verb = "repoint" if stale and want else ("register" if want else "remove")
            print(f"    - would {verb} codex/{name}")
            continue
        try:
            # `codex mcp add` will not overwrite a name that is already there, so a repoint is
            # remove-then-add. The remove is best-effort: if it fails the add fails loudly next.
            if stale and want:
                subprocess.run(["codex", "mcp", "remove", name], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print(f"    ✓ codex/{name} {'repointed at this root' if stale and want else ('registered' if want else 'removed')}")
        except (OSError, subprocess.SubprocessError):
            print(f"    ! codex/{name} reconciliation failed")
            failed = 1
    return failed


def cursor_config() -> Path:
    override = os.environ.get("AIWORKS_CURSOR_MCP_CONFIG")
    return Path(override) if override else Path.home() / ".cursor" / "mcp.json"


def reconcile_cursor(root: Path, action: str, want: bool, dry: bool) -> int:
    path = cursor_config()
    try:
        data = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
    except json.JSONDecodeError:
        print(f"    ! cursor MCP config is not valid JSON: {path}")
        return 1
    servers = data.setdefault("mcpServers", {})
    changed = False
    for name, relative in SERVERS.items():
        desired = expected(root, relative)
        current = servers.get(name)
        matches = current == desired
        stale = bool(current) and not matches and isinstance(current, dict) and ours(
            str(current.get("command") or ""), [str(v) for v in current.get("args") or []], relative)
        if action == "status":
            state = "registered" if matches else ("STALE path; sync repoints it" if stale else "not registered")
            print(f"    {'✓' if matches else '-'} cursor/{name} — {state}")
            continue
        if want and matches or not want and current is None:
            continue
        if current is not None and not matches and not stale:
            print(f"    ! cursor/{name} has a command this script does not own; left unchanged")
            continue
        if dry:
            verb = "repoint" if stale and want else ("register" if want else "remove")
            print(f"    - would {verb} cursor/{name}")
            continue
        if want:
            servers[name] = desired
        else:
            servers.pop(name, None)
        changed = True
        print(f"    ✓ cursor/{name} {'repointed at this root' if stale and want else ('registered' if want else 'removed')}")
    if changed:
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(path.suffix + ".tmp")
        temp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temp.replace(path)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--action", choices=("sync", "on", "off", "status"), required=True)
    parser.add_argument("--want", choices=("0", "1"), required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    harnesses = selected(root)
    want = args.want == "1"
    failed = 0
    if "codex" in harnesses and shutil.which("codex"):
        failed |= reconcile_codex(root, args.action, want, args.dry_run)
    if "cursor" in harnesses:
        failed |= reconcile_cursor(root, args.action, want, args.dry_run)
    return failed


if __name__ == "__main__":
    raise SystemExit(main())
