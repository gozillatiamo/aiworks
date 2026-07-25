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
    dedup_refs,
    fmt_ts,
    partition_attachments,
    refs_from_message,
)
from .config import Config
from .correlation import CorrelationContext, new_correlation_id, now_iso
from .dispatcher import Dispatcher
from .catalog import (
    agent_duties,
    available_agents,
    available_workflows,
    is_agent_list,
    is_workflow_list,
    split_agent,
    split_workflow,
    workflow_summaries,
)
from .store import RedisStore

log = logging.getLogger("aiworks_dispatch.slack")

_LEADING_MENTIONS = re.compile(r"^(?:\s*<@[^>]+>\s*)+")

# Slack refuses a message over 4000 chars; leave room for the header + markdown.
_MAX_POST_CHARS = 3500

_USAGE = (
    "Mention me with a request or a slash command, e.g.\n"
    "• `@aiworks /prd OFB-123`\n"
    "• `@aiworks /dev-cycle OFB-45`\n"
    "• `@aiworks investigate why payouts are slow in front-end`\n"
    "• `@aiworks agent:developer implement OFB-45 per the plan on the ticket` "
    "(a leading `agent:<name>` hands the whole request to that subagent)\n"
    "`agent:list` shows every agent, `workflow:list` every workflow.\n"
    "I'll spin up a worktree, run Claude on it, and reply in this thread when done."
)


def _strip_mentions(text: str) -> str:
    return _LEADING_MENTIONS.sub("", text or "").strip()


def _render_list(header: str, empty: str, prefix: str, items: list[tuple[str, str]]) -> list[str]:
    """A catalog listing, split into postable chunks (Slack caps a message at 4000
    chars). Returns one string per message, in order."""
    if not items:
        return [empty]
    lines = [f"• `{prefix}:{name}` — {summary}" if summary else f"• `{prefix}:{name}`"
             for name, summary in items]
    chunks, current = [], header
    for line in lines:
        if len(current) + len(line) + 1 > _MAX_POST_CHARS:
            chunks.append(current)
            current = line
        else:
            current = f"{current}\n{line}"
    chunks.append(current)
    return chunks


def render_agent_list(duties: list[tuple[str, str]]) -> list[str]:
    """The `agent:list` answer — who a request can be routed to."""
    return _render_list(
        header=(
            f":claude-wave: เรามีกีกี้ให้เลือกสรร {len(duties)} ตัว\n"
            "พิมพ์ `agent:<name> <คำสั่ง>`\n"
            "เช่น `agent:developer implement OFB-45`.\n"
            "ถ้าขี้เกียจก็ใช้ workflow ซะ — เช็คด้วย `workflow:list`."
        ),
        empty=(
            ":confused_dog: ผู้ใด๋น้อ? — `.claude/agents/` ว่างหรืออ่านไม่ได้.\n"
            "เช็ค `WORKSPACE_ROOT` ใน `env` ว่าชี้ที่ meta-repo main clone รึเปล่า."
        ),
        prefix="agent",
        items=duties,
    )


