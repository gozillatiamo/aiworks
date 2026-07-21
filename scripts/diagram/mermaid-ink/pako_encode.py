#!/usr/bin/env python3
# Encode Mermaid source as a mermaid.live "pako:" URL fragment.
#
# Run as its own file (not a heredoc piped through `python3 -`) because a heredoc
# replaces the command's stdin entirely — sys.stdin.read() would return '' instead
# of the piped Mermaid text, silently producing a link with an empty diagram.
#
# State schema matches mermaid-live-editor's State type (src/lib/types.d.ts): the
# "mermaid" field must be a JSON STRING, not a nested object — the app calls
# JSON.parse(state.mermaid) directly, so a nested object throws and the editor
# renders blank.
import sys
import json
import zlib
import base64

theme = sys.argv[1]
code = sys.stdin.read()
state = {
    "code": code,
    "mermaid": json.dumps({"theme": theme}),
    "updateDiagram": True,
    "rough": False,
}
payload = json.dumps(state).encode("utf-8")
compressed = zlib.compress(payload, 9)
print(base64.urlsafe_b64encode(compressed).decode("ascii").rstrip("="))
