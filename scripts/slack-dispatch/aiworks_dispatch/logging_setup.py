"""Log formatting — always ONE line per event, in one of two shapes:

    pretty   human console:  ``07-25 16:26:12.483 INFO  slack_app  │ accepted correlation=…``
    json     machine/grep:   ``{"ts":"2026-07-25T16:26:12.483+07:00","level":…,"msg":…}``

Timestamps are stamped in ``LOG_TZ`` (default ``Asia/Bangkok``) with millisecond
precision — the service dispatches agents whose steps land inside the same second, and
the host's own timezone is not necessarily the team's.

Which one is picked by ``LOG_FORMAT`` (``pretty`` | ``json`` | ``auto``, default
``auto``): auto = pretty when stdout is a TTY, json when it is redirected — so
``./run.sh`` reads nicely in a terminal while ``./run.sh > run.log`` stays
greppable/parseable. Colour is used only on a TTY and is dropped when ``NO_COLOR``
is set.

Single-line is a hard invariant in BOTH shapes: pretty collapses embedded newlines
and flattens a traceback to ``| ExcType: msg at file:line``; json escapes them
inside the string. That keeps every event greppable with one `grep` per event.
"""

from __future__ import annotations

import json
import logging
import os
import re
import sys
import traceback
from datetime import datetime, tzinfo
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

_OUR_PREFIX = "aiworks_dispatch"

# The team reads these logs in Bangkok time regardless of where the host thinks it is.
_DEFAULT_TZ = "Asia/Bangkok"


def resolve_tz(name: str) -> tzinfo | None:
    """ZoneInfo for `name`; None (= the host's local time) if the zone is unknown."""
    zone = (name or "").strip()
    if not zone or zone.lower() == "local":
        return None
    try:
        return ZoneInfo(zone)
    except (ZoneInfoNotFoundError, ValueError):
        print(f"warning: unknown LOG_TZ={zone!r} — falling back to local time", file=sys.stderr)
        return None


def _stamp(created: float, tz: tzinfo | None) -> datetime:
    return datetime.fromtimestamp(created, tz) if tz else datetime.fromtimestamp(created).astimezone()

# Fixed-width level tags so the message column lines up.
_LEVEL_TAG = {
    "DEBUG": "DEBUG",
    "INFO": "INFO ",
    "WARNING": "WARN ",
    "ERROR": "ERROR",
    "CRITICAL": "FATAL",
}

_LEVEL_COLOR = {
    "DEBUG": "\033[38;5;245m",   # grey
    "INFO": "\033[36m",          # cyan
    "WARNING": "\033[33m",       # yellow
    "ERROR": "\033[31m",         # red
    "CRITICAL": "\033[1;97;41m",  # white on red
}

_DIM = "\033[2m"
_RESET = "\033[0m"
_LIT = "\033[35m"  # numbers / booleans / null inside an embedded JSON payload

# Width of the module column. Our own names are short (main, store, slack_app), so a wide
# column is dead space before the `│`; longer ones are truncated. LOG_NAME_WIDTH=0 drops
# the padding entirely (ragged bar, zero wasted space).
_NAME_W = 10

# `key=` inside a message — dimmed so the values stand out (correlation=abc123…).
_KV_KEY = re.compile(r"(?<![\w.])([a-z][\w.]*)=")

# A message often carries a JSON payload (a superset CLI response, a Slack API body).
# Those are re-rendered AS JSON rather than passed through as an opaque blob. Past this
# rendered length pretty gives up on colouring and truncates — the untouched payload is
# always available via LOG_FORMAT=json.
_JSON_MAX = 600
_JSON_DEPTH = 6


def _find_json(text: str) -> tuple[int, int, object] | None:
    """First balanced ``{…}`` / ``[…]`` span in text that really parses, or None.

    Only object/array spans count — a bare number or quoted word inside prose is prose,
    not a payload. Python reprs (single quotes) fail to parse and are left alone.
    """
    decoder = json.JSONDecoder()
    for i, ch in enumerate(text):
        if ch not in "{[":
            continue
        try:
            obj, end = decoder.raw_decode(text, i)
        except ValueError:
            continue
        if isinstance(obj, (dict, list)):
            return i, end, obj
    return None