def render_workflow_list(flows: list[tuple[str, str]]) -> list[str]:
    """The `workflow:list` answer — the multi-agent pipelines that can be run."""
    return _render_list(
        header=(
            f":claude-wave: แด่ท่านผู้ขี้เกียจทั้งหลาย เรามี workflow ที่รันได้ {len(flows)} ตัว\n"
            "พิมพ์ `/dev-cycle OFB-45`\n"
            "หรือ `workflow:dev-cycle OFB-45` ก็ได้ (ค่าเดียวกัน).\n"
            "ถ้าอยากจิกรายตัว - เช็คด้วย `agent:list`."
        ),
        empty=(
            ":confused_dog: ไม่เจอ workflow เลยแฮะ — `.claude/workflows/` ว่างหรืออ่านไม่ได้.\n"
            "เช็ค `WORKSPACE_ROOT` ใน `env` ว่าชี้ที่ meta-repo main clone รึเปล่า."
        ),
        prefix="workflow",
        items=flows,
    )


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

    def _post_skip_notices(client, channel: str, thread_ts: str, part) -> None:  # noqa: ANN001
        """Announce which of the mention's files won't be read — the two buckets the user
        asked for (size / type), plus a secrets note. Reused by the stop path and the
        proceed path so the copy stays in one place."""
        if part.oversized:
            _post(
                client, channel, thread_ts,
                f":6537_scaredreb: เดี๋ยววววว!! เกินไป๊ ไฟล์ {cfg.attachment_max_file_mb}MB จะเอากันให้ตายเลยเรอะ: "
                + ", ".join(f"`{n}`" for n in part.oversized),
            )
        if part.unsupported:
            _post(
                client, channel, thread_ts,
                ":1000053748: ไฟล์ไรอ่ะ!? ดูดเงินป่ะเนี่ย รับแค่ image / PDF / text สดห้ามผ่อน: "
                + ", ".join(f"`{n}`" for n in part.unsupported),
            )
        if part.secret:
            _post(
                client, channel, thread_ts,
                ":refuse: No no ไม่รู้ๆ (.env / secrets) ไม่ยุ่งๆ: "
                + ", ".join(f"`{n}`" for n in part.secret),
            )

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
        # `agent:list` / `workflow:list` — answered inline from disk. No worktree, no
        # agent, no busy flag, and deliberately BEFORE the busy check so they still
        # answer while a turn is running.
        for kind, is_list, load, render in (
            ("agent", is_agent_list, agent_duties, render_agent_list),
            ("workflow", is_workflow_list, workflow_summaries, render_workflow_list),
        ):
            if is_list(request_text):
                items = load(cfg.workspace_root)
                log.info("%s list channel=%s user=%s count=%d", kind, channel, user, len(items))
                store.mark_ignored(event_key, f"{kind}:list (answered inline)")
                for chunk in render(items):
                    _post(client, channel, thread_ts, chunk)
                return

        # `workflow:<name> <args>` is sugar for the slash command the session already
        # understands — rewrite it and let the normal path run the workflow.
        workflows = available_workflows(cfg.workspace_root)
        flow, rest, unknown_flow = split_workflow(request_text, workflows)
        if unknown_flow:
            log.info("unknown workflow %s channel=%s user=%s", unknown_flow, channel, user)
            store.mark_ignored(event_key, f"unknown workflow workflow:{unknown_flow}")
            _post(
                client, channel, thread_ts,
                f":272trumpq: `workflow:{unknown_flow}` คืออะไรอ่ะ ไม่มีน้า.\n"
                ":claude-wave: ที่รันได้: " + ", ".join(f"`{w}`" for w in sorted(workflows))
                + "\nรายละเอียดพิมพ์ `workflow:list`. อยากจิกรายตัวใช้ `agent:list`.",
            )
            return
        if flow:
            request_text = f"/{flow} {rest}".strip()

        # Optional routing: a leading `agent:<name>` hands the request to that subagent.
        # Resolved BEFORE the empty-request check so `@aiworks agent:developer` + a file
        # alone still counts as a files-only request rather than falling through to USAGE.
        agents = available_agents(cfg.workspace_root)
        agent_name, request_text, unknown_agent = split_agent(request_text, agents)
        if unknown_agent:
            log.info("unknown agent %s channel=%s user=%s", unknown_agent, channel, user)
            store.mark_ignored(event_key, f"unknown agent agent:{unknown_agent}")
            _post(
                client, channel, thread_ts,
                f":confused_dog: ผู้ใด๋น้อ? `agent:{unknown_agent}` มึงใครเนี่ยยย.\n"
                ":claude-wave: อ้ายมีกันแค่นี้: "
                + ", ".join(f"`agent:{a}`" for a in sorted(agents))
                + "\nสนใจติดต่อ `agent:list` ได้นะ.\n"
                + "ถ้าไม่รักกัน ก็เอา `agent:` ออกไปได้เลยไม่ต้องแคร์หรอก :milk_sulk:.",
            )
            return
        # A mention can carry its whole request in an attachment (text.md, a screenshot,
        # …) with no message text — only bail to USAGE when there is NEITHER text NOR a
        # file. (Thread-only context still needs some text on the mention to act on.)
        if not request_text and not event.get("files"):
            _post(client, channel, thread_ts, _USAGE)
            return

        # Resolve Slack ids -> display names (cached per event), so multi-user threads
        # read clearly in the agent's context. Needs users:read; degrades to raw ids.
        resolve_name = _make_name_resolver(client)

        # Files attached to the mention message itself — present even when the mention is
        # NOT inside a thread (the bootstrap case: a flat @bot with an image).
        mention_ts = event.get("ts", "")
        mention_files = refs_from_message(event, resolve_name(user))

        # If the user attached file(s) to THIS mention and NONE are usable (all too big /
        # unsupported / secrets), there is nothing to act on — acknowledge with the reason
        # and STOP, before claiming the thread or spinning up a worktree. Don't burn a heavy
        # worktree (21-repo clone) on an input we already know we can't read.
        part = partition_attachments(mention_files, cfg.attachment_max_file_bytes)
        if mention_files and not part.usable:
            _post_skip_notices(client, channel, thread_ts, part)
            _post(
                client, channel, thread_ts,
                ":no_entry_sign: ไม่มีไฟล์ที่อ่านได้เลย — ขออนุญาตผ่าน นะฮ่ะ.\n"
                f"ส่งไฟล์ใหม่ที่เล็กกว่า {cfg.attachment_max_file_mb}MB/ชนิดที่รองรับ แล้ว mention มาใหม่นะ.",
            )
            store.mark_ignored(
                event_key,
                f"unusable attachments oversized={part.oversized} unsupported={part.unsupported} secret={part.secret}",
            )
            log.info(
                "ignored mention (no usable attachments) channel=%s user=%s over=%s unsup=%s secret=%s",
                channel, user, part.oversized, part.unsupported, part.secret,
            )
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
        attachments = list(mention_files)

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

        # Files-only mention: give the agent an explicit instruction instead of a blank
        # request, so the ATTACHMENTS block below is understood as the task.
        if not request_text:
            request_text = (
                "(No text accompanied this mention — the request is in the attached "
                "file(s) and/or this thread. Read them and act accordingly.)"
            )

        ctx = CorrelationContext(
            correlation_id=new_correlation_id(),
            slack_channel=channel,
            slack_thread_ts=thread_ts,
            slack_user_id=user,
            request_text=request_text,
            created_at=now_iso(),
            agent_name=agent_name,
        )
        try:
            store.save_context(ctx)
        except Exception:
            log.exception("failed to persist context for %s", ctx.correlation_id)

        # Claim the thread before acking so a near-simultaneous mention is rejected.
        store.set_busy(thread_key, ctx.correlation_id, cfg.busy_ttl_sec)

        continuing = mapping is not None
        log.info(
            "accepted correlation=%s channel=%s user=%s continuing=%s agent=%s",
            ctx.correlation_id, channel, user, continuing, agent_name or "-",
        )
        agent_note = f" - :fullsend: ฉันเลือกนาย `{agent_name}` ปั่นงานแสนโวลต์!!! :pikachu-hehe:" if agent_name else ""
        _post(
            client, channel, thread_ts,
            f":typingcat: จัดไปไอหนู{agent_note} — {'พี่ไม่เหนื่อยอยู่แล้ว!!' if continuing else 'ใช้งานมาหนักๆ ไม่ต้องเกรงใจหรอก :glassespepeq:'} "
            f"ตื่นๆ มีเรื่องว่ะ :petclaude:. ใจร่มๆ พักชมสิ่งที่น่าสนใจสักครู่ :bananadance_duo:. (ref: `{ctx.correlation_id}`)",
        )
        # Partially-unusable mention still dispatches (a usable file and/or text remains) —
        # just tell the user which attachments were skipped. Same partition decided before
        # the busy check; the prompt's ATTACHMENTS SKIPPED block stays the full source of
        # truth (it also covers thread-file skips / download failures / total-cap).
        _post_skip_notices(client, channel, thread_ts, part)
        # Heavy (fresh worktree setup can take minutes). Do it off the socket thread.
        threading.Thread(
            target=_run_dispatch,
            args=(ctx, thread_key, mapping, thread_context, attachments, mention_ts, client),
            name=f"dispatch-{ctx.correlation_id}", daemon=True,
        ).start()

    return app
