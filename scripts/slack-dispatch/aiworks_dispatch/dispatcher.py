"""Dispatch abstraction + the local-Superset implementation.

The `Dispatcher` interface isolates HOW a worktree+agent is created so the engine
can be swapped without touching Slack/correlation/prompt code. Today's engine is
the local `superset` CLI (the host service already runs on this machine); a future
`SupersetSdkDispatcher` (the @superset_sh/sdk relay) or a bare `claude -p` fallback
can drop in behind the same interface.

The local flow is deliberately two steps with known-per-command JSON shapes:
  1. `superset workspaces create` — make the worktree (runs the project setup.sh).
  2. write .aiworks/slack-context.json into the returned worktreePath (host FS).
  3. `superset agents create` — launch the Claude agent with the built prompt.
Step 2 sits between so the context file is present before the agent can post back.
"""

from __future__ import annotations

import json
import logging
import subprocess
from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path

from .config import Config
from .correlation import CorrelationContext, git_safe_slug
from .prompt import build_prompt

log = logging.getLogger("aiworks_dispatch.dispatcher")


@dataclass
class DispatchResult:
    ok: bool
    workspace_id: str | None = None
    session_id: str | None = None
    worktree_path: str | None = None
    branch: str | None = None
    reused: bool = False
    error: str | None = None

    def to_dict(self) -> dict:
        return {
            "ok": self.ok,
            "workspace_id": self.workspace_id,
            "session_id": self.session_id,
            "worktree_path": self.worktree_path,
            "branch": self.branch,
            "reused": self.reused,
            "error": self.error,
        }


class Dispatcher(ABC):
    @abstractmethod
    def dispatch(self, ctx: CorrelationContext, reuse: dict | None = None) -> DispatchResult:  # pragma: no cover
        ...

    @abstractmethod
    def workspace_alive(self, workspace_id: str) -> bool:  # pragma: no cover
        ...


def _first(d: dict, *keys: str) -> str | None:
    """First present, truthy value among nested/aliased keys (defensive JSON read)."""
    for key in keys:
        cur: object = d
        for part in key.split("."):
            if isinstance(cur, dict) and part in cur:
                cur = cur[part]
            else:
                cur = None
                break
        if isinstance(cur, str) and cur:
            return cur
    return None


