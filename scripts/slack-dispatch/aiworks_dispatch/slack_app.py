"""Slack Socket Mode listener (slack_bolt).

Handles app_mention: dedup -> allowlist -> strip mention -> mint context ->
immediate ack -> dispatch the heavy worktree creation on a background thread so
the socket envelope is acked promptly (Slack redelivers otherwise; dedup in the
store is the backstop).
"""

from __future__ import annotations

import logging
import re
import threading

from slack_bolt import App

from .config import Config
from .correlation import CorrelationContext, git_safe_slug, new_correlation_id, now_iso
from .dispatcher import Dispatcher
from .store import RedisStore

log = logging.getLogger("aiworks_dispatch.slack")

_LEADING_MENTIONS = re.compile(r"^(?:\s*<@[^>]+>\s*)+")

_USAGE = (
    "Mention me with a request or a slash command, e.g.\n"
    "• `@aiworks /prd OFB-123`\n"
    "• `@aiworks /dev-cycle OFB-45`\n"
    "• `@aiworks investigate why payouts are slow in front-end`\n"
    "I'll spin up a worktree, run Claude on it, and reply in this thread when done."
)


def _strip_mentions(text: str) -> str:
    return _LEADING_MENTIONS.sub("", text or "").strip()


def _is_allowed(cfg: Config, channel: str, user: str) -> bool:
    # Default deny. Allowed when the channel OR the user is on a configured list.
    if cfg.allowed_channel_ids and channel in cfg.allowed_channel_ids:
        return True
    if cfg.allowed_user_ids and user in cfg.allowed_user_ids:
        return True
    return False


def build_app(cfg: Config, store: RedisStore, dispatcher: Dispatcher) -> App:
    app = App(token=cfg.slack_bot_token, logger=log)

    def _post(client, channel: str, thread_ts: str, text: str) -> None:
        try:
            client.chat_postMessage(channel=channel, thread_ts=thread_ts, text=text, unfurl_links=False)
        except Exception:
            log.exception("failed to post to %s/%s", channel, thread_ts)

    def _run_dispatch(ctx: CorrelationContext, client) -> None:
        slug = git_safe_slug(ctx.correlation_id)
        result = dispatcher.dispatch(ctx)
        try:
            store.save_outcome(ctx.correlation_id, result.to_dict())
        except Exception:
            log.exception("failed to persist outcome for %s", ctx.correlation_id)
        if result.ok:
            log.info(
                "dispatched ok correlation=%s workspace=%s session=%s",
                ctx.correlation_id, result.workspace_id, result.session_id,
            )
            _post(
                client, ctx.slack_channel, ctx.slack_thread_ts,
                f":white_check_mark: Worktree `slack/{slug}` created — Claude is on it now "
                f"(session `{result.session_id or 'n/a'}`). I'll reply here when it finishes. "
                f"(ref: `{ctx.correlation_id}`)",
            )
        else:
            log.error("dispatch failed correlation=%s error=%s", ctx.correlation_id, result.error)
            _post(
                client, ctx.slack_channel, ctx.slack_thread_ts,
                f":x: Couldn't dispatch (ref `{ctx.correlation_id}`): {result.error}\n"
                f"The Superset host may be offline — try again once it's back.",
            )

    @app.event("app_mention")
    def handle_app_mention(event, client, logger):  # noqa: ANN001
        event_key = event.get("client_msg_id") or event.get("ts", "")
        if not event_key:
            return
        # Idempotency: a redelivered event must not spawn a second worktree.
        if not store.mark_seen(event_key):
            log.info("duplicate event %s — skipping", event_key)
            return

        channel = event.get("channel", "")
        thread_ts = event.get("thread_ts") or event.get("ts", "")
        user = event.get("user", "")

        if not _is_allowed(cfg, channel, user):
            log.warning("denied mention channel=%s user=%s", channel, user)
            _post(client, channel, thread_ts, ":no_entry: I'm not enabled for this channel or user.")
            return

        request_text = _strip_mentions(event.get("text", ""))
        if not request_text:
            _post(client, channel, thread_ts, _USAGE)
            return

        ctx = CorrelationContext(
            correlation_id=new_correlation_id(),
            slack_channel=channel,
            slack_thread_ts=thread_ts,
            slack_user_id=user,
            request_text=request_text,
            created_at=now_iso(),
        )
        try:
            store.save_context(ctx)
        except Exception:
            log.exception("failed to persist context for %s", ctx.correlation_id)

        log.info("accepted correlation=%s channel=%s user=%s", ctx.correlation_id, channel, user)
        _post(
            client, channel, thread_ts,
            f":hourglass_flowing_sand: On it — creating a worktree and dispatching Claude. "
            f"I'll reply in this thread when it's done. (ref: `{ctx.correlation_id}`)",
        )
        # Heavy: worktree setup can take minutes. Do it off the socket thread.
        threading.Thread(
            target=_run_dispatch, args=(ctx, client), name=f"dispatch-{ctx.correlation_id}", daemon=True,
        ).start()

    return app
