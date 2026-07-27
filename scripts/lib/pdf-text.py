#!/usr/bin/env python3
"""scripts/lib/pdf-text.py — extract the SCANNABLE TEXT of a PDF for the PII egress gate.

Why this exists
---------------
scripts/lib/pii-scan.sh applies text-shaped regexes. Applied to the raw bytes of a PDF that is
wrong in both directions:

  * FALSE BLOCK — every PDF carries an xref table of 10-digit zero-padded byte offsets
    ("0000000015 00000 n"), which matches the Thai phone detector `\\b0[0-9]{9}\\b`. The gate
    therefore refused 100% of pdf uploads, including a deliverable rendered from a clean,
    tracked repo doc. Renderer identity is a second one: Chrome stamps
    /Creator (HeadlessChrome/150.0.0.0 …), and that version reads as an IPv4.
  * FALSE PASS — the words a human reads are NOT in the file as ASCII. Chrome/Skia embeds
    subset fonts and shows text as glyph codes (`<03EB> Tj`), so a phone number in the body of
    the document is invisible to a byte-level grep. Only each font's /ToUnicode CMap maps those
    codes back to characters.

So this module reconstructs the document the way a reader sees it, stdlib only (no poppler, no
pypdf — the pdf adapter's offline-by-construction rule).

What it returns (stdout, UTF-8, lossy-decoded)
---------------------------------------------
  1. the page text — for every page and form XObject: its content stream inflated, its text
     operators decoded through the /ToUnicode CMap of the font selected by `Tf`. Literals
     inside ONE operator are joined with no separator (kerning splits a run mid-number:
     `[(08) -2 (12345678)] TJ`); operators are separated by a newline, so unrelated numbers on
     different lines are never glued into a phone/id shape the document never contained.
  2. link targets — /URI annotation values (a `mailto:` autolink is real egress).
  3. author-controlled metadata — /Title, /Author, /Subject, /Keywords, XMP packets and object
     streams, with xref lines dropped. /Producer and /Creator are dropped: tool identity, never
     user data.

Deliberately excluded as container noise: content-stream coordinates, embedded font and image
bytes. Not covered (documented limit, same spirit as pii-scan.sh's own notes): text baked into
a raster image, and non-Flate compressed streams — no regex reaches those.

Usage:  pdf-text.py FILE            # prints the scannable text; exit 0
        pdf-text.py --selftest      # fixtures
Exit 3 = not a PDF (caller falls back to its own handling).
"""

import re
import sys
import zlib

_OBJ = re.compile(rb"(?s)(?<![0-9])(\d+)\s+\d+\s+obj\b(.*?)endobj")
_STREAM = re.compile(rb"stream\r?\n?(.*?)\r?\n?endstream", re.S)
_XREF_ENTRY = re.compile(rb"(?m)^[0-9]{10} [0-9]{5} [fn][ \r\n]*$")
# Renderer identity, not user data — see the module docstring.
_TOOL_KEYS = re.compile(rb"/(?:Producer|Creator)\s*(?:\((?:\\.|[^()\\])*\)|<[0-9A-Fa-f\s]*>)", re.S)
_METADATA_BLOB = (b"<?xpacket", b"<x:xmpmeta", b"<rdf:RDF", b"/ObjStm")
_URI = re.compile(rb"/URI\s*\((?P<u>(?:\\.|[^()\\])*)\)", re.S)

_LITERAL = re.compile(rb"\((?P<s>(?:\\.|[^()\\])*)\)", re.S)
_HEX = re.compile(rb"<(?P<h>[0-9A-Fa-f\s]*)>", re.S)
_ELEMENT = re.compile(rb"\((?:\\.|[^()\\])*\)|<[0-9A-Fa-f\s]*>", re.S)
_NUM = rb"[-+]?(?:\d+\.?\d*|\.\d+)"
_TOKEN = re.compile(
    rb"""/(?P<font>[^\s/<>\[\]()]+)\s+""" + _NUM + rb"""\s+Tf
       | \[(?P<arr>[^\]]*)\]\s*TJ
       | (?P<lit>\((?:\\.|[^()\\])*\))\s*(?:Tj|'|")
       | (?P<hex><[0-9A-Fa-f\s]*>)\s*(?:Tj|'|")
       | (?:""" + _NUM + rb"""\s+){5}(?P<tmy>""" + _NUM + rb""")\s+Tm
       | (?P<tdx>""" + _NUM + rb""")\s+(?P<tdy>""" + _NUM + rb""")\s+(?:Td|TD)
       | (?P<nl>T\*|BT|ET)""",
    re.S | re.X,
)
_ESCAPES = {b"n": b"\n", b"r": b"\r", b"t": b"\t", b"b": b"\b", b"f": b"\f"}
# A text-showing operator applied to a string/array operand — the marker that an inflated
# stream is CONTENT (words) rather than a font or image blob.
_SHOW_OP = re.compile(rb"(?:\)|\]|>)\s*(?:Tj|TJ|'|\")")

