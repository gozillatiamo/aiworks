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
from typing import Callable

from slack_bolt import App

from .attachments import (
    SlackFileRef,
    classify_skips_for_ack,
    dedup_refs,
    fmt_ts,
    refs_from_message,
)
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


def _make_name_resolver(client) -> Callable[[str], str]:  # noqa: ANN001
    """Resolve a Slack user id -> display name, cached for the lifetime of one event.

    Makes multi-user threads legible in the agent's context. Needs the users:read
    scope; on any failure it falls back to the raw id, so a missing scope degrades
    gracefully rather than blocking the turn."""
    cache: dict[str, str] = {}

    def resolve(user_id: str) -> str:
        if not user_id:
            return "unknown"
        if user_id in cache:
            return cache[user_id]
        name = user_id
        try:
            info = client.users_info(user=user_id)
            prof = (info.get("user") or {}).get("profile") or {}
            name = (
                prof.get("display_name")
                or prof.get("real_name")
                or (info.get("user") or {}).get("name")
                or user_id
            )
        except Exception as e:  # noqa: BLE001
            log.debug("users_info failed for %s: %s", user_id, e)
        cache[user_id] = name
        return name

    return resolve


def fetch_thread_context(
    client,  # noqa: ANN001
    channel: str,
    thread_ts: str,
    before_ts: str,
    max_msgs: int,
    *,
    oldest: str | None = None,
    resolve_name: Callable[[str], str] | None = None,
) -> tuple[str, list[SlackFileRef]]:
    """Thread messages up to (excluding) the mention: a text transcript (one line per
    message, tagged with its author + timestamp) plus the files attached along the way.

    `oldest` (a Slack ts) restricts the fetch to messages after a prior turn's
    high-water mark, so a follow-up re-scans only what is new. Messages with NO text
    but WITH files are kept (an image-only post must not vanish). Raises on API error
    so the caller can hard-fail (e.g. missing channels:history)."""
    kwargs: dict = {"channel": channel, "ts": thread_ts, "limit": max_msgs}
    if oldest:
        kwargs["oldest"] = oldest
    resp = client.conversations_replies(**kwargs)
    lines: list[str] = []
    files: list[SlackFileRef] = []
    for m in resp.get("messages", []) or []:
        mts = m.get("ts", "")
        if before_ts and not _ts_before(mts, before_ts):
            continue  # skip the mention itself and anything after it
        raw_author = m.get("user") or (f"bot:{m.get('bot_id')}" if m.get("bot_id") else "unknown")
        name = resolve_name(raw_author) if (resolve_name and not raw_author.startswith("bot:")) else raw_author
        text = (m.get("text") or "").strip()
        msg_files = refs_from_message(m, name)
        if not text and not msg_files:
            continue  # nothing usable (e.g. a join notice)
        if text:
            lines.append(f"[{name} @ {fmt_ts(mts)}] {text}")
        files.extend(msg_files)
    return "\n".join(lines), files