class _JsonFormatter(logging.Formatter):
    def __init__(self, tz: tzinfo | None = None) -> None:
        super().__init__()
        self.tz = tz

    def format(self, record: logging.LogRecord) -> str:
        msg = record.getMessage()
        payload = {
            # ISO 8601 with milliseconds + offset — sorts lexicographically, parses anywhere.
            "ts": _stamp(record.created, self.tz).isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": msg,
        }
        # An embedded payload is ALSO surfaced as a real nested object, so `jq .data.id`
        # works instead of re-parsing a string. `msg` stays byte-identical for grep.
        found = _find_json(msg)
        if found:
            payload["data"] = found[2]
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False)


class _PrettyFormatter(logging.Formatter):
    """`HH:MM:SS LEVEL logger │ message` — aligned columns, one physical line."""

    def __init__(self, color: bool, name_width: int = _NAME_W, tz: tzinfo | None = None) -> None:
        super().__init__()
        self.color = color
        self.name_width = max(0, name_width)
        self.tz = tz

    def _paint(self, text: str, code: str) -> str:
        return f"{code}{text}{_RESET}" if self.color else text

    def _short_name(self, name: str) -> str:
        """`aiworks_dispatch.slack_app` -> `slack_app`; `slack_sdk.socket_mode.x` -> `slack`."""
        if name == _OUR_PREFIX:
            short = "main"
        elif name.startswith(_OUR_PREFIX + "."):
            short = name[len(_OUR_PREFIX) + 1:]
        else:
            # Third-party (slack_bolt.App, slack_sdk.socket_mode.builtin.client) — the
            # package tells you enough; the dotted tail is noise in a log column.
            short = name.split(".", 1)[0].removesuffix("_sdk").removesuffix("_bolt")
        if self.name_width and len(short) > self.name_width:
            short = short[: self.name_width - 1] + "…"
        return short

    def _flatten_exc(self, record: logging.LogRecord) -> str:
        """Traceback -> a single ` | ExcType: msg at file:line` tail."""
        etype, evalue, tb = record.exc_info  # type: ignore[misc]
        frames = traceback.extract_tb(tb) if tb else []
        where = f" at {Path(frames[-1].filename).name}:{frames[-1].lineno}" if frames else ""
        name = getattr(etype, "__name__", str(etype))
        # The exception text often ends in a JSON payload too — render it the same way.
        detail = f"{name}: {self._render_msg(str(evalue))}{where}".strip()
        return " " + self._paint(f"| {detail}", _LEVEL_COLOR["ERROR"])

    # -- embedded JSON ------------------------------------------------------

    def _json_scalar(self, obj: object) -> str:
        if isinstance(obj, str):
            return json.dumps(obj, ensure_ascii=False)
        return self._paint(json.dumps(obj), _LIT)  # int/float/bool/None

    def _json_compact(self, obj: object, depth: int = 0) -> str:
        """Compact one-line JSON with dimmed keys/punctuation, values left bright."""
        if not self.color or depth >= _JSON_DEPTH:
            return json.dumps(obj, ensure_ascii=False, separators=(", ", ": "))
        dim = lambda s: self._paint(s, _DIM)  # noqa: E731
        if isinstance(obj, dict):
            items = (
                f"{dim(json.dumps(str(k), ensure_ascii=False))}{dim(':')} "
                f"{self._json_compact(v, depth + 1)}"
                for k, v in obj.items()
            )
            return dim("{") + dim(", ").join(items) + dim("}")
        if isinstance(obj, list):
            items = (self._json_compact(v, depth + 1) for v in obj)
            return dim("[") + dim(", ").join(items) + dim("]")
        return self._json_scalar(obj)

    def _render_msg(self, raw: str) -> str:
        """Prose collapsed to one line; an embedded JSON payload re-rendered as JSON.

        Whitespace collapsing runs on the prose only — the payload is rebuilt from the
        parsed object, so a pretty-printed or newline-laden blob lands compact and intact.
        """
        found = _find_json(raw)
        if not found:
            return self._dim_kv(" ".join(raw.split()))
        start, end, obj = found
        plain = json.dumps(obj, ensure_ascii=False, separators=(", ", ": "))
        if len(plain) > _JSON_MAX:
            body = plain[:_JSON_MAX] + self._paint(f"…(+{len(plain) - _JSON_MAX} chars, see LOG_FORMAT=json)", _DIM)
        else:
            body = self._json_compact(obj)
        head = self._dim_kv(" ".join(raw[:start].split()))
        tail = self._render_msg(raw[end:]) if raw[end:].strip() else ""
        return " ".join(part for part in (head, body, tail) if part)

    def _dim_kv(self, text: str) -> str:
        if not self.color:
            return text
        return _KV_KEY.sub(lambda m: self._paint(m.group(1), _DIM) + "=", text)

    def format(self, record: logging.LogRecord) -> str:
        # `YYYY-MM-DD HH:MM:SS.mmm` — full date so a line can be quoted or correlated with
        # a ticket/trace without guessing the year; ms because dispatch steps land inside
        # the same second.
        stamp = _stamp(record.created, self.tz)
        ts = f"{stamp:%Y-%m-%d %H:%M:%S}.{stamp.microsecond // 1000:03d}"
        tag = _LEVEL_TAG.get(record.levelname, record.levelname[:5].ljust(5))
        name = self._short_name(record.name)
        msg = self._render_msg(record.getMessage())

        padded = name.ljust(self.name_width) if self.name_width else name
        if self.color:
            ts = self._paint(ts, _DIM)
            tag = self._paint(tag, _LEVEL_COLOR.get(record.levelname, ""))
            name = self._paint(padded, _DIM)
            bar = self._paint("│", _DIM)
        else:
            name = padded
            bar = "│"

        line = f"{ts} {tag} {name} {bar} {msg}"
        if record.exc_info:
            line += self._flatten_exc(record)
        return line


