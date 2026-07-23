"""Correlation identity — the linchpin that pairs a dispatched agent with the
Slack thread it must answer.

The id is minted INDEPENDENTLY of the user's text (which is untrusted) and then
paired with the captured Slack context. It is URL-safe, git-branch-safe, and
unique per mention.
"""

from __future__ import annotations

import re
import secrets
import string
from dataclasses import asdict, dataclass
from datetime import datetime, timezone

_ID_ALPHABET = string.ascii_lowercase + string.digits
_SLUG_RE = re.compile(r"[^a-z0-9-]+")


@dataclass(frozen=True)
class CorrelationContext:
    correlation_id: str   # stable, git-safe, unique per mention (e.g. req-ab12cd34ef)
    slack_channel: str    # event.channel
    slack_thread_ts: str  # event.thread_ts ?? event.ts — reply into the right thread
    slack_user_id: str    # event.user
    request_text: str     # mention text, @-mention stripped
    created_at: str       # ISO-8601 UTC

    def to_dict(self) -> dict:
        return asdict(self)

    @staticmethod
    def from_dict(d: dict) -> "CorrelationContext":
        return CorrelationContext(**d)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_correlation_id() -> str:
    """`req-` + 10 lowercase-alnum chars. Not derived from user input."""
    return "req-" + "".join(secrets.choice(_ID_ALPHABET) for _ in range(10))


def git_safe_slug(value: str, max_len: int = 40) -> str:
    """Reduce to [a-z0-9-], collapse runs of separators, trim to max_len.

    A minted correlation_id already satisfies this; the function stays defensive
    so the workspace/branch name is always a valid git ref.
    """
    slug = _SLUG_RE.sub("-", value.lower()).strip("-")
    slug = re.sub(r"-{2,}", "-", slug)
    return slug[:max_len].strip("-") or "req"
