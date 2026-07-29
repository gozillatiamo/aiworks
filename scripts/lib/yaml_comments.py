#!/usr/bin/env python3
"""Find and remove YAML comments — the mechanism behind the "no comments in the LIVE
workspace config" rule (docs/adr/0006-config-carries-no-comments.md).

The live config files (`workspace.config.yaml`, `workspace.config.local.yaml`) are DATA.
Every explanation belongs in their `*.example.yaml` templates, which is where a new org
copies from and where `aiworks config`'s drift guard already insists a key be documented.
This module is what makes that mechanical rather than remembered:

    python3 scripts/lib/yaml_comments.py --check workspace.config.yaml   # exit 1 if any
    python3 scripts/lib/yaml_comments.py --strip workspace.config.yaml   # to stdout
    python3 scripts/lib/yaml_comments.py --write workspace.config.yaml   # in place
    ... --check-stdin --label workspace.config.yaml  < proposed-content   # the hook path
    python3 scripts/lib/yaml_comments.py --selftest                      # fixtures

WHY A SCANNER AND NOT `grep '#'`: a `#` is only a comment when it is outside a quoted
scalar and outside a block scalar. This workspace's own config would be corrupted by the
naive version on its very first line of interest — `channel: "#dev-oneforbet"` is a Slack
channel, and `page_naming: "{work_key} / {feature}"`-style quoted values are everywhere.
A stripper that ate that would silently change where notifications go, so the quote/block
state machine below is the point of the file, not decoration.

Stdlib only, and deliberately no PyYAML: this runs from a PreToolUse hook on a teammate's
machine, where an import that may be missing is a guard that fails instead of guarding.
"""

from __future__ import annotations

import re
import sys

# `key: |`, `key: >-`, `- key: |2` … — the header of a block scalar, whose body is verbatim
# text where `#` is content, not a comment. Matched against the line with any trailing
# comment already removed (`key: | # note` is legal).
_BLOCK_RE = re.compile(
    r"""^(\s*)(?:-\s+)?            # indent, optional sequence dash
        (?:[^\s#"']+|"[^"]*"|'[^']*')\s*:   # the key (plain or quoted)
        \s*[|>][+-]?\d*\s*$        # the block indicator and its modifiers
    """,
    re.VERBOSE,
)


def comment_col(line: str) -> int:
    """Index of the `#` that starts a comment on `line`, or -1.

    A `#` opens a comment only when it is outside quotes AND either starts the line or
    follows whitespace — `url: git@host:org/repo#tag` and `"#channel"` are values.
    """
    quote = None  # None | "'" | '"'
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if quote == '"':
            if c == "\\":
                i += 2
                continue
            if c == '"':
                quote = None
        elif quote == "'":
            if c == "'":
                # '' is an escaped single quote inside a single-quoted scalar.
                if i + 1 < n and line[i + 1] == "'":
                    i += 2
                    continue
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "#" and (i == 0 or line[i - 1] in " \t"):
            return i
        i += 1
    return -1


def _walk(text: str):
    """Yield (line, comment_col, in_block) per line, tracking block-scalar bodies."""
    block_indent = None
    for line in text.splitlines():
        if block_indent is not None:
            # A block scalar's body is every following line that is blank or indented
            # deeper than its key. The first line at or left of the key ends it.
            if not line.strip() or (len(line) - len(line.lstrip())) > block_indent:
                yield line, -1, True
                continue
            block_indent = None
        col = comment_col(line)
        head = line[:col] if col >= 0 else line
        m = _BLOCK_RE.match(head)
        yield line, col, False
        if m:
            block_indent = len(m.group(1))


def find(text: str) -> list[tuple[int, str]]:
    """Every comment in `text`, as (1-based line number, the comment text)."""
    out = []
    for no, (line, col, in_block) in enumerate(_walk(text), 1):
        if not in_block and col >= 0:
            out.append((no, line[col:].strip()))
    return out