def _resolve_mode(fmt: str, stream) -> str:  # noqa: ANN001
    mode = (fmt or "auto").strip().lower()
    if mode not in ("pretty", "json", "auto"):
        mode = "auto"
    if mode == "auto":
        mode = "pretty" if getattr(stream, "isatty", lambda: False)() else "json"
    return mode


def setup_logging(
    level: str,
    fmt: str = "auto",
    name_width: int = _NAME_W,
    tz_name: str = _DEFAULT_TZ,
) -> None:
    stream = sys.stdout
    mode = _resolve_mode(fmt, stream)
    color = mode == "pretty" and stream.isatty() and not os.environ.get("NO_COLOR")
    tz = resolve_tz(tz_name)

    handler = logging.StreamHandler(stream)
    handler.setFormatter(
        _PrettyFormatter(color, name_width, tz) if mode == "pretty" else _JsonFormatter(tz)
    )
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(getattr(logging, level.upper(), logging.INFO))
    # slack_bolt is chatty at INFO on every socket ping — keep it at WARNING.
    logging.getLogger("slack_bolt").setLevel(logging.WARNING)
    logging.getLogger("slack_sdk").setLevel(logging.WARNING)


def _demo() -> None:
    """``python -m aiworks_dispatch.logging_setup`` — sample lines in every shape.

    Cheap way to eyeball the formatters (columns, colour, embedded payloads) without
    starting the service or connecting to Slack.
    """
    handler = logging.StreamHandler(sys.stdout)
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(logging.DEBUG)

    def emit() -> None:
        logging.getLogger(_OUR_PREFIX).info(
            "aiworks-dispatch starting (project=abc123 base=develop agent=claude)")
        logging.getLogger(f"{_OUR_PREFIX}.slack_app").info(
            "accepted correlation=7f3a9b channel=C04NZCMAG94 user=U081LPQ4REH continuing=False role=-")
        logging.getLogger(f"{_OUR_PREFIX}.slack_app").warning("denied mention channel=C999 user=U777")
        logging.getLogger(f"{_OUR_PREFIX}.dispatcher").info(
            'workspace created {\n  "id": "ws_9f2",\n  "worktreePath": "/tmp/wt/slack-7f3a9b",\n'
            '  "healthy": true,\n  "retries": 3\n} reused=False')
        try:
            raise RuntimeError('workspace create returned no id: {"error": {"code": 422}}')
        except RuntimeError:
            logging.getLogger(f"{_OUR_PREFIX}.dispatcher").exception("dispatch failed for 7f3a9b")

    tz = resolve_tz(os.environ.get("LOG_TZ", _DEFAULT_TZ))
    for label, formatter in (
        ("pretty (colour)", _PrettyFormatter(color=True, tz=tz)),
        ("pretty (NO_COLOR)", _PrettyFormatter(color=False, tz=tz)),
        ("pretty (LOG_NAME_WIDTH=0, ragged)", _PrettyFormatter(color=False, name_width=0, tz=tz)),
        ("json", _JsonFormatter(tz)),
    ):
        print(f"── {label} ──")
        handler.setFormatter(formatter)
        emit()
        print()


if __name__ == "__main__":
    _demo()
