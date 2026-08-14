---
name: diagram-ticket
description: Render a Mermaid diagram (flowchart, sequence, ER, state, class, gantt, gitGraph, quadrant, mindmap, journey) and embed it INSIDE a ticket's description body as an image (plus a mermaid.live edit link) — not merely attached to the Attachments panel, where a reader of the ticket never sees it. Use when clarifying a ticket's flow/relationship/lifecycle would benefit from a picture instead of more prose, or when a user asks to diagram, visualize, draw, or virtualize a flow/sequence/ER/state diagram for a ticket. Gated by workspace.config.yaml diagrams.enabled (default OFF) — reports skipped, not an error, when off.
argument-hint: "<KEY> [diagram-type] — or pass raw Mermaid source directly"
allowed-tools:
  - Bash(scripts/diagram/*)
  - Bash(scripts/tracker/*)
  - Read
---

# Diagramming a ticket

## Output language — this is structural, not prose

Diagram node labels and edge text are technical/domain terms — they stay in **English**
regardless of the workspace's resolved output language (same rule that already keeps
code, identifiers, and field labels English under `language: th`; see
`docs/agents/language.md`). Don't re-resolve the language here — whatever directive is
already active in your prompt governs the sentence you write **around** the diagram
(the reference line in the ticket body); it never governs the diagram's own text.

## Gate — check before doing anything else

Read `diagrams.enabled` from `workspace.config.local.yaml` (personal override) if it
has a `diagrams:` block, else `workspace.config.yaml` (same precedence as every other
workspace switch). **`false` (the default): stop here** and return
`skipped: diagrams disabled (workspace.config.yaml diagrams.enabled=false)` — this is
not a failure, a diagram is an enhancement to a ticket's spec, not a required
deliverable. Only continue past this point when it's `true`.

## Flow

1. **Decide it earns its place, and pick the type.** A diagram is worth attaching only
   when it shows a flow, relationship, lifecycle, or structure that the ticket's prose
   can't say as cleanly — not every ticket needs one. Match the diagram **type** to the
   *shape* of the content using the existing catalogue in
   `.claude/skills/write-interactive-docs/references/diagrams.md` ("Choose by the shape
   of the idea" table + the Mermaid recipes right below it) — reuse it as-is, don't
   re-derive the type mapping here. Keep it to **≤ 12 nodes**; split a dense idea into
   two focused diagrams rather than cramming one.
2. **Write the Mermaid source**, respecting two ticket-specific gotchas the HTML-doc
   catalogue doesn't need to worry about:
   - Quote any node label containing `&`, `/`, `(`, or `:` (e.g. `BRD["/brd"]`, not
     `BRD[/brd]`) — the same Mermaid-parsing pitfall documented in `diagrams.md`'s
     "Don't let it break" section applies here too.
   - When the diagram's fenced ` ```mermaid ` block is embedded in the ticket body,
     keep the fence **top-level** — never nested inside a bullet/numbered list item.
     A fence nested under a list item silently flattens to plain text and can eat
     `snake_case` underscores (see the ADF-rendering gotcha this bit you on APP-1952-
     style tickets before). Put the fence on its own paragraph, above or below the list
     it relates to, never inside it.
3. **Render the image**:
   ```sh
   printf '%s' "<mermaid source>" | "$CLAUDE_PROJECT_DIR"/scripts/diagram/render.sh - /tmp/<slug>.png --theme "<diagrams.theme, default 'default'>"
   ```
   `render.sh` always runs when invoked (the gate check in step 0 is what you already
   did) — a non-zero exit means invalid Mermaid syntax or a network error, not a
   disabled feature; fix the source or report the failure, don't retry blindly.
   The background is **opaque** (`--bg`, default `FFFFFF`) and should stay that way: a
   transparent PNG takes the colour of whatever the viewer puts behind it, and Jira's
   full-screen media viewer is near-black, which makes the diagram's own dark text and
   edges unreadable — it reads fine in the body and turns to mush the moment a human
   clicks it to look closer.
4. **Get the edit link** (no network call — pure local encode):
   ```sh
   printf '%s' "<mermaid source>" | "$CLAUDE_PROJECT_DIR"/scripts/diagram/live-link.sh -
   ```
5. **Attach the rendered file and take back its embed handle.** A classic REST
   attachment id is *not* embeddable — Jira's ADF `media` node needs a **Media Services
   UUID**, a disjoint id space. `--embed-id` resolves it for you and prints only that
   uuid:
   ```sh
   uuid=$("$CLAUDE_PROJECT_DIR"/scripts/tracker/add-ticket-attachment.sh <KEY> /tmp/<slug>.png --embed-id)
   ```
   Already attached by an earlier step? `get-ticket-attachments.sh <KEY>` prints each
   image's ready-to-paste embed token — no re-upload needed.
   **Notion: skip the uuid** (`add-ticket-attachment.sh <KEY> <file>`, no flag). Its
   adapter has no attachment-embed API yet, so the live-link line is your only in-body
   content and `in_body: false`.
6. **Put the image IN the description body, not just the Attachments panel** (Jira). The
   image token goes into the Markdown body the ticket is written with — the adapter
   renders a token that is **alone on its line** as a block-level `mediaSingle`; one
   sharing a line with prose stays literal text, because ADF has nowhere to put a media
   node inside a paragraph. So write, on its own line under the section the diagram
   illustrates (typically after `Scope:`/`Reproduce steps:`, before `Acceptance
   criteria:`):
   ```md
   ![<slug>.png](attachment:<uuid from step 5>)
   [View / edit this diagram](https://mermaid.live/edit#pako:<link from step 4>)
   ```
   Then write the body once, whole, with `upsert-ticket-details.sh <KEY> --body-file
   <path>` — Jira's description field only ever takes a full replacement. Two rules that
   protect what is already on the ticket:
   - **Never hand-write a body you have not read first.** Dump the current one
     (`get-ticket-details.sh <KEY>`), insert your two lines into *that* text, and write
     it back — anything you omit is gone, there is no partial update and no undo.
   - Images a human pasted into the description are carried over automatically by
     `upsert-ticket-details.sh` (`adf_append_media`, the APP-1952 fix), so a rewrite
     cannot silently drop them — but they land in an "Attachments (carried over)"
     section at the end, not where they were.
   - **Replacing** a diagram you rendered earlier (re-rendered, fixed labels) needs
     `--no-carry-media` on that write, or the superseded image is re-appended under that
     same divider — and writing the body again will not clear it, because the carry-over
     reads the description it just wrote. The stale ATTACHMENT still sits in the panel
     after that; leave it, or ask the ticket's owner before deleting (a delete is
     irreversible and any other comment embedding it would be left pointing at nothing).
   **Don't add a `codeBlock` with the raw Mermaid source** — the live-editor link already
   carries the full source (verified in step 7), so a second copy is pure noise. Don't
   post the link as a comment either: it is already in-body on the reference line.
7. **Verify — the image renders in-body, and the link actually opens.** Confirm all of:
   - `get-ticket-details.sh <KEY>` prints its `⚠ N embedded image/attachment(s) in the
     description` line and the body still contains every section it had before your
     write (diff it against the dump from step 6);
   - `get-ticket-attachments.sh <KEY>` lists the rendered file;
   - the link **as it now reads on the ticket** decodes to the full source — read the
     description back and check that copy, never the string you generated:
     ```sh
     "$CLAUDE_PROJECT_DIR"/scripts/diagram/live-link.sh --check "<link from the ticket>"
     ```
     It prints `ok: <n> chars of Mermaid source, theme <t>, starts "..."`, and exits
     non-zero with the reason otherwise. Checking the generated string proves nothing —
     the encoder is already covered by `scripts/diagram/selftest.sh`; what breaks is the
     trip onto the ticket. **One** altered base64 character kills the whole zlib stream,
     and mermaid.live answers a corrupt fragment by quietly loading its own "Loading URL
     failed" sample diagram — which looks like a rendered diagram to anyone who clicks.
     That is a shipped failure: it happened on APP-2315, where the fragment on the ticket
     differed from the encoder's output in exactly one character. Never retype or
     reflow a fragment; interpolate it whole.
   None of this is optional — a diagram that is merely attached (never embedded in the
   description) or a link that renders blank both look identical to success until you
   check. An attachment-only diagram is the failure this flow exists to prevent: nobody
   reading the ticket sees it.

## Budget

At most `diagrams.max_per_ticket` (workspace default: 2) diagrams per ticket per run.
If the content plainly calls for more, attach the highest-value ones and note in your
report which were skipped and why — never attach past the cap silently.

## Output

Return a compact result the caller (typically `/clarifying-ticket`, step 5 — Compose
the spec) folds into the ticket:

```
diagram_type:   flowchart | sequence | state | er | class | gantt | gitGraph | quadrant | mindmap | journey
attached:       true | false
in_body:        true | false        # false on Notion (no embed API) — attachment + fallback block only
file:           <slug>.png          # omitted if attached: false
media_uuid:     <UUID>              # Jira only, omitted when in_body: false
live_editor_url:<mermaid.live link>
skipped:        <reason>            # only when gated off, or genuinely no diagram warranted
```
