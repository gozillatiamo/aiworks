#!/usr/bin/env python3
"""Reconcile machine-local triage MCP registrations for Codex and Cursor."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path

from config import configured, registry


SERVERS = {
    "pg_triage": "scripts/db/pg_triage_mcp.py",
    "redis_triage": "scripts/redis/redis_triage_mcp.py",
    "k8s_triage": "scripts/k8s/k8s_triage_mcp.py",
    "monitoring_triage": "scripts/monitoring/monitoring_triage_mcp.py",
}


def selected(root: Path) -> set[str]:
    values = configured(root / "workspace.config.yaml")
    if not values:
        values = [str(item["id"]) for item in registry() if item.get("default_selected")]
    return set(values)


def expected(root: Path, relative: str) -> dict:
    return {"command": "uv", "args": ["run", "--quiet", str(root / relative)]}


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
        if action == "status":
            print(f"    {'✓' if matches else '-'} codex/{name} — {'registered' if matches else 'not registered'}")
            continue
        if want and matches or not want and not item:
            continue
        if item and not matches:
            print(f"    ! codex/{name} has a command this script does not own; left unchanged")
            continue
        command = ["codex", "mcp", "add", name, "--", "uv", "run", "--quiet", str(root / relative)] if want else ["codex", "mcp", "remove", name]
        if dry:
            print(f"    - would {'register' if want else 'remove'} codex/{name}")
            continue
        try:
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print(f"    ✓ codex/{name} {'registered' if want else 'removed'}")
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
        if action == "status":
            print(f"    {'✓' if matches else '-'} cursor/{name} — {'registered' if matches else 'not registered'}")
            continue
        if want and matches or not want and current is None:
            continue
        if current is not None and not matches:
            print(f"    ! cursor/{name} has a command this script does not own; left unchanged")
            continue
        if dry:
            print(f"    - would {'register' if want else 'remove'} cursor/{name}")
            continue
        if want:
            servers[name] = desired
        else:
            servers.pop(name, None)
        changed = True
        print(f"    ✓ cursor/{name} {'registered' if want else 'removed'}")
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
