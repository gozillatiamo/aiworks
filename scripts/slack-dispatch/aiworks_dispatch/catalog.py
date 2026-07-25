"""What this workspace can be asked for — its subagents and its workflows.

Pure parsing, no Slack dependency: what exists (`.claude/agents/<name>.md`,
`.claude/workflows/<name>.js`), a one-line summary for each, and how a leading
`role:<name>` / `workflow:<name>` is peeled off a request.

The prefix is `role:` and NOT `@name` on purpose: Slack linkifies an `@handle` that
collides with a real user or usergroup into `<@U…>` / `<!subteam^…>`, and leading
mentions are stripped before parsing — routing would silently vanish for exactly the
names most likely to collide. `role:` / `workflow:` are never linkified.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path

log = logging.getLogger("aiworks_dispatch.catalog")

ROLE = "role"
WORKFLOW = "workflow"

# `role:` / `roles:` (and the workflow pair) — the plural is a free typo tolerance.
_TOKEN = {
    kind: re.compile(rf"^{kind}s?:\s*([a-zA-Z][a-zA-Z0-9-]*)(?:\s+|$)", re.IGNORECASE)
    for kind in (ROLE, WORKFLOW)
}
# `role:list` asks WHO can be routed to, `workflow:list` WHAT can be run. Both are
# answered inline from disk — no worktree, no agent, no busy flag — so they stay instant
# even while a turn is running. Reserved: no agent or workflow may be named `list`.
LIST_TOKENS = frozenset({"list", "lists"})

_FRONTMATTER = re.compile(r"\A---\s*\n(.*?)\n---\s*\n", re.DOTALL)
_DESCRIPTION = re.compile(r"^description:\s*(.+?)\s*$", re.MULTILINE)
_SENTENCE_SPLIT = re.compile(
    r"(?<!\be\.g\.)(?<!\bi\.e\.)(?<!\betc\.)(?<!\bvs\.)(?<!\bcf\.)(?<=[.!?])\s+"
)
# Seniority padding — "(20 yrs)", "(10+ yrs scaling … to unicorn velocity)". Says nothing
# about what the role DOES, and it eats the character budget the duty needs. Parentheses
# without a yrs/years mention ("(dev/staging/prod)", "(e.g. FM-<n>)") are kept.
_EXPERIENCE = re.compile(r"\s*\([^()]*\b(?:yrs?|years?)\b[^()]*\)")

SUMMARY_MAX_CHARS = 130
_SUMMARY_MIN_CHARS = 70  # a title-only lead-in ("Emily — elite Chief Product Officer &
#                         UX Strategist.") clears 45 on its own, so keep pulling
#                         sentences until there is room for what it actually DOES.

# `export const meta = { name: 'dev-cycle', description: '…', whenToUse: '…', … }`
_META_START = re.compile(r"export\s+const\s+meta\s*=\s*\{")
_META_WINDOW = 24_000  # meta sits at the top; dev-cycle.js itself is 118 KB
_JS_STRING = r"(?:'((?:[^'\\]|\\.)*)'|\"((?:[^\"\\]|\\.)*)\"|`((?:[^`\\]|\\.)*)`)"
_JS_UNESCAPE = re.compile(r"\\(['\"`\\])")


# -- discovery -------------------------------------------------------------------

def _dir(workspace_root: str, kind: str) -> Path:
    return Path(workspace_root, ".claude", "agents" if kind == ROLE else "workflows")


def _paths(workspace_root: str, kind: str) -> list[Path]:
    suffix = "*.md" if kind == ROLE else "*.js"
    try:
        return sorted(_dir(workspace_root, kind).glob(suffix))
    except OSError as e:  # noqa: BLE001
        log.warning("cannot list %s: %s", _dir(workspace_root, kind), e)
        return []


def available_roles(workspace_root: str) -> set[str]:
    """Role names — `.claude/agents/<name>.md` filenames.

    Read per mention (a handful of files, negligible) so a newly added agent works
    without a service restart. An unreadable directory yields an empty set, which turns
    every `role:<name>` into an unknown-name reply rather than a silent mis-dispatch.
    """
    return {p.stem.lower() for p in _paths(workspace_root, ROLE)}


def available_workflows(workspace_root: str) -> set[str]:
    """Workflow names — `.claude/workflows/<name>.js` filenames."""
    return {p.stem.lower() for p in _paths(workspace_root, WORKFLOW)}


# -- summaries -------------------------------------------------------------------

def _summarize(text: str) -> str:
    """One line: whole sentences up to SUMMARY_MAX_CHARS.

    The first sentence alone when it already says what the thing does, otherwise the
    next one too (many descriptions open with a title-only lead-in). Trailing
    model/effort notes fall off the end.
    """
    text = _EXPERIENCE.sub("", (text or "").strip().strip("\"'"))
    parts = [s for s in _SENTENCE_SPLIT.split(text) if s]
    if not parts:
        return ""
    summary, i = parts[0], 1
    while len(summary) < _SUMMARY_MIN_CHARS and i < len(parts):
        summary = f"{summary} {parts[i]}"
        i += 1
    if len(summary) > SUMMARY_MAX_CHARS:
        cut = summary[: SUMMARY_MAX_CHARS - 1]
        space = cut.rfind(" ")
        if space > SUMMARY_MAX_CHARS - 25:  # word boundary, but never gut the line
            cut = cut[:space]
        summary = cut.rstrip(" ,;:—-") + "…"
    return summary


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as e:  # noqa: BLE001
        log.warning("cannot read %s: %s", path, e)
        return ""


def _agent_description(md: str) -> str:
    """The frontmatter `description:` of an agent definition."""
    fm = _FRONTMATTER.match(md)
    if not fm:
        return ""
    found = _DESCRIPTION.search(fm.group(1))
    return found.group(1) if found else ""


def _js_field(block: str, key: str) -> str:
    """A single-line string field of a JS object literal, unescaped."""
    m = re.search(rf"^\s*{key}:\s*{_JS_STRING}", block, re.MULTILINE)
    if not m:
        return ""
    raw = next((g for g in m.groups() if g is not None), "")
    return _JS_UNESCAPE.sub(r"\1", raw).replace("\\n", " ").strip()


def _workflow_description(js: str) -> str:
    """`whenToUse` from a workflow's meta, falling back to `description`.

    `whenToUse` states the purpose in one sentence; `description` is the model-facing
    spec and runs to thousands of characters.
    """
    start = _META_START.search(js)
    if not start:
        return ""
    block = js[start.end(): start.end() + _META_WINDOW]
    return _js_field(block, "whenToUse") or _js_field(block, "description")


def summaries(workspace_root: str, kind: str) -> list[tuple[str, str]]:
    """`(name, summary)` for every definition of `kind`, sorted by name. The summary may
    be empty (malformed or description-less file) — the name is still listed, since it
    is still invokable."""
    describe = _agent_description if kind == ROLE else _workflow_description
    return [(p.stem.lower(), _summarize(describe(_read(p)))) for p in _paths(workspace_root, kind)]


def role_duties(workspace_root: str) -> list[tuple[str, str]]:
    return summaries(workspace_root, ROLE)


def workflow_summaries(workspace_root: str) -> list[tuple[str, str]]:
    return summaries(workspace_root, WORKFLOW)


# -- request parsing -------------------------------------------------------------

def is_list_request(text: str, kind: str) -> bool:
    """True for `<kind>:list` / `<kind>:lists`. Anything trailing ("role:list agents")
    still just lists."""
    m = _TOKEN[kind].match((text or "").strip())
    return bool(m and m.group(1).lower() in LIST_TOKENS)


def split_prefixed(text: str, kind: str, names: set[str]) -> tuple[str, str, str]:
    """Peel a leading `<kind>:<name>` off the request text.

    Returns `(name, remaining_text, unknown_token)` — at most one of name/unknown_token
    is ever set. An unknown name is reported rather than ignored: the prefix is explicit
    enough that nobody types it by accident, so it always means routing was intended —
    running it as prose would quietly do the work under a different plan than asked.
    """
    text = (text or "").strip()
    m = _TOKEN[kind].match(text)
    if not m:
        return "", text, ""
    token = m.group(1).lower()
    if token in names:
        return token, text[m.end():].strip(), ""
    return "", text, token


def is_role_list(text: str) -> bool:
    return is_list_request(text, ROLE)


def is_workflow_list(text: str) -> bool:
    return is_list_request(text, WORKFLOW)


def split_role(text: str, roles: set[str]) -> tuple[str, str, str]:
    return split_prefixed(text, ROLE, roles)


def split_workflow(text: str, workflows: set[str]) -> tuple[str, str, str]:
    return split_prefixed(text, WORKFLOW, workflows)
