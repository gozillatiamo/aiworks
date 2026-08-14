#!/usr/bin/env python3
# Decode a mermaid.live "pako:" link and report whether the editor can actually open it.
#
# Exists because a corrupt link is INVISIBLE at a glance: the fragment is 800+ chars of
# base64, and mermaid.live answers a broken one by silently loading its own "Loading URL
# failed" sample diagram — which looks like a rendered diagram, not like an error. One
# altered character is enough (that is exactly how it failed on a real ticket: a single
# base64 char differed from what the encoder printed, the rest byte-identical), and zlib
# then refuses the whole stream.
#
# Run as its own file, like pako_encode.py — a heredoc through `python3 -` would eat the
# stdin the link may arrive on.
#
# Reads a full URL, a bare `pako:...` fragment, or just the base64, from argv or stdin.
# Prints a one-line summary on success; exits 1 with the reason on failure.
import sys
import json
import zlib
import base64

arg = (sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] != "-" else sys.stdin.read()).strip()
frag = arg.split("#pako:")[-1].split("pako:")[-1].strip()
if not frag:
    sys.exit("error: no pako fragment found in the input")


def fail(why):
    sys.exit(f"error: link is corrupt — {why}\n  the editor would silently open its own "
             f"sample diagram instead. Re-generate it with live-link.sh and copy the "
             f"whole fragment ({len(frag)} chars here) without re-typing it.")


try:
    raw = base64.urlsafe_b64decode(frag + "=" * (-len(frag) % 4))
except Exception as e:
    fail(f"not valid URL-safe base64 ({e})")
try:
    payload = zlib.decompress(raw)
except Exception as e:
    fail(f"base64 decoded but zlib inflate failed ({e})")
try:
    state = json.loads(payload)
except Exception as e:
    fail(f"inflated but the state is not JSON ({e})")

code = state.get("code")
if not code:
    fail("state carries no `code` — the diagram would open empty")
cfg = state.get("mermaid")
if not isinstance(cfg, str):
    # The editor calls JSON.parse(state.mermaid) directly, so a nested object throws there.
    fail("`mermaid` is not a JSON string (the editor JSON.parses it and renders blank)")
try:
    theme = json.loads(cfg).get("theme", "?")
except Exception as e:
    fail(f"`mermaid` is a string but not JSON ({e})")

first = code.strip().splitlines()[0][:40] if code.strip() else ""
print(f"ok: {len(code)} chars of Mermaid source, theme {theme}, starts \"{first}\"")