def build_app(cfg: Config, store: RedisStore, dispatcher: Dispatcher) -> App:
    app = App(token=cfg.slack_bot_token, logger=log)

    def _post(client, channel: str, thread_ts: str, text: str) -> None:
        try:
            client.chat_postMessage(channel=channel, thread_ts=thread_ts, text=text, unfurl_links=False)
        except Exception:
            log.exception("failed to post to %s/%s", channel, thread_ts)

    def _run_dispatch(
        ctx: CorrelationContext,
        thread_key: str,
        mapping: dict | None,
        thread_context: str,
        attachments: list[SlackFileRef],
        mention_ts: str,
        client,  # noqa: ANN001
    ) -> None:
        # Reuse the thread's worktree if it still exists; otherwise fall back to fresh.
        reuse = None
        if mapping and mapping.get("workspace_id") and dispatcher.workspace_alive(mapping["workspace_id"]):
            reuse = mapping
        elif mapping:
            log.info("thread %s mapping stale (worktree gone) — creating a fresh worktree", thread_key)
            # The prior worktree (its thread-log.md AND downloaded files) is gone, but the
            # pre-ack fetch only pulled messages since the last high-water mark. Rebuild the
            # FULL thread so the fresh agent starts with complete context. Best-effort — on
            # failure keep the incremental data already gathered.
            if ctx.slack_thread_ts and ctx.slack_thread_ts != mention_ts:
                mention_files = [a for a in attachments if a.ts == mention_ts]
                try:
                    full_context, full_files = fetch_thread_context(
                        client, ctx.slack_channel, ctx.slack_thread_ts, mention_ts,
                        cfg.thread_context_max_msgs, oldest=None,
                        resolve_name=_make_name_resolver(client),
                    )
                    thread_context = full_context
                    attachments = dedup_refs(mention_files + full_files)
                    log.info("rebuilt full thread context for fresh worktree (files=%d)", len(attachments))
                except Exception as e:  # noqa: BLE001
                    log.warning("full re-fetch failed for %s — using incremental context: %s", thread_key, e)

        result = dispatcher.dispatch(ctx, reuse=reuse, thread_context=thread_context, attachments=attachments)
        try:
            store.save_outcome(ctx.correlation_id, result.to_dict())
        except Exception:
            log.exception("failed to persist outcome for %s", ctx.correlation_id)

        if not result.ok:
            # No agent was launched — free the thread so a retry isn't blocked.
            store.clear_busy(thread_key)
            log.error("dispatch failed correlation=%s error=%s", ctx.correlation_id, result.error)
            if result.scope_error:
                # A missing scope is a config problem — say exactly how to fix it.
                _post(
                    client, ctx.slack_channel, ctx.slack_thread_ts,
                    ":pepe-cry: ช่วยด้วย!! โหลดไฟล์ไม่ได้เลยยยยยย~\n"
                    "นายลืมเพิ่ม `files:read` scope ให้เรารึป่าว. เราขอ `users:read` ด้วยนะ เราจะได้รู้จักกัน :1000056069q:\n"
                    f"reinstall AIworks แล้วก็ลองมันใหม่อีกครั้งนะฮ่ะ. (ref `{ctx.correlation_id}`)\n"
                    f":red_circle: *{result.error}*",
                )
            else:
                _post(
                    client, ctx.slack_channel, ctx.slack_thread_ts,
                    f":im_deadq: อยู่ไม่ไหว อยู่ไม่ไหว เฮ้ย อยู่ไม่ไหว อ้าว! (ref `{ctx.correlation_id}`)\n"
                    f"บ้านนี้มันน่ากลัว กลัว ๆ ๆ อร๊าย! — กูไม่อยากอยู่ กูไม่อยากอยู่ กูไม่อยากอยู่ที่นี่.\n"
                    f":red_circle: *{result.error}*",
                )
            return

        # Persist the thread->worktree mapping. Fixed TTL from creation (never refreshed).
        try:
            if result.reused:
                store.touch_thread(thread_key, {
                    **(mapping or {}),
                    "last_correlation_id": ctx.correlation_id,
                    "last_activity": ctx.created_at,
                    # High-water mark: next follow-up re-scans only messages after this.
                    "last_read_ts": mention_ts,
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
                    # High-water mark: next follow-up re-scans only messages after this.
                    "last_read_ts": mention_ts,
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
            _post(client, channel, thread_ts, ":pepe-tumtum: แก... ไม่! มีสิทธิิ์!!!.")
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

        # Resolve Slack ids -> display names (cached per event), so multi-user threads
        # read clearly in the agent's context. Needs users:read; degrades to raw ids.
        resolve_name = _make_name_resolver(client)

        # Files attached to the mention message itself — present even when the mention is
        # NOT inside a thread (the bootstrap case: a flat @bot with an image).
        mention_ts = event.get("ts", "")
        attachments = refs_from_message(event, resolve_name(user))

        # When the mention is inside a thread, pull the conversation as text context AND
        # its attachments. On a follow-up (mapping exists) only what is NEW since the last
        # turn's high-water mark is re-scanned; on the first turn, the whole thread up to
        # the mention. Hard-fail (no dispatch) if the history is unreadable.
        thread_context = ""
        if thread_ts and thread_ts != mention_ts:
            anchor = mapping.get("last_read_ts") if mapping else None
            try:
                thread_context, thread_files = fetch_thread_context(
                    client, channel, thread_ts, mention_ts, cfg.thread_context_max_msgs,
                    oldest=anchor, resolve_name=resolve_name,
                )
                attachments = dedup_refs(attachments + thread_files)
                log.info(
                    "pulled thread context channel=%s thread=%s chars=%d files=%d since=%s",
                    channel, thread_ts, len(thread_context), len(thread_files), anchor or "start",
                )
            except Exception as e:  # noqa: BLE001
                log.warning("thread fetch failed channel=%s thread=%s: %s", channel, thread_ts, e)
                _post(
                    client, channel, thread_ts,
                    ":confused-numbers: ห๊ะ ห๊ะ อะไรนะ ยังไงสาว.\n"
                    "ขอ scopes `channels:history` (and `groups:history` for private channels) + reinstall AIworks หน่อย\n"
                    "แล้วพูด!!!.",
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
        # Tell the user up-front which attachments won't make it in — two buckets, decided
        # from metadata alone (no download). The prompt's ATTACHMENTS SKIPPED block stays
        # the full source of truth (it also covers .env / download failures / total-cap).
        oversized, unsupported = classify_skips_for_ack(attachments, cfg.attachment_max_file_bytes)
        if oversized:
            _post(
                client, channel, thread_ts,
                f":6537_scaredreb: เดี๋ยววววว!! เกินไป๊ ไฟล์ {cfg.attachment_max_file_mb}MB จะเอากันให้ตายเลยเรอะ: "
                + ", ".join(f"`{n}`" for n in oversized),
            )
        if unsupported:
            _post(
                client, channel, thread_ts,
                ":1000053748: ไฟล์ไรอ่ะ!? ดูดเงินป่ะเนี่ย รับแค่ image / PDF / text สดห้ามผ่อน: "
                + ", ".join(f"`{n}`" for n in unsupported),
            )
        # Heavy (fresh worktree setup can take minutes). Do it off the socket thread.
        threading.Thread(
            target=_run_dispatch,
            args=(ctx, thread_key, mapping, thread_context, attachments, mention_ts, client),
            name=f"dispatch-{ctx.correlation_id}", daemon=True,
        ).start()

    return app
