#!/usr/bin/env python3
"""Reconcile triage MCP registrations for Codex and Cursor.

Claude keeps its own machine-local scope (`~/.claude.json`, handled entirely in bash by
`triage-mcp.sh`). Cursor and Codex are PROJECT scope instead: this root's own git-ignored
`.cursor/mcp.json` and `.codex/config.toml`. Both do still have a machine-global surface
(`~/.cursor/mcp.json`, `${CODEX_HOME:-~/.codex}/config.toml`) that predates project scope, so
this module also migrates this root's own leftovers out of it — never a live sibling checkout's
registration (docs/adr/0038).
"""

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


def owned_shape(command: str, args: list[str], relative: str) -> bool:
    """True when (command, args) is exactly the shape this script has ever produced for
    `relative`: `uv run --quiet <path ending in .../relative>`, no extra flags.

    Shape alone does NOT mean the registration is safe to remove: a sibling workspace checkout
    on the same machine registers the identical shape globally and its server is perfectly
    live. Whether an owned-shape entry is dead or a live sibling is decided separately, by
    whether the recorded path still exists on disk — see `classify_global_entry`.
    """
    return command == "uv" and args[:2] == ["run", "--quiet"] and len(args) == 3 \
        and args[2].endswith(f"/{relative}")


def classify_global_entry(root: Path, relative: str, current: dict | None) -> str | None:
    """Classify one name's entry in a machine-GLOBAL registration file.

    Returns `None` (absent), `"own"` (byte-identical to this root's expected entry — a
    leftover from before project scope, or a duplicate registration), `"dead"` (this script's
    shape, but the recorded script no longer exists — a moved/deleted checkout), `"sibling"`
    (this script's shape, and the recorded script DOES exist — another workspace checkout on
    this machine, never touched), or `"foreign"` (anything else — somebody's own setup).
    """
    if current is None:
        return None
    if not isinstance(current, dict):
        return "foreign"
    command = str(current.get("command") or "")
    args = [str(value) for value in current.get("args") or []]
    if current == expected(root, relative):
        return "own"
    if not owned_shape(command, args, relative):
        return "foreign"
    return "sibling" if Path(args[2]).exists() else "dead"


def is_git_worktree(root: Path) -> bool:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--is-inside-work-tree"],
            capture_output=True, text=True,
        )
    except OSError:
        return False
    return result.returncode == 0 and result.stdout.strip() == "true"


def holds_triage_safely(root: Path, rel_path: str) -> str | None:
    """Refuse to write triage into a file that is not a private, git-ignored surface.

    Returns a reason to refuse, or `None` to proceed. A root that is not a git work tree at
    all (a bare checkout, a tarball) has no tracked-vs-ignored distinction to make, so it is
    always allowed.
    """
    if not is_git_worktree(root):
        return None
    tracked = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--error-unmatch", rel_path],
        capture_output=True, text=True,
    )
    if tracked.returncode == 0:
        return f"{rel_path} is tracked by git — git rm --cached {rel_path} first"
    ignored = subprocess.run(
        ["git", "-C", str(root), "check-ignore", "-q", rel_path],
        capture_output=True, text=True,
    )
    if ignored.returncode != 0:
        return f"{rel_path} is not git-ignored — add /{rel_path} to .gitignore first"
    return None


# ── Cursor: project .cursor/mcp.json = .mcp.json ∪ triage entries ───────────────────────────

def shared_servers(root: Path) -> dict:
    path = root / ".mcp.json"
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        print(f"    ! .mcp.json is not valid JSON: {path}")
        raise SystemExit(1)
    return dict(data.get("mcpServers") or {})


def triage_entries(root: Path, mode: str, existing: dict) -> dict:
    if mode == "off":
        return {}
    result: dict[str, dict] = {}
    for name, relative in SERVERS.items():
        if mode == "on":
            if (root / relative).is_file():
                result[name] = expected(root, relative)
        elif mode == "preserve":
            current = existing.get(name)
            if isinstance(current, dict) and current == expected(root, relative):
                result[name] = current
        else:
            raise ValueError(f"unknown mode: {mode}")
    return result


def render_cursor(root: Path, mode: str) -> str:
    path = root / ".cursor" / "mcp.json"
    existing: dict = {}
    if path.is_file() and not path.is_symlink():
        try:
            existing = json.loads(path.read_text(encoding="utf-8")).get("mcpServers") or {}
        except json.JSONDecodeError:
            existing = {}
    servers = dict(shared_servers(root))
    servers.update(triage_entries(root, mode, existing))
    return json.dumps({"mcpServers": servers}, indent=2, sort_keys=True) + "\n"


def cursor_config() -> Path:
    override = os.environ.get("AIWORKS_CURSOR_MCP_CONFIG")
    return Path(override) if override else Path.home() / ".cursor" / "mcp.json"


