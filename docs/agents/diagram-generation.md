# Diagram generation (ticket-clarification visuals)

The single reference for how the **`/diagram-ticket`** skill turns a Mermaid diagram
into something attached to a ticket — a rendered image, plus a link a human can open
and edit — and how to turn the capability on in a freshly `aiworks sync`'d workspace.
Mirrors `docs/agents/image-generation.md`'s shape (config block, backend, setup).

## Config: the `diagrams:` block (default OFF)

```yaml
diagrams:
  enabled: false          # MASTER switch (default OFF). false -> /diagram-ticket generates nothing.
  provider: mermaid-ink   # renders via the public mermaid.ink/mermaid.live services
  theme: default          # default | dark | forest | neutral
  max_per_ticket: 2       # budget cap: most diagrams /diagram-ticket attaches per ticket
```

- **`enabled: false` (default)** — `/diagram-ticket` does nothing and reports
  `skipped: diagrams disabled` back to its caller (`clarifying-ticket`, or whichever
  agent invoked it directly). The ticket still gets its clarified text spec; it just
  has no visual. Turn on with `enabled: true`.
- **`provider`** picks the adapter backend (`DIAGRAM_PROVIDER` — see
  `scripts/diagram/README.md`). Only `mermaid-ink` exists today.
- **`max_per_ticket`** is `/diagram-ticket`'s own budget cap, mirroring
  `image_generation.max_per_request` — most tickets need at most one diagram; a ticket
  with genuinely distinct flows (e.g. a happy-path sequence AND a state lifecycle) may
  warrant two.

There is no per-machine setup step and no secret to provision — the default provider is
a public, unauthenticated service (see below), so `enabled: true` is the only change
needed.

## Why this is gated at all

Unlike syntax-highlighted code in a PR, a diagram's node labels are free text an agent
writes — and rendering it via `mermaid-ink` sends that text over HTTPS to a third-party
service to get the image back. That's diagram **structure** (flow/entity/state names),
never ticket credentials or file attachments, but it's still workspace content leaving
the network, which several repos' `guardian_focus: secrets, data-protection` settings
in `workspace.config.yaml` flag as something to treat deliberately rather than
by default. Hence the same opt-in-off pattern as `design.enabled` /
`image_generation.enabled`.

**Do not put secrets, tokens, connection strings, or real customer/PII data in a
diagram node label.** A diagram illustrates structure (`Player --> AuthService`), not
literal payloads.

## The backend: mermaid.ink / mermaid.live

- **`scripts/diagram/render.sh`** — base64-encodes the raw Mermaid text and calls
  `https://mermaid.ink/img/<b64>?type=png` (or `/svg/<b64>` for vector output),
  saving the response to a local file. No install, no API key.
- **`scripts/diagram/live-link.sh`** — deflate-compresses (pako-compatible) + base64
  encodes the same text entirely **locally** and prints a `https://mermaid.live/edit#pako:…`
  link. This step makes **no network call at all**; the text only reaches
  `mermaid.live` if a human later opens that link in a browser.
- Full adapter contract: `scripts/diagram/README.md`.

## Which diagram type to pick

`/diagram-ticket` reuses the existing catalogue in
`../../.claude/skills/write-interactive-docs/references/diagrams.md` ("Choose by the
shape of the idea" table + recipes) rather than re-deriving it — same Mermaid syntax,
same shape-to-type mapping, whether the diagram ends up in an HTML doc or a ticket.

## Attaching to a ticket

The rendered image is uploaded via the existing tracker adapter
(`scripts/tracker/add-ticket-attachment.sh <KEY> <file>` — see
`docs/agents/issue-tracker.md`), never a new upload path. Jira is the only tracker
provider that adapter supports today; Notion attachment upload is not yet
implemented there, so on a Notion-backed workspace `/diagram-ticket` falls back to the
live-editor link + a raw fenced ` ```mermaid ` block only (no image).
