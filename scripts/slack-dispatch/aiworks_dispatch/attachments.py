"""Slack file attachments: select, download into the worktree, format for the prompt.

Files referenced in the triggering mention AND in the thread it belongs to are
downloaded into the (reused or fresh) worktree so the dispatched Claude agent can
Read them — images and PDFs natively, text-like files as text. Selection is
type-filtered and capped; download is IDEMPOTENT (keyed by the Slack file id, so a
follow-up turn that re-scans the thread never re-fetches a file already on disk)
and per-file SOFT-DEGRADING — a single broken/oversized/unsupported file is noted
and skipped rather than failing the turn. The ONE exception is an auth failure,
which means the bot is missing the `files:read` scope: that raises
`AttachmentScopeError` so the caller can hard-fail with an actionable message.

Claude cannot read audio or video (no such input modality), so those are not in
the allowlist — supporting them would require a preprocessing stage (ffmpeg frame
extraction / speech-to-text) that this module deliberately does not have.
"""

from __future__ import annotations

import logging
import os
import re
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone

log = logging.getLogger("aiworks_dispatch.attachments")

# mimetypes / extensions Claude Code's Read tool can actually consume. Images are
# rendered visually; PDFs are read by page; text-like files are read as text. NB:
# no audio/* or video/* — Claude has no audio/video input modality.
_IMAGE_MIMES = {"image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp"}
_DOC_MIMES = {"application/pdf"}
_TEXT_EXT = {
    "txt", "text", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "xml",
    "html", "htm", "log", "toml", "ini", "conf", "cfg", "properties", "sql", "sh",
    "bash", "zsh", "rs", "go", "java", "kt", "c", "h", "cpp", "hpp", "cs", "rb",
    "php", "py", "js", "jsx", "ts", "tsx", "vue", "svelte", "css", "scss",
    "dockerfile", "gradle", "diff", "patch",
}

# A file literally named .env / .env.something is a secrets file — never download
# it into the worktree (the workspace .env guard would block Reading it anyway).
_DOTENV_RE = re.compile(r"^\.env(\..+)?$")


class AttachmentScopeError(RuntimeError):
    """A download failed authentication — the bot is missing the files:read scope."""


@dataclass
class SlackFileRef:
    """A file attached to a Slack message, plus who/when, and (once fetched) its
    on-disk path RELATIVE to the worktree root (the agent's cwd)."""

    id: str
    name: str
    mimetype: str
    size: int          # bytes (0 when Slack omits it)
    url_private: str   # download URL — requires `Authorization: Bearer <bot token>`
    author: str        # resolved display name, or the raw id if lookup failed
    ts: str            # Slack ts of the message the file was on
    local_path: str = ""  # e.g. .aiworks/attachments/F123__diagram.png (set on success)


# -- formatting helpers (shared with prompt.py) -----------------------------------

def fmt_ts(ts: str) -> str:
    """Slack epoch ts -> a human-readable UTC stamp for multi-user context lines."""
    try:
        return datetime.fromtimestamp(float(ts), tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    except (TypeError, ValueError):
        return ts or "?"


def human_size(n: int) -> str:
    if n < 1024:
        return f"{n} B"
    if n < 1024 * 1024:
        return f"{n / 1024:.0f} KB"
    return f"{n / (1024 * 1024):.1f} MB"


# -- selection --------------------------------------------------------------------

def _basename(name: str) -> str:
    return os.path.basename(name or "")


def _is_secretish(name: str) -> bool:
    return bool(_DOTENV_RE.match(_basename(name)))


def _is_allowed(name: str, mimetype: str) -> bool:
    mt = (mimetype or "").lower()
    if mt in _IMAGE_MIMES or mt in _DOC_MIMES or mt.startswith("text/"):
        return True
    base = _basename(name).lower()
    ext = base.rsplit(".", 1)[-1] if "." in base else base  # "Dockerfile" -> "dockerfile"
    return ext in _TEXT_EXT


def _safe_name(name: str) -> str:
    base = _basename(name) or "file"
    return re.sub(r"[^A-Za-z0-9._-]", "_", base)[:100] or "file"


def refs_from_message(message: dict, author: str) -> list[SlackFileRef]:
    """Extract SlackFileRefs from a message-shaped dict (a thread message OR the
    raw app_mention event — both carry `files` and `ts`)."""
    out: list[SlackFileRef] = []
    for f in message.get("files", []) or []:
        url = f.get("url_private_download") or f.get("url_private")
        fid = f.get("id")
        if not url or not fid:
            continue  # tombstoned/hidden file object — nothing to fetch
        out.append(
            SlackFileRef(
                id=fid,
                name=f.get("name") or f.get("title") or fid,
                mimetype=f.get("mimetype") or "",
                size=int(f.get("size") or 0),
                url_private=url,
                author=author,
                ts=message.get("ts", ""),
            )
        )
    return out


def dedup_refs(refs: list[SlackFileRef]) -> list[SlackFileRef]:
    """First occurrence wins — the same file can appear in >1 fetched message."""
    seen: set[str] = set()
    out: list[SlackFileRef] = []
    for r in refs:
        if r.id in seen:
            continue
        seen.add(r.id)
        out.append(r)
    return out


def classify_skips_for_ack(refs: list[SlackFileRef], max_file_bytes: int) -> tuple[list[str], list[str]]:
    """Split refs into (oversized_names, unsupported_names) from METADATA ALONE — no
    download — so the two buckets can be surfaced in the Slack ack before dispatch.

    Mirrors `download_attachments` precedence (type checked before size). Secrets/.env
    and (unknowable pre-download) transient failures are NOT surfaced here — they stay
    prompt-only notes. Total-cap overflow also stays prompt-only (it depends on fetch
    order, so it can't be attributed to a specific file up front)."""
    oversized: list[str] = []
    unsupported: list[str] = []
    for f in dedup_refs(refs):
        if _is_secretish(f.name):
            continue
        if not _is_allowed(f.name, f.mimetype):
            unsupported.append(f.name)
        elif f.size and f.size > max_file_bytes:
            oversized.append(f.name)
    return oversized, unsupported


# -- download ---------------------------------------------------------------------

def _download_one(url: str, token: str, dest: str, timeout: int = 30) -> int:
    """Download to `dest` (atomically via a .part temp). Returns bytes written.
    Raises AttachmentScopeError on an auth failure (missing files:read scope)."""
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 (Slack https url)
            ctype = (resp.headers.get("Content-Type") or "").lower()
            # A bad/absent token makes Slack serve the HTML login page, not the file.
            if "text/html" in ctype:
                raise AttachmentScopeError("url_private returned an HTML page (bad/missing token)")
            data = resp.read()
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise AttachmentScopeError(f"HTTP {e.code} on url_private") from e
        raise
    tmp = dest + ".part"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, dest)
    return len(data)