def strip(text: str) -> str:
    """`text` with every comment removed.

    Values are never touched. A comment-only line disappears entirely; a trailing comment
    leaves its value behind, rstripped. Blank runs left over from a deleted block collapse
    to ONE blank line, so the result reads as blocks rather than as a hole-punched file —
    except inside a block scalar, where a blank line is content.
    """
    kept: list[tuple[str, bool]] = []  # (line, protected)
    for line, col, in_block in _walk(text):
        if in_block:
            kept.append((line, True))
            continue
        if col < 0:
            kept.append((line.rstrip(), False))
            continue
        head = line[:col].rstrip()
        if head:
            kept.append((head, False))
        # else: the whole line was a comment — drop it.

    out: list[str] = []
    for line, protected in kept:
        if protected or line.strip():
            out.append(line)
            continue
        # An unprotected blank: keep it only as a single separator between content.
        if out and out[-1].strip():
            out.append(line)
    while out and not out[-1].strip():
        out.pop()
    return "\n".join(out) + "\n" if out else ""


# ── CLI ───────────────────────────────────────────────────────────────────────────────

_FIX = "python3 scripts/lib/yaml_comments.py --write"


def _report(label: str, hits: list[tuple[int, str]]) -> None:
    for no, txt in hits:
        sys.stderr.write(f"{label}:{no}: {txt[:96]}\n")


def _selftest() -> int:
    cases = [
        # (name, input, expected comment line numbers, expected strip output)
        ("comment-only line", "# hi\na: 1\n", [1], "a: 1\n"),
        ("trailing comment", "a: 1  # hi\n", [1], "a: 1\n"),
        ("quoted hash is a value", 'channel: "#dev-oneforbet"\n', [], 'channel: "#dev-oneforbet"\n'),
        ("single-quoted hash", "c: '#x'\n", [], "c: '#x'\n"),
        ("hash glued to a value", "url: git@host:org/repo#tag\n", [], "url: git@host:org/repo#tag\n"),
        ("quoted then comment", 'c: "#a"  # note\n', [1], 'c: "#a"\n'),
        ("escaped quote then comment", 'c: "a\\"b"  # n\n', [1], 'c: "a\\"b"\n'),
        ("block scalar body kept", "d: |\n  # not a comment\n  x\ne: 1\n", [], "d: |\n  # not a comment\n  x\ne: 1\n"),
        ("block header comment", "d: | # note\n  x\n", [1], "d: |\n  x\n"),
        ("blank run collapses", "a: 1\n\n# c\n\n\nb: 2\n", [3], "a: 1\n\nb: 2\n"),
        ("leading blanks dropped", "# c\n\na: 1\n", [1], "a: 1\n"),
        ("nested indent kept", "a:\n  b: 1   # c\n", [2], "a:\n  b: 1\n"),
        ("all comments", "# a\n# b\n", [1, 2], ""),
    ]
    bad = 0
    for name, src, want_lines, want_out in cases:
        hits = [no for no, _ in find(src)]
        got = strip(src)
        if hits != want_lines:
            bad += 1
            print(f"FAIL {name}: comment lines {hits} != {want_lines}")
        elif got != want_out:
            bad += 1
            print(f"FAIL {name}: strip {got!r} != {want_out!r}")
        else:
            print(f"ok   {name}")
        # Stripping twice must change nothing more — a stripper that is not idempotent
        # is one that eats a line of data on the second pass.
        if strip(got) != got:
            bad += 1
            print(f"FAIL {name}: not idempotent")
    print(f"\n{len(cases)} cases, {bad} failed")
    return 1 if bad else 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    mode, rest = argv[0], argv[1:]

    if mode == "--selftest":
        return _selftest()

    if mode == "--check-stdin":
        label = "input"
        if "--label" in rest:
            i = rest.index("--label")
            if i + 1 < len(rest):
                label = rest[i + 1]
        hits = find(sys.stdin.read())
        _report(label, hits)
        return 1 if hits else 0

    if not rest:
        sys.stderr.write(f"{mode} needs at least one file\n")
        return 2

    if mode == "--check":
        bad = 0
        for path in rest:
            try:
                with open(path, encoding="utf-8") as fh:
                    hits = find(fh.read())
            except OSError as exc:
                sys.stderr.write(f"{path}: {exc}\n")
                return 2
            if hits:
                bad += 1
                _report(path, hits)
        return 1 if bad else 0

    if mode in ("--strip", "--write"):
        for path in rest:
            try:
                with open(path, encoding="utf-8") as fh:
                    out = strip(fh.read())
            except OSError as exc:
                sys.stderr.write(f"{path}: {exc}\n")
                return 2
            if mode == "--strip":
                sys.stdout.write(out)
            else:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(out)
        return 0

    sys.stderr.write(f"unknown mode {mode!r} (see --help)\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
