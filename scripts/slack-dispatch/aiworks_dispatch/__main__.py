"""Entrypoint — wire config -> store -> dispatcher -> Slack app, start Socket Mode.

    python -m aiworks_dispatch
"""

from __future__ import annotations

import logging
import signal
import sys

from slack_bolt.adapter.socket_mode import SocketModeHandler

from .config import Config, ConfigError
from .dispatcher import SupersetLocalDispatcher
from .logging_setup import setup_logging
from .slack_app import build_app
from .store import RedisStore

log = logging.getLogger("aiworks_dispatch")


def main() -> int:
    try:
        cfg = Config.from_env()
    except ConfigError as e:
        # Logging may not be configured yet — print plainly and fail fast.
        print(f"config error: {e}", file=sys.stderr)
        return 2

    setup_logging(cfg.log_level, cfg.log_format, cfg.log_name_width, cfg.log_tz)
    log.info("aiworks-dispatch starting (project=%s base=%s agent=%s)",
             cfg.superset_project_id, cfg.superset_base_branch, cfg.superset_agent_preset)

    try:
        store = RedisStore(
            cfg.redis_url,
            dedup_ttl_sec=cfg.dedup_ttl_sec,
            context_ttl_sec=cfg.context_ttl_sec,
        )
    except Exception as e:
        log.error("cannot reach Redis at %s: %s — start it with docker compose up -d", cfg.redis_url, e)
        return 3

    dispatcher = SupersetLocalDispatcher(cfg)
    app = build_app(cfg, store, dispatcher)
    handler = SocketModeHandler(app, cfg.slack_app_token)

    def _shutdown(signum, _frame):  # noqa: ANN001
        log.info("received signal %s — shutting down", signum)
        try:
            handler.close()
        finally:
            sys.exit(0)

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    log.info("connecting to Slack (Socket Mode)…")
    handler.start()  # blocks
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
