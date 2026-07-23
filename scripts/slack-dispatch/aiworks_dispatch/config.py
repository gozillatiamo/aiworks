"""Configuration — parse + validate environment into a typed Config, fail fast.

Required vars raise at boot so a misconfigured service never starts half-alive.
The allowlists parse into sets; an empty allowlist means DENY ALL (a loud warning
is logged at boot) — the mention text becomes an agent prompt with repo write
access, so open-by-default is never the fallback.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger("aiworks_dispatch.config")


class ConfigError(RuntimeError):
    """Raised when a required env var is missing or invalid."""


def _require(name: str) -> str:
    val = os.environ.get(name, "").strip()
    if not val:
        raise ConfigError(f"missing required env var: {name}")
    return val


def _optional(name: str, default: str) -> str:
    val = os.environ.get(name, "").strip()
    return val or default


def _csv_set(name: str) -> set[str]:
    raw = os.environ.get(name, "")
    return {tok.strip() for tok in raw.split(",") if tok.strip()}


def _default_workspace_root() -> str:
    # scripts/slack-dispatch/aiworks_dispatch/config.py -> up 3 = the meta-repo root.
    return str(Path(__file__).resolve().parents[3])


@dataclass(frozen=True)
class Config:
    # Slack (Socket Mode)
    slack_bot_token: str          # xoxb-… — chat.postMessage for acks
    slack_app_token: str          # xapp-… — Socket Mode connection

    # Trigger allowlist (default deny)
    allowed_channel_ids: set[str] = field(default_factory=set)
    allowed_user_ids: set[str] = field(default_factory=set)

    # Superset (local host CLI)
    superset_project_id: str = ""     # required — the OFB meta-repo project
    superset_host_id: str = ""        # optional — empty => --local (this machine)
    superset_agent_preset: str = "claude"
    superset_base_branch: str = "develop"
    dispatch_timeout_sec: int = 1800  # ws create runs the project's setup.sh (heavy)

    # The main clone whose scripts/notify/.env holds the Slack bot token. The
    # dispatched agent posts back through THIS path (an absolute path that
    # resolves from inside any worktree on the same machine).
    workspace_root: str = field(default_factory=_default_workspace_root)

    # Dedup / correlation store (Redis — see docker-compose.yml)
    redis_url: str = "redis://localhost:6370/0"
    dedup_ttl_sec: int = 86400        # 1d — window Slack may redeliver within
    context_ttl_sec: int = 604800     # 7d — keep correlation context for tracing

    # Thread continuity: a Slack thread reuses ITS worktree so a follow-up mention
    # never re-spawns one. The mapping lives thread_ttl_sec from CREATION (fixed, not
    # sliding). While a thread's agent is running, a busy flag (busy_ttl_sec, a safety
    # cap — the Stop-hook clears it promptly) rejects concurrent mentions.
    thread_ttl_sec: int = 604800      # 7d fixed from thread creation
    busy_ttl_sec: int = 1800          # cap; defaults to dispatch_timeout_sec

    # On the FIRST mention inside a pre-existing thread (whose root did not address the
    # bot), the whole thread up to the mention is pulled in as context. Cap the number
    # of messages fetched so a giant thread can't blow up the prompt.
    thread_context_max_msgs: int = 200

    log_level: str = "info"

    @staticmethod
    def from_env() -> "Config":
        dispatch_timeout = int(_optional("DISPATCH_TIMEOUT_SEC", "1800"))
        cfg = Config(
            slack_bot_token=_require("SLACK_BOT_TOKEN"),
            slack_app_token=_require("SLACK_APP_TOKEN"),
            allowed_channel_ids=_csv_set("ALLOWED_CHANNEL_IDS"),
            allowed_user_ids=_csv_set("ALLOWED_USER_IDS"),
            superset_project_id=_require("SUPERSET_PROJECT_ID"),
            superset_host_id=_optional("SUPERSET_HOST_ID", ""),
            superset_agent_preset=_optional("SUPERSET_AGENT_PRESET", "claude"),
            superset_base_branch=_optional("SUPERSET_BASE_BRANCH", "develop"),
            dispatch_timeout_sec=dispatch_timeout,
            workspace_root=_optional("WORKSPACE_ROOT", _default_workspace_root()),
            redis_url=_optional("REDIS_URL", "redis://localhost:6370/0"),
            dedup_ttl_sec=int(_optional("DEDUP_TTL_SEC", "86400")),
            context_ttl_sec=int(_optional("CONTEXT_TTL_SEC", "604800")),
            thread_ttl_sec=int(_optional("THREAD_TTL_SEC", "604800")),
            busy_ttl_sec=int(_optional("BUSY_TTL_SEC", str(dispatch_timeout))),
            thread_context_max_msgs=int(_optional("THREAD_CONTEXT_MAX_MSGS", "200")),
            log_level=_optional("LOG_LEVEL", "info"),
        )
        cfg.validate()
        return cfg

    def validate(self) -> None:
        root = Path(self.workspace_root)
        send = root / "scripts" / "notify" / "send.sh"
        if not send.is_file():
            raise ConfigError(
                f"WORKSPACE_ROOT={self.workspace_root} has no scripts/notify/send.sh — "
                "post-back would fail. Point it at the OFB meta-repo main clone."
            )
        if not self.allowed_channel_ids and not self.allowed_user_ids:
            log.warning(
                "SECURITY: no ALLOWED_CHANNEL_IDS or ALLOWED_USER_IDS set — "
                "the bot will DENY every mention (default deny). Configure at least one."
            )
