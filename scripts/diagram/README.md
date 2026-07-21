# Diagram adapter

Provider-agnostic shell scripts that turn Mermaid diagram source into something a
ticket can carry: a rendered image, or a browser link a human can open and edit.
`lib.sh` dispatches to a provider implementation chosen by `DIAGRAM_PROVIDER`
(`mermaid-ink`, the only one today).

| Script | Does |
|---|---|
| `render.sh <mermaid-file\|-> <out.png\|out.svg> [--theme name]` | Render Mermaid source to a local image file |
| `live-link.sh <mermaid-file\|-> [--theme name]` | Print a `mermaid.live` edit-in-browser URL for the same source |

Both take Mermaid text from a file path or `-` for stdin. Attach the rendered
file to a ticket with `scripts/tracker/add-ticket-attachment.sh`.

**These are low-level primitives — they always run when invoked.** The "should a
diagram be generated at all" decision (`workspace.config.yaml` → `diagrams.enabled`,
default `false`) lives in the calling skill (`/diagram-ticket`), same pattern as
`scripts/notify/send.sh`.

## Backend: mermaid.ink / mermaid.live

Both are public, unauthenticated services — no install, no API key. `render.sh`
sends the diagram's Mermaid **text** (node labels, flow structure — not ticket
credentials or attachments) to `mermaid.ink` over HTTPS to get the image back.
`live-link.sh` never calls the network itself — it only base64/deflate-encodes
the text locally into a URL; the text is sent to `mermaid.live` only if and when
a human opens that link in a browser.

Because diagram text does leave the workspace to a third party, this is gated
behind `diagrams.enabled` — see `docs/agents/diagram-generation.md`. Don't put
secrets, tokens, or real customer data in a node label; a diagram illustrates
structure, not literal payloads.

## Adding a self-hosted provider later

Drop a new `scripts/diagram/<name>/impl.sh` defining `diagram_render` and
`diagram_live_link` (same signatures as `mermaid-ink/impl.sh`), then set
`DIAGRAM_PROVIDER=<name>` in a git-ignored `scripts/diagram/.env`.