def download_attachments(
    refs: list[SlackFileRef],
    worktree_path: str,
    *,
    bot_token: str,
    max_files: int,
    max_file_bytes: int,
    total_bytes: int,
) -> tuple[list[SlackFileRef], list[str]]:
    """Download the allowed subset of `refs` into <worktree>/.aiworks/attachments/.

    Returns (downloaded, notes): `downloaded` refs have their `local_path` set to a
    worktree-relative path; `notes` are human-readable reasons for each skip (fed
    into the prompt so the agent knows what it can't see). Raises
    AttachmentScopeError on the first auth failure (the bot lacks files:read).
    """
    downloaded: list[SlackFileRef] = []
    notes: list[str] = []
    if not refs:
        return downloaded, notes
    if not worktree_path or not os.path.isdir(worktree_path):
        log.warning("worktree not ready (%r) — skipping %d attachment(s)", worktree_path, len(refs))
        notes.append(f"{len(refs)} attachment(s) skipped (worktree not ready to stage files)")
        return downloaded, notes

    rel_dir = os.path.join(".aiworks", "attachments")
    abs_dir = os.path.join(worktree_path, rel_dir)
    os.makedirs(abs_dir, exist_ok=True)
    total = 0

    for f in dedup_refs(refs):
        if len(downloaded) >= max_files:
            notes.append(f"{f.name}: skipped (max {max_files} files reached)")
            continue
        if _is_secretish(f.name):
            notes.append(f"{f.name}: skipped (looks like a secrets/.env file)")
            continue
        if not _is_allowed(f.name, f.mimetype):
            notes.append(f"{f.name}: skipped (unsupported type {f.mimetype or '?'})")
            continue
        if f.size and f.size > max_file_bytes:
            notes.append(f"{f.name}: skipped (> {human_size(max_file_bytes)} per-file cap)")
            continue

        rel = os.path.join(rel_dir, f"{f.id}__{_safe_name(f.name)}")
        dest = os.path.join(worktree_path, rel)

        # Idempotent: a prior turn (worktree reuse) already fetched this exact file.
        if os.path.exists(dest) and (not f.size or os.path.getsize(dest) == f.size):
            f.local_path = rel
            total += os.path.getsize(dest)
            downloaded.append(f)
            continue

        if total + (f.size or 0) > total_bytes:
            notes.append(f"{f.name}: skipped (would exceed {human_size(total_bytes)} total cap)")
            continue

        try:
            written = _download_one(f.url_private, bot_token, dest)
        except AttachmentScopeError:
            raise  # hard-fail: config problem, surfaced by the caller
        except Exception as e:  # noqa: BLE001 — transient/per-file: degrade, keep going
            log.warning("attachment download failed id=%s name=%s: %s", f.id, f.name, e)
            notes.append(f"{f.name}: download failed ({e})")
            continue

        f.local_path = rel
        total += written
        downloaded.append(f)
        log.info("attachment downloaded id=%s name=%s bytes=%d", f.id, f.name, written)

    return downloaded, notes