# --- primitives ---------------------------------------------------------------------------


def _unescape(lit: bytes) -> bytes:
    """Resolve PDF string escapes: \\n \\r \\t \\b \\f \\( \\) \\\\ and \\ooo octal."""
    out = bytearray()
    i = 0
    while i < len(lit):
        c = lit[i : i + 1]
        if c != b"\\":
            out += c
            i += 1
            continue
        nxt = lit[i + 1 : i + 2]
        if nxt in _ESCAPES:
            out += _ESCAPES[nxt]
            i += 2
        elif nxt.isdigit():
            octal = lit[i + 1 : i + 4]
            out.append(int(octal, 8) & 0xFF)
            i += 1 + len(octal)
        else:
            out += nxt
            i += 2
    return bytes(out)


def _inflate(body: bytes):
    """Inflate the FlateDecode stream inside an object body, or None."""
    m = _STREAM.search(body)
    if not m:
        return None
    try:
        return zlib.decompress(m.group(1))
    except zlib.error:
        return None


def _scrub(chunk: bytes) -> bytes:
    """Drop xref offsets, renderer identity, and NULs from a chunk of PDF structure."""
    chunk = _XREF_ENTRY.sub(b" ", chunk)
    chunk = _TOOL_KEYS.sub(b" ", chunk)
    return chunk.replace(b"\x00", b" ")


# --- /ToUnicode CMaps ---------------------------------------------------------------------


def _utf16be(hexdigits: bytes) -> str:
    raw = bytes.fromhex(hexdigits.decode("ascii", "ignore").replace(" ", ""))
    return raw.decode("utf-16-be", "replace")


