"""Pre-flight sanity check — run before first start, or when a dispatch fails.

    python -m aiworks_dispatch.check

Prints the local Superset host status, the configured project, the installed agent
presets, and whether Redis + the notify adapter are reachable, so an operator can
fill in the env vars and confirm the prerequisites without guessing.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


def _superset(args: list[str]) -> tuple[bool, object]:
    try:
        proc = subprocess.run(["superset", *args, "--json"], capture_output=True, text=True, timeout=30)
    except FileNotFoundError:
        return False, "superset CLI not found on PATH"
    except subprocess.TimeoutExpired:
        return False, "superset timed out"
    if proc.returncode != 0:
        return False, (proc.stderr.strip() or proc.stdout.strip())
    try:
        return True, json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        return True, proc.stdout.strip()


def _ok(label: str, detail: str = "") -> None:
    print(f"  \033[32m✓\033[0m {label}{(' — ' + detail) if detail else ''}")


def _bad(label: str, detail: str = "") -> None:
    print(f"  \033[31m✗\033[0m {label}{(' — ' + detail) if detail else ''}")


def main() -> int:
    problems = 0
    project_id = os.environ.get("SUPERSET_PROJECT_ID", "").strip()
    agent_preset = os.environ.get("SUPERSET_AGENT_PRESET", "claude").strip() or "claude"

    print("Superset host:")
    ok, status = _superset(["status"])
    if ok and isinstance(status, dict) and status.get("running") and status.get("healthy"):
        _ok("host running + healthy", f"{status.get('hostName')} ({status.get('hostId', '')[:12]}…)")
    else:
        _bad("host not healthy", json.dumps(status) if isinstance(status, dict) else str(status))
        _bad("hint", "start it with:  superset start")
        problems += 1

    print("Project:")
    ok, projects = _superset(["projects", "list"])
    if ok and isinstance(projects, list):
        match = next((p for p in projects if p.get("id") == project_id), None)
        if match:
            _ok(f"SUPERSET_PROJECT_ID resolves", f"{match.get('name')} -> {match.get('path')}")
        elif project_id:
            _bad("SUPERSET_PROJECT_ID not found in projects list", project_id)
            problems += 1
        else:
            print("  (SUPERSET_PROJECT_ID unset) available projects:")
            for p in projects:
                print(f"      {p.get('id')}  {p.get('name')}  {p.get('path')}")
            problems += 1
    else:
        _bad("could not list projects", str(projects))
        problems += 1

    print("Agent preset:")
    ok, agents = _superset(["agents", "list", "--local"])
    if ok and isinstance(agents, list):
        ids = {a.get("presetId") for a in agents}
        if agent_preset in ids:
            _ok(f"preset '{agent_preset}' installed on host")
        else:
            _bad(f"preset '{agent_preset}' NOT installed", f"available: {sorted(i for i in ids if i)}")
            problems += 1
    else:
        _bad("could not list agents", str(agents))
        problems += 1

    print("Redis:")
    redis_url = os.environ.get("REDIS_URL", "redis://localhost:6370/0")
    try:
        import redis  # noqa: PLC0415

        redis.Redis.from_url(redis_url, decode_responses=True).ping()
        _ok("reachable", redis_url)
    except Exception as e:  # noqa: BLE001
        _bad("unreachable", f"{redis_url}: {e}")
        _bad("hint", "cd scripts/slack-dispatch && docker compose up -d")
        problems += 1

    print("Notify adapter (post-back path):")
    workspace_root = os.environ.get("WORKSPACE_ROOT", "").strip() or str(Path(__file__).resolve().parents[3])
    send = Path(workspace_root) / "scripts" / "notify" / "send.sh"
    if send.is_file():
        _ok("send.sh present", str(send))
    else:
        _bad("send.sh missing", str(send))
        problems += 1

    print()
    if problems:
        print(f"\033[31m{problems} problem(s) found — fix the above before starting.\033[0m")
        return 1
    print("\033[32mAll prerequisites look good. Start with: ./run.sh\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