class SupersetLocalDispatcher(Dispatcher):
    def __init__(self, cfg: Config):
        self.cfg = cfg

    # -- CLI plumbing -------------------------------------------------------

    def _target_flags(self) -> list[str]:
        return ["--host", self.cfg.superset_host_id] if self.cfg.superset_host_id else ["--local"]

    def _run(self, args: list[str], timeout: int) -> dict:
        cmd = ["superset", *args, "--json"]
        log.debug("exec: %s", " ".join(cmd[:6]) + " …")
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            # env inherits SUPERSET_API_KEY (the CLI reads it) when OAuth isn't used.
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"superset {args[0]} {args[1] if len(args) > 1 else ''} failed "
                f"(exit {proc.returncode}): {proc.stderr.strip() or proc.stdout.strip()}"
            )
        try:
            return json.loads(proc.stdout or "{}")
        except json.JSONDecodeError as e:
            raise RuntimeError(f"superset returned non-JSON output: {e}: {proc.stdout[:400]!r}")

    # -- steps --------------------------------------------------------------

    def _create_workspace(self, name: str, branch: str) -> tuple[str, str]:
        data = self._run(
            [
                "workspaces", "create",
                *self._target_flags(),
                "--project", self.cfg.superset_project_id,
                "--name", name,
                "--branch", branch,
                "--base-branch", self.cfg.superset_base_branch,
            ],
            timeout=self.cfg.dispatch_timeout_sec,
        )
        ws_id = _first(data, "id", "workspace.id", "workspaceId")
        worktree = _first(data, "worktreePath", "workspace.worktreePath", "path")
        if not ws_id:
            raise RuntimeError(f"workspace create returned no id: {json.dumps(data)[:400]}")
        return ws_id, (worktree or "")

    def _write_context_file(self, worktree_path: str, ctx: CorrelationContext) -> None:
        if not worktree_path:
            log.warning("no worktreePath returned — skipping context file (Stop-hook backstop disabled for %s)", ctx.correlation_id)
            return
        aiworks_dir = Path(worktree_path) / ".aiworks"
        aiworks_dir.mkdir(parents=True, exist_ok=True)
        thread_key = f"thread:{ctx.slack_channel}:{ctx.slack_thread_ts}"
        payload = {
            **ctx.to_dict(),
            "workspace_root": self.cfg.workspace_root,
            # For the Stop-hook: clear the thread busy flag once the session ends.
            "redis_url": self.cfg.redis_url,
            "thread_key": thread_key,
        }
        # A fresh dispatch replaces any stale marker so the Stop-hook fires for THIS turn.
        (aiworks_dir / "slack-context.json").write_text(json.dumps(payload, indent=2))
        (aiworks_dir / "slack-posted").unlink(missing_ok=True)

    def workspace_alive(self, workspace_id: str) -> bool:
        """True if the workspace still exists with a present worktree (reuse is safe)."""
        try:
            data = self._run(["workspaces", "get", workspace_id], timeout=30)
        except Exception as e:  # noqa: BLE001
            log.info("workspace %s not reusable: %s", workspace_id, e)
            return False
        return bool(data.get("worktreeExists")) and bool(_first(data, "id", "workspace.id"))

    def _create_agent(self, workspace_id: str, prompt: str) -> str | None:
        data = self._run(
            [
                "agents", "create",
                "--workspace", workspace_id,
                "--agent", self.cfg.superset_agent_preset,
                "--prompt", prompt,
            ],
            timeout=120,
        )
        return _first(data, "id", "sessionId", "session.id", "agentSessionId")

    # -- interface ----------------------------------------------------------

    def dispatch(self, ctx: CorrelationContext, reuse: dict | None = None) -> DispatchResult:
        """Fresh worktree (reuse is None) or reuse an existing one for a thread follow-up.

        Reuse skips `workspaces create` entirely — no re-clone, no setup.sh — and just
        launches a new agent session in the thread's existing worktree/branch. Context
        carries via .aiworks/thread-log.md (the CLI cannot resume the prior session).
        """
        if reuse:
            branch = reuse.get("branch")
            try:
                worktree = reuse.get("worktree_path") or ""
                self._write_context_file(worktree, ctx)
                prompt = build_prompt(ctx, self.cfg.workspace_root, is_followup=True)
                session_id = self._create_agent(reuse["workspace_id"], prompt)
                return DispatchResult(
                    ok=True, workspace_id=reuse["workspace_id"], session_id=session_id,
                    worktree_path=worktree or None, branch=branch, reused=True,
                )
            except Exception as e:  # noqa: BLE001
                log.exception("reuse dispatch failed for %s", ctx.correlation_id)
                return DispatchResult(ok=False, branch=branch, reused=True, error=str(e))

        slug = git_safe_slug(ctx.correlation_id)
        name = branch = f"slack/{slug}"
        try:
            ws_id, worktree = self._create_workspace(name, branch)
            self._write_context_file(worktree, ctx)
            prompt = build_prompt(ctx, self.cfg.workspace_root, is_followup=False)
            session_id = self._create_agent(ws_id, prompt)
            return DispatchResult(
                ok=True,
                workspace_id=ws_id,
                session_id=session_id,
                worktree_path=worktree or None,
                branch=branch,
            )
        except subprocess.TimeoutExpired:
            return DispatchResult(ok=False, branch=branch, error="superset timed out (worktree setup took too long)")
        except Exception as e:  # surfaced to the Slack thread, never swallowed
            log.exception("dispatch failed for %s", ctx.correlation_id)
            return DispatchResult(ok=False, branch=branch, error=str(e))