def _parse_cmap(cmap: bytes):
    """(code_len, {code_int: text}) from a ToUnicode CMap stream."""
    code_len = 1
    space = re.search(rb"begincodespacerange(.*?)endcodespacerange", cmap, re.S)
    if space:
        first = _HEX.search(space.group(1))
        if first:
            code_len = max(1, len(first.group("h").strip()) // 2)

    table = {}
    for block in re.findall(rb"beginbfchar(.*?)endbfchar", cmap, re.S):
        pairs = _HEX.findall(block)
        for src, dst in zip(pairs[::2], pairs[1::2]):
            table[int(src.strip() or b"0", 16)] = _utf16be(dst)
    for block in re.findall(rb"beginbfrange(.*?)endbfrange", cmap, re.S):
        for entry in re.finditer(rb"<([0-9A-Fa-f\s]*)>\s*<([0-9A-Fa-f\s]*)>\s*(\[[^\]]*\]|<[0-9A-Fa-f\s]*>)", block, re.S):
            lo, hi, dst = int(entry.group(1), 16), int(entry.group(2), 16), entry.group(3)
            if dst.startswith(b"["):
                for offset, item in enumerate(_HEX.findall(dst)):
                    table[lo + offset] = _utf16be(item)
            else:
                start = _utf16be(dst.strip(b"<>"))
                for offset in range(hi - lo + 1):
                    table[lo + offset] = chr(ord(start[0]) + offset) + start[1:] if start else ""
    return code_len, table


def _font_maps(objs, resources: bytes):
    """{font name: (code_len, table)} for a /Resources dict body."""
    ref = re.search(rb"/Resources\s+(\d+)\s+\d+\s+R", resources)
    if ref:
        resources = objs.get(int(ref.group(1)), resources)
    fonts = re.search(rb"/Font\s*<<(?P<d>.*?)>>", resources, re.S)
    if not fonts:
        return {}
    maps = {}
    for name, num in re.findall(rb"/([^\s/<>\[\]()]+)\s+(\d+)\s+\d+\s+R", fonts.group("d")):
        font = objs.get(int(num), b"")
        tou = re.search(rb"/ToUnicode\s+(\d+)\s+\d+\s+R", font)
        if not tou:
            continue
        cmap = _inflate(objs.get(int(tou.group(1)), b""))
        if cmap:
            maps[name] = _parse_cmap(cmap)
    return maps


# --- content streams ----------------------------------------------------------------------


def _decode(raw: bytes, font) -> str:
    """Decode one shown string: through the font's CMap when known, else as raw bytes."""
    if not font:
        return raw.decode("utf-8", "replace")
    code_len, table = font
    out = []
    for i in range(0, len(raw) - code_len + 1, code_len):
        code = int.from_bytes(raw[i : i + code_len], "big")
        out.append(table.get(code, ""))
    return "".join(out)


def _elements(chunk: bytes):
    """The string elements of a TJ array / a single show operand, in order."""
    for m in _ELEMENT.finditer(chunk):
        tok = m.group(0)
        if tok.startswith(b"<"):
            digits = tok[1:-1].decode("ascii", "ignore").replace(" ", "")
            if len(digits) % 2:
                digits += "0"
            yield bytes.fromhex(digits)
        else:
            yield _unescape(tok[1:-1])


def _page_text(stream: bytes, maps) -> str:
    """Reduce a content stream to its shown text, ONE VISUAL LINE PER LINE.

    Line breaks come from the text position, not from the operator count: Chrome shows one
    glyph per `Tj` and advances with `tx 0 Td`, so breaking per operator would put every
    character on its own line and no multi-character detector (phone, id, email) could ever
    match. A new line starts only where the text y actually moves — `Tm`'s f, a `Td`/`TD` with
    a non-zero ty, `T*`, or a `BT`/`ET` block boundary. Glyphs sharing a y are the same line
    and are joined as the reader sees them (the space between words is itself a glyph, so real
    spacing survives).
    """
    lines = []
    line = []
    font = None
    y = None

    def flush():
        if line:
            lines.append("".join(line))
            line.clear()

    for m in _TOKEN.finditer(stream):
        if m.group("font") is not None:
            font = maps.get(m.group("font"))
        elif m.group("nl") is not None:
            flush()
            y = None
        elif m.group("tmy") is not None:
            new_y = float(m.group("tmy"))
            if y is not None and new_y != y:
                flush()
            y = new_y
        elif m.group("tdy") is not None:
            ty = float(m.group("tdy"))
            if ty:
                flush()
                y = (y or 0.0) + ty
        elif m.group("arr") is not None:
            # Join the array's elements with NO separator — kerning splits runs mid-number.
            line.append("".join(_decode(e, font) for e in _elements(m.group("arr"))))
        else:
            operand = m.group("lit") or m.group("hex")
            line.append("".join(_decode(e, font) for e in _elements(operand)))
    flush()
    return "\n".join(l for l in lines if l)


# --- public -------------------------------------------------------------------------------


def extract(data: bytes) -> bytes:
    if not data.startswith(b"%PDF"):
        raise ValueError("not a PDF")

    objs = {int(m.group(1)): m.group(2) for m in _OBJ.finditer(data)}
    parts = []
    decoded = set()

    # 1. pages and form XObjects: content stream decoded through its own font resources.
    for body in objs.values():
        if not re.search(rb"/Type\s*/Page\b", body) and not re.search(rb"/Subtype\s*/Form\b", body):
            continue
        maps = _font_maps(objs, body)
        targets = [int(n) for n in re.findall(rb"/Contents\s+(\d+)\s+\d+\s+R", body)]
        for arr in re.findall(rb"/Contents\s*\[(.*?)\]", body, re.S):
            targets += [int(n) for n in re.findall(rb"(\d+)\s+\d+\s+R", arr)]
        own = _inflate(body)  # a form XObject carries its own stream
        streams = [own] if own else []
        for num in targets:
            decoded.add(num)
            streams.append(_inflate(objs.get(num, b"")))
        for stream in streams:
            if stream:
                parts.append(_page_text(stream, maps).encode("utf-8"))

    # 2. link targets — an autolinked mailto: is real egress.
    parts += [_unescape(m.group("u")) for m in _URI.finditer(data)]

    # 3. printable metadata (XMP, object streams). Font/image and already-decoded content
    #    streams are container noise and stay out.
    #
    #    A stream that shows text but that NO page reached is decoded too. That happens when
    #    the /Contents edge is absent or written in a form this regex parser can't follow —
    #    and for a PII backstop an unreachable text stream is the worst possible thing to
    #    skip silently, since its words are still in the file a reader can open. Decoded with
    #    no font map, so it yields the literal string bytes. Font/image streams are excluded
    #    by requiring an actual show operator.
    for num, body in objs.items():
        if num in decoded:
            continue
        blob = _inflate(body)
        if not blob:
            continue
        if any(marker in blob for marker in _METADATA_BLOB):
            parts.append(_scrub(blob))
        elif _SHOW_OP.search(blob):
            parts.append(_page_text(blob, {}).encode("utf-8"))

    parts.append(_scrub(_STREAM.sub(b" ", data)))
    return b"\n".join(p for p in parts if p)


# --- selftest -----------------------------------------------------------------------------


def _selftest() -> int:
    fails = 0

    def check(desc, got, want):
        nonlocal fails
        if want in got:
            print(f"ok   {desc}")
        else:
            print(f"FAIL {desc}: {want!r} not in extracted text")
            fails += 1

    def refute(desc, got, unwanted):
        nonlocal fails
        if unwanted not in got:
            print(f"ok   {desc}")
        else:
            print(f"FAIL {desc}: {unwanted!r} leaked into extracted text")
            fails += 1

    def pdf(content: bytes, extra: bytes = b"", objects: bytes = b"") -> bytes:
        body = zlib.compress(content)
        return (
            b"%PDF-1.4\n1 0 obj\n<</Type /Page /Contents 2 0 obj_REF" + extra + b">>\nendobj\n"
            b"2 0 obj\n<</Length " + str(len(body)).encode() + b">>stream\n" + body + b"\nendstream\nendobj\n"
            + objects +
            b"xref\n0 3\n0000000000 65535 f \n0000000015 00000 n \n0000000327 00000 n \n"
            b"trailer<</Size 3>>\nstartxref\n999\n%%EOF\n"
        ).replace(b"2 0 obj_REF", b"2 0 R")

    def text_of(*a, **k):
        return extract(pdf(*a, **k)).decode("utf-8", "replace")

    check("literal Tj digits survive", text_of(b"BT (hello 0812345678) Tj ET"), "0812345678")
    check("kern-split number rejoins inside one TJ", text_of(b"BT [(08) -20 (12) -5 (345678)] TJ ET"), "0812345678")
    check(
        "same-line glyph operators join (Chrome shows one glyph per Tj)",
        text_of(b"BT 1 0 0 -1 24 81 Tm (08) Tj 5 0 Td (91) Tj 5 0 Td (234567) Tj ET"),
        "0891234567",
    )
    refute(
        "a y move breaks the line",
        text_of(b"BT 1 0 0 -1 24 81 Tm (ADR 0) Tj 0 -12 Td (123456789 rows) Tj ET"),
        "0123456789",
    )
    refute(
        "T* breaks the line",
        text_of(b"BT (ADR 0) Tj T* (123456789 rows) Tj ET"),
        "0123456789",
    )
    check("metadata dict is scanned", text_of(b"BT (x) Tj ET", extra=b" /Author (a@b.co)"), "a@b.co")
    check("annotation /URI is scanned", text_of(b"BT (x) Tj ET", extra=b" /A <</URI (mailto:a@b.co)>>"), "a@b.co")
    refute("xref offsets are stripped", text_of(b"BT (x) Tj ET"), "0000000015")
    refute(
        "renderer identity is dropped",
        text_of(b"BT (x) Tj ET", extra=b" /Producer (Skia/PDF m150) /Creator (HeadlessChrome/150.0.0.0)"),
        "150.0.0.0",
    )
    soup = text_of(b"q 1.5 0 0 1.5 0 0 cm /F1 12 Tf BT (text) Tj ET Q")
    check("page text kept from a content stream", soup, "text")
    refute("content-stream operators excluded", soup, "cm")

    # A subset font shows glyph codes; only the /ToUnicode CMap makes them readable.
    cmap = zlib.compress(
        b"/CMapType 2 def\n1 begincodespacerange\n<00> <FF>\nendcodespacerange\n"
        b"3 beginbfchar\n<03> <0030>\n<04> <0038>\n<05> <0039>\nendbfchar\n"
        b"1 beginbfrange\n<10> <12> <0041>\nendbfrange\nendcmap\n"
    )
    fonts = (
        b"4 0 obj\n<</Type /Font /Subtype /Type3 /ToUnicode 5 0 R>>\nendobj\n"
        b"5 0 obj\n<</Length " + str(len(cmap)).encode() + b">>stream\n" + cmap + b"\nendstream\nendobj\n"
    )
    glyphs = text_of(
        b"BT /F4 11 Tf [<0304> -20 <0503>] TJ (x) Tj <101112> Tj ET",
        extra=b" /Resources <</Font <</F4 4 0 R>>>>",
        objects=fonts,
    )
    check("glyph codes decode via ToUnicode bfchar", glyphs, "0890")
    check("bfrange decodes", glyphs, "ABC")

    print("---")
    print("selftest PASS" if not fails else f"selftest FAIL ({fails})")
    return 0 if not fails else 1


if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "--selftest":
        sys.exit(_selftest())
    if not arg:
        print("usage: pdf-text.py FILE | --selftest", file=sys.stderr)
        sys.exit(64)
    with open(arg, "rb") as fh:
        raw = fh.read()
    try:
        out = extract(raw)
    except ValueError:
        print(f"not a PDF: {arg}", file=sys.stderr)
        sys.exit(3)
    sys.stdout.write(out.decode("utf-8", "replace"))
