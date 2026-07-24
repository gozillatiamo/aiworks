"""Dedup + correlation store, backed by a dedicated Redis (docker-compose.yml).

Slack redelivers events; a redelivered app_mention must NOT spawn a second
worktree. `mark_seen` is the guard: SET NX EX — the first caller wins, every
redelivery of the same event key is dropped.

The context + dispatch outcome are also persisted (TTL'd) for tracing and for a
future status/orphan-detection command.
"""

from __future__ import annotations

import json
import logging

import redis

from .correlation import CorrelationContext

log = logging.getLogger("aiworks_dispatch.store")


class RedisStore:
    def __init__(self, url: str, *, dedup_ttl_sec: int, context_ttl_sec: int):
        self._r = redis.Redis.from_url(url, decode_responses=True)
        self._dedup_ttl = dedup_ttl_sec
        self._context_ttl = context_ttl_sec
        # Fail fast: a dead Redis at boot is a misconfiguration, not a runtime hiccup.
        self._r.ping()
        log.info("connected to Redis at %s", url)

    def mark_seen(self, event_key: str) -> bool:
        """True if this event key is new (process it); False if a duplicate."""
        # SET returns True when the key was set, None when NX failed (already present).
        was_set = self._r.set(f"seen:{event_key}", "1", nx=True, ex=self._dedup_ttl)
        return bool(was_set)

    def save_context(self, ctx: CorrelationContext) -> None:
        self._r.set(
            f"corr:{ctx.correlation_id}",
            json.dumps(ctx.to_dict()),
            ex=self._context_ttl,
        )

    def save_outcome(self, correlation_id: str, outcome: dict) -> None:
        self._r.set(
            f"outcome:{correlation_id}",
            json.dumps(outcome),
            ex=self._context_ttl,
        )

    def get_context(self, correlation_id: str) -> CorrelationContext | None:
        raw = self._r.get(f"corr:{correlation_id}")
        return CorrelationContext.from_dict(json.loads(raw)) if raw else None

    # -- thread continuity --------------------------------------------------

    @staticmethod
    def thread_key(channel: str, thread_ts: str) -> str:
        return f"thread:{channel}:{thread_ts}"

    def get_thread(self, key: str) -> dict | None:
        """The worktree mapping for a Slack thread, or None if never seen / expired."""
        raw = self._r.get(key)
        return json.loads(raw) if raw else None

    def create_thread(self, key: str, data: dict, ttl_sec: int) -> None:
        """First mapping for a thread — TTL is FIXED from here (not refreshed on reuse)."""
        self._r.set(key, json.dumps(data), ex=ttl_sec)

    def touch_thread(self, key: str, data: dict) -> None:
        """Record latest activity WITHOUT resetting the fixed creation TTL."""
        self._r.set(key, json.dumps(data), keepttl=True)

    def is_busy(self, key: str) -> bool:
        return self._r.exists(f"{key}:busy") == 1

    def set_busy(self, key: str, value: str, ttl_sec: int) -> None:
        """Mark a thread's worktree in-use (safety-capped; cleared by the Stop-hook)."""
        self._r.set(f"{key}:busy", value, ex=ttl_sec)

    def clear_busy(self, key: str) -> None:
        self._r.delete(f"{key}:busy")
