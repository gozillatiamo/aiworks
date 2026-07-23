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
from .correlation import CorrelationContext, new_correlation_id, now_iso
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

    def _run_dispatch(ctx: CorrelationContext, thread_key: str, mapping: dict | None, client) -> None:
        # Reuse the thread's worktree if it still exists; otherwise fall back to fresh.
        reuse = None
        if mapping and mapping.get("workspace_id") and dispatcher.workspace_alive(mapping["workspace_id"]):
            reuse = mapping
        elif mapping:
            log.info("thread %s mapping stale (worktree gone) — creating a fresh worktree", thread_key)

        result = dispatcher.dispatch(ctx, reuse=reuse)
        try:
            store.save_outcome(ctx.correlation_id, result.to_dict())
        except Exception:
            log.exception("failed to persist outcome for %s", ctx.correlation_id)

        if not result.ok:
            # No agent was launched — free the thread so a retry isn't blocked.
            store.clear_busy(thread_key)
            log.error("dispatch failed correlation=%s error=%s", ctx.correlation_id, result.error)
            _post(
                client, ctx.slack_channel, ctx.slack_thread_ts,
                f":x: Couldn't dispatch (ref `{ctx.correlation_id}`): {result.error}\n"
                f"The Superset host may be offline — try again once it's back.",
            )
            return

        # Persist the thread->worktree mapping. Fixed TTL from creation (never refreshed).
        try:
            if result.reused:
                store.touch_thread(thread_key, {
                    **(mapping or {}),
                    "last_correlation_id": ctx.correlation_id,
                    "last_activity": ctx.created_at,
                })
            else:
                store.create_thread(thread_key, {
                    "workspace_id": result.workspace_id,
                    "worktree_path": result.worktree_path,
                    "branch": result.branch,
                    "correlation_id": ctx.correlation_id,
                    "created_at": ctx.created_at,
                    "last_correlation_id": ctx.correlation_id,
                    "last_activity": ctx.created_at,
                }, cfg.thread_ttl_sec)
        except Exception:
            log.exception("failed to persist thread mapping for %s", thread_key)

        verb = "Reusing" if result.reused else "Created"
        log.info(
            "dispatched ok correlation=%s reused=%s workspace=%s session=%s",
            ctx.correlation_id, result.reused, result.workspace_id, result.session_id,
        )
        _post(
            client, ctx.slack_channel, ctx.slack_thread_ts,
            f":white_check_mark: {verb} worktree `{result.branch}` — Claude is on it now "
            f"(session `{result.session_id or 'n/a'}`). I'll reply here when it finishes. "
            f"(ref: `{ctx.correlation_id}`)",
        )
        # On success the busy flag stays set until the agent's session ends
        # (the Stop-hook clears it) — that's what rejects concurrent mentions.

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

        thread_key = store.thread_key(channel, thread_ts)

        # Concurrency: one agent per thread's worktree at a time. A mention that
        # arrives while the previous turn is still running is refused, not queued.
        if store.is_busy(thread_key):
            log.info("thread %s busy — rejecting concurrent mention", thread_key)
            _post(
                client, channel, thread_ts,
                ":hourglass: I'm still working on the previous request in this thread. "
                "I'll reply here when it's done — mention me again after that.",
            )
            return

        # Reuse this thread's existing worktree if we've seen the thread before
        # (validated in the background before dispatch). None => a fresh worktree.
        mapping = store.get_thread(thread_key)

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

        # Claim the thread before acking so a near-simultaneous mention is rejected.
        store.set_busy(thread_key, ctx.correlation_id, cfg.busy_ttl_sec)

        continuing = mapping is not None
        log.info("accepted correlation=%s channel=%s user=%s continuing=%s", ctx.correlation_id, channel, user, continuing)
        _post(
            client, channel, thread_ts,
            f":hourglass_flowing_sand: On it — {'continuing this thread' if continuing else 'creating a worktree'} "
            f"and dispatching Claude. I'll reply in this thread when it's done. (ref: `{ctx.correlation_id}`)",
        )
        # Heavy (fresh worktree setup can take minutes). Do it off the socket thread.
        threading.Thread(
            target=_run_dispatch, args=(ctx, thread_key, mapping, client),
            name=f"dispatch-{ctx.correlation_id}", daemon=True,
        ).start()

    return app
