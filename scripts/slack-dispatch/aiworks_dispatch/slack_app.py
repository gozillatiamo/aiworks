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


def _ts_before(a: str, b: str) -> bool:
    """True if Slack ts `a` is strictly earlier than `b` (numeric, not lexical)."""
    try:
        return float(a) < float(b)
    except (TypeError, ValueError):
        return False


def fetch_thread_context(client, channel: str, thread_ts: str, before_ts: str, max_msgs: int) -> str:
    """Whole thread up to (excluding) the mention, one line per message tagged with
    its Slack author id. Raises on API error so the caller can hard-fail."""
    resp = client.conversations_replies(channel=channel, ts=thread_ts, limit=max_msgs)
    lines: list[str] = []
    for m in resp.get("messages", []) or []:
        mts = m.get("ts", "")
        if before_ts and not _ts_before(mts, before_ts):
            continue  # skip the mention itself and anything after it
        text = (m.get("text") or "").strip()
        if not text:
            continue
        author = m.get("user") or (f"bot:{m.get('bot_id')}" if m.get("bot_id") else "unknown")
        lines.append(f"[{author}] {text}")
    return "\n".join(lines)


def build_app(cfg: Config, store: RedisStore, dispatcher: Dispatcher) -> App:
    app = App(token=cfg.slack_bot_token, logger=log)

    def _post(client, channel: str, thread_ts: str, text: str) -> None:
        try:
            client.chat_postMessage(channel=channel, thread_ts=thread_ts, text=text, unfurl_links=False)
        except Exception:
            log.exception("failed to post to %s/%s", channel, thread_ts)

    def _run_dispatch(ctx: CorrelationContext, thread_key: str, mapping: dict | None, thread_context: str, client) -> None:
        # Reuse the thread's worktree if it still exists; otherwise fall back to fresh.
        reuse = None
        if mapping and mapping.get("workspace_id") and dispatcher.workspace_alive(mapping["workspace_id"]):
            reuse = mapping
        elif mapping:
            log.info("thread %s mapping stale (worktree gone) — creating a fresh worktree", thread_key)

        result = dispatcher.dispatch(ctx, reuse=reuse, thread_context=thread_context)
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
                f":im_deadq: อยู่ไม่ไหว อยู่ไม่ไหว เฮ้ย อยู่ไม่ไหว อ้าว! (ref `{ctx.correlation_id}`)\n"
                f"บ้านนี้มันน่ากลัว กลัว ๆ ๆ อร๊าย! — กูไม่อยากอยู่ กูไม่อยากอยู่ กูไม่อยากอยู่ที่นี่.\n",
                f":red_circle: *{result.error}*"
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

        verb = "โยนเข้า" if result.reused else "เสก"
        log.info(
            "dispatched ok correlation=%s reused=%s workspace=%s session=%s",
            ctx.correlation_id, result.reused, result.workspace_id, result.session_id,
        )
        _post(
            client, ctx.slack_channel, ctx.slack_thread_ts,
            f":claude-code: {verb} worktree `{result.branch}` — น้อง Claude รายงานตัวฮ่ะ "
            f"(session `{result.session_id or 'n/a'}`). เสร็จแล้วเดี๋ยวมาบอกนะฮ่ะ. "
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
            _post(client, channel, thread_ts, ":pepe-tumtum: แก่... ไม่... มีสิทธิิ์!!!.")
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
                ":angry-monkey: ใจเย็นดิ๊!! รอก่อนได้ไหมล่ะ. "
                "ก็แดดมันร้อน คนไม่ใช่หุ่นยนต์ ที่จะทนตากแดดทั้งวัน — ค่อยถามใหม่นะจ๊ะ.",
            )
            return

        # Reuse this thread's existing worktree if we've seen the thread before
        # (validated in the background before dispatch). None => a fresh worktree.
        mapping = store.get_thread(thread_key)

        # First bot request INSIDE a pre-existing thread (its root did not @ the bot):
        # pull the conversation so far as context. Hard-fail (no dispatch) if unreadable.
        mention_ts = event.get("ts", "")
        thread_context = ""
        if mapping is None and thread_ts and thread_ts != mention_ts:
            try:
                thread_context = fetch_thread_context(
                    client, channel, thread_ts, mention_ts, cfg.thread_context_max_msgs
                )
                log.info("pulled thread context channel=%s thread=%s chars=%d", channel, thread_ts, len(thread_context))
            except Exception as e:  # noqa: BLE001
                log.warning("thread fetch failed channel=%s thread=%s: %s", channel, thread_ts, e)
                _post(
                    client, channel, thread_ts,
                    ":lock: I was mentioned inside a thread but can't read its history. Add the bot "
                    "scopes `channels:history` (and `groups:history` for private channels), reinstall "
                    "the app, then mention me again.",
                )
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

        # Claim the thread before acking so a near-simultaneous mention is rejected.
        store.set_busy(thread_key, ctx.correlation_id, cfg.busy_ttl_sec)

        continuing = mapping is not None
        log.info("accepted correlation=%s channel=%s user=%s continuing=%s", ctx.correlation_id, channel, user, continuing)
        _post(
            client, channel, thread_ts,
            f":typingcat: จัดไปไอหนู — {'พี่ไม่เหนื่อยอยู่แล้ว!!' if continuing else 'ใช้งานมาหนักๆ ไม่ต้องเกรงใจหรอก :glassespepeq:'} "
            f"ตื่นๆ มีเรื่องว่ะ :petclaude:. ใจร่มๆ พักชมสิ่งที่น่าสนใจสักครู่ :bananadance_duo:. (ref: `{ctx.correlation_id}`)",
        )
        # Heavy (fresh worktree setup can take minutes). Do it off the socket thread.
        threading.Thread(
            target=_run_dispatch, args=(ctx, thread_key, mapping, thread_context, client),
            name=f"dispatch-{ctx.correlation_id}", daemon=True,
        ).start()

    return app