def migrate_global_cursor(root: Path, want: bool, dry: bool, write: bool) -> int:
    """Report (and, when `write`, remove) this root's own leftovers from the machine-global
    Cursor config. `write=False` is the read-only `status` view; a live sibling is never
    touched either way."""
    path = cursor_config()
    try:
        data = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
    except json.JSONDecodeError:
        print(f"    ! cursor global MCP config is not valid JSON: {path}")
        return 1
    servers = data.get("mcpServers") or {}
    changed = False
    for name, relative in SERVERS.items():
        cls = classify_global_entry(root, relative, servers.get(name))
        if cls in ("own", "dead"):
            if not write:
                reason = "from this workspace" if cls == "own" else "(path gone)"
                print(f"    ! cursor/{name} — GLOBAL leftover {reason}; sync removes it")
            elif dry:
                print(f"    - would remove global cursor/{name}")
            else:
                servers.pop(name, None)
                changed = True
                print(f"    ✓ cursor/{name} — GLOBAL leftover removed")
        elif cls == "sibling":
            if want:
                print(f"    - cursor/{name} — GLOBAL entry owned elsewhere; shadowed here by project scope")
            else:
                print(f"    ! cursor/{name} — GLOBAL entry owned elsewhere is ACTIVE here while triage "
                      "is off; remove it from ~/.cursor/mcp.json or upgrade that workspace")
        elif cls == "foreign":
            print(f"    - cursor/{name} — GLOBAL entry with a hand-made command; "
                  "left alone (project scope overrides it when registered)")
    if changed:
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(path.suffix + ".tmp")
        temp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temp.replace(path)
    return 0


def write_cursor_project(path: Path, content: str, dry: bool) -> None:
    was_symlink = path.is_symlink()
    current = path.read_text(encoding="utf-8") if path.is_file() and not was_symlink else None
    if current == content and not was_symlink:
        print("    ✓ cursor project scope up to date")
        return
    if dry:
        print("    - would write cursor project .cursor/mcp.json")
        return
    if was_symlink:
        path.unlink()
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(content, encoding="utf-8")
    temp.replace(path)
    print("    ✓ cursor project scope written")


def status_cursor(root: Path) -> None:
    shared = shared_servers(root)
    for name in SERVERS:
        if name in shared:
            print(f"    ! .mcp.json defines {name} — triage servers must never be in "
                  "the shared file (docs/adr/0005)")
    path = root / ".cursor" / "mcp.json"
    existing: dict = {}
    if path.is_file() and not path.is_symlink():
        try:
            existing = json.loads(path.read_text(encoding="utf-8")).get("mcpServers") or {}
        except json.JSONDecodeError:
            existing = {}
    for name, relative in SERVERS.items():
        registered = existing.get(name) == expected(root, relative)
        state = "registered (project scope)" if registered else "not registered"
        print(f"    {'✓' if registered else '-'} cursor/{name} — {state}")


def reconcile_cursor(root: Path, action: str, want: bool, dry: bool) -> int:
    if action == "status":
        status_cursor(root)
        return migrate_global_cursor(root, want, dry=True, write=False)
    mode = "on" if want else "off"
    failed = 0
    if want:
        reason = holds_triage_safely(root, ".cursor/mcp.json")
        if reason:
            print(f"    ! cursor triage not written: {reason}")
            failed = 1
        else:
            write_cursor_project(root / ".cursor" / "mcp.json", render_cursor(root, mode), dry)
    else:
        write_cursor_project(root / ".cursor" / "mcp.json", render_cursor(root, mode), dry)
    failed |= migrate_global_cursor(root, want, dry, write=True)
    return failed


# ── Codex: project .codex/config.toml, generated by scripts/codex/generate.py ───────────────

def read_toml_servers(path: Path) -> dict | None:
    """Returns `{}` for an absent file, `None` when the file cannot be read (no `tomllib`, or
    it does not parse) so callers can tell "nothing there" from "cannot tell"."""
    if not path.is_file():
        return {}
    try:
        import tomllib
    except ImportError:
        return None
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    return dict(data.get("mcp_servers") or {})


def codex_triage(root: Path, mode: str, existing_path: Path) -> tuple[dict, str]:
    """The triage servers `generate.py` merges into a ROOT-only `.codex/config.toml`."""
    if mode == "off":
        result = {}
        for name, relative in SERVERS.items():
            if (root / relative).is_file():
                entry = dict(expected(root, relative))
                entry["enabled"] = False
                result[name] = entry
        return result, ""
    if mode == "on":
        return (
            {name: expected(root, relative) for name, relative in SERVERS.items()
             if (root / relative).is_file()},
            "",
        )
    if mode != "preserve":
        raise ValueError(f"unknown mode: {mode}")
    existing = read_toml_servers(existing_path)
    if existing is None:
        return {}, ("codex triage preserve skipped: tomllib unavailable or "
                     f"{existing_path} does not parse")
    result = {}
    for name, relative in SERVERS.items():
        entry = existing.get(name)
        if not isinstance(entry, dict):
            continue
        exp = expected(root, relative)
        if entry.get("command") == exp["command"] and list(entry.get("args") or []) == exp["args"]:
            kept = dict(exp)
            if entry.get("enabled") is False:
                kept["enabled"] = False
            result[name] = kept
    return result, ""


