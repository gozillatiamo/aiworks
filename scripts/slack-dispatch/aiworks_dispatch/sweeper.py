"""Background worktree GC — the cleanup half of the dispatch lifecycle.

Every mention that opens a thread creates a Superset worktree, and nothing removed them:
the service had no cleanup path at all, only a manual one-liner in its RUNBOOK. They
accumulated until a human noticed the disk.

This runs `aiworks gc --dispatch` on an interval. All of the judgement lives in that
script, deliberately — the sweeper decides only WHEN, never WHAT, so a human running the
command by hand and the daemon running it unattended cannot diverge in behaviour.

Two properties matter and both come from the GC, not from here:

  * It never touches a worktree that is in use. A running agent, a held cargo lock, or any
    process cwd'd inside vetoes removal, so the sweeper cannot disturb work in flight or
    serialize a concurrent build.
  * It reads the live workspace list from the `superset` CLI and aborts if that list comes
    back empty, rather than concluding everything is garbage.

The age threshold defaults to `thread_ttl_sec` (see Config.gc_ttl_days): a worktree that a
live Slack thread could still be routed back to is out of reach by construction, so the
sweeper can never delete the worktree a follow-up mention is about to reuse.
"""

from __future__ import annotations

import logging
import math
import subprocess
import threading
from pathlib import Path

from .config import Config

log = logging.getLogger("aiworks_dispatch.sweeper")


def _ttl_days(cfg: Config) -> int:
    if cfg.gc_ttl_days > 0:
        return cfg.gc_ttl_days
    # Round UP: equal-to-TTL must still be reusable, so never reap at the boundary.
    return max(1, math.ceil(cfg.thread_ttl_sec / 86400))


def _run_once(cfg: Config, ttl_days: int) -> None:
    gc = Path(cfg.workspace_root) / "scripts" / "aiworks-gc.sh"
    if not gc.is_file():
        log.warning("worktree GC skipped — %s not found", gc)
        return
    cmd = [str(gc), "--dispatch", "--ttl-days", str(ttl_days)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        log.warning("worktree GC timed out after 900s")
        return
    except Exception as e:  # never let the sweeper take the service down
        log.warning("worktree GC failed to start: %s", e)
        return
    if proc.returncode != 0:
        log.warning("worktree GC exited %s: %s", proc.returncode,
                    (proc.stderr or proc.stdout or "").strip()[:400])
        return
    removed = [ln.strip() for ln in (proc.stdout or "").splitlines() if "removed" in ln]
    if removed:
        log.info("worktree GC reclaimed %d worktree(s) older than %dd", len(removed), ttl_days)
    else:
        log.debug("worktree GC: nothing past %dd", ttl_days)


def start(cfg: Config) -> threading.Thread | None:
    """Start the sweeper as a daemon thread. Returns None when disabled."""
    if not cfg.gc_enabled:
        log.info("worktree GC disabled (GC_ENABLED=0)")
        return None

    ttl_days = _ttl_days(cfg)
    stop = threading.Event()

    def loop() -> None:
        # Sweep once at boot: the service is usually restarted after a stretch of idleness,
        # which is exactly when the most worktrees are past their TTL.
        while not stop.is_set():
            _run_once(cfg, ttl_days)
            stop.wait(cfg.gc_interval_sec)

    t = threading.Thread(target=loop, name="worktree-gc", daemon=True)
    t.start()
    log.info("worktree GC every %ds, reaping dispatch worktrees older than %dd",
             cfg.gc_interval_sec, ttl_days)
    return t