def codex_home() -> Path:
    override = os.environ.get("CODEX_HOME")
    return Path(override) if override else Path.home() / ".codex"


def codex_project_registered(root: Path, name: str, relative: str) -> bool:
    servers = read_toml_servers(root / ".codex" / "config.toml")
    entry = (servers or {}).get(name)
    if not isinstance(entry, dict):
        return False
    exp = expected(root, relative)
    return entry.get("command") == exp["command"] and list(entry.get("args") or []) == exp["args"] \
        and entry.get("enabled") is not False


def migrate_global_codex(root: Path, want: bool, dry: bool, write: bool) -> int:
    """Cursor's counterpart, over `${CODEX_HOME:-~/.codex}/config.toml`. Read with `tomllib`
    (never `codex mcp list`, which merges in the project layer from cwd and so cannot tell
    user scope from project scope); removal goes through `codex mcp remove`, the only writer
    of the Codex user layer this script uses — there is no TOML writer in the standard
    library, so hand-editing this file is not an option the way it is for Cursor's JSON."""
    if not write:
        servers = read_toml_servers(codex_home() / "config.toml") or {}
        _report_global_codex(root, want, servers, dry=True, write=False)
        return 0
    if not shutil.which("codex"):
        print("    - codex global migration skipped (codex CLI not on PATH)")
        return 0
    servers = read_toml_servers(codex_home() / "config.toml")
    if servers is None:
        print("    - codex global migration skipped (tomllib unavailable, or "
              f"{codex_home() / 'config.toml'} does not parse)")
        return 0
    return _report_global_codex(root, want, servers, dry, write=True)


def _report_global_codex(root: Path, want: bool, servers: dict, dry: bool, write: bool) -> int:
    for name, relative in SERVERS.items():
        cls = classify_global_entry(root, relative, servers.get(name))
        if cls in ("own", "dead"):
            if not write:
                reason = "from this workspace" if cls == "own" else "(path gone)"
                print(f"    ! codex/{name} — GLOBAL leftover {reason}; sync removes it")
            elif dry:
                print(f"    - would remove global codex/{name}")
            else:
                subprocess.run(["codex", "mcp", "remove", name], check=False,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                print(f"    ✓ codex/{name} — GLOBAL leftover removed")
        elif cls == "sibling":
            if want:
                print(f"    - codex/{name} — GLOBAL entry owned elsewhere; shadowed here by project scope")
            else:
                print(f"    - codex/{name} — GLOBAL entry owned elsewhere; shadowed (masked by enabled=false)")
        elif cls == "foreign":
            print(f"    - codex/{name} — GLOBAL entry with a hand-made command; "
                  "left alone (project scope overrides it when registered)")
    return 0


def status_codex(root: Path) -> None:
    for name, relative in SERVERS.items():
        registered = codex_project_registered(root, name, relative)
        state = "registered (project scope)" if registered else "not registered"
        print(f"    {'✓' if registered else '-'} codex/{name} — {state}")


def reconcile_codex(root: Path, action: str, want: bool, dry: bool) -> int:
    if action == "status":
        status_codex(root)
        return migrate_global_codex(root, want, dry=True, write=False)
    mode = "on" if want else "off"
    failed = 0
    skip_write = False
    if want:
        reason = holds_triage_safely(root, ".codex/config.toml")
        if reason:
            print(f"    ! codex triage not written: {reason}")
            failed = 1
            skip_write = True
    if not skip_write:
        generate_py = root / "scripts" / "codex" / "generate.py"
        command = ["python3", str(generate_py), "--root", str(root), "--triage", mode]
        if dry:
            command.append("--dry-run")
        command.append(".")
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            print("    ! codex project reconciliation failed")
            failed = 1
    failed |= migrate_global_codex(root, want, dry, write=True)
    return failed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--render", choices=("cursor",))
    parser.add_argument("--action", choices=("sync", "on", "off", "status"))
    parser.add_argument("--want", choices=("0", "1"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()

    if args.render:
        if args.action or args.want is not None:
            parser.error("--render is mutually exclusive with --action/--want")
        print(render_cursor(root, "preserve"), end="")
        return 0
    if not args.action or args.want is None:
        parser.error("--action and --want are required unless --render is given")

    harnesses = selected(root)
    want = args.want == "1"
    failed = 0
    if "codex" in harnesses:
        failed |= reconcile_codex(root, args.action, want, args.dry_run)
    if "cursor" in harnesses:
        failed |= reconcile_cursor(root, args.action, want, args.dry_run)
    return failed


if __name__ == "__main__":
    raise SystemExit(main())
