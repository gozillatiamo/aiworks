---
name: diagram-ticket
description: Render a Mermaid diagram (flowchart, sequence, ER, state, class, gantt, gitGraph, quadrant, mindmap, journey) and attach it to a ticket as a PNG image plus a mermaid.live edit link. Use when clarifying a ticket's flow/relationship/lifecycle would benefit from a picture instead of more prose, or when a user asks to diagram, visualize, draw, or virtualize a flow/sequence/ER/state diagram for a ticket. Gated by workspace.config.yaml diagrams.enabled (default OFF) — reports skipped, not an error, when off.
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
     `snake_case` underscores (see the ADF-rendering gotcha this bit you on OFB-1952-
     style tickets before). Put the fence on its own paragraph, above or below the list
     it relates to, never inside it.
3. **Render the image**:
   ```sh
   printf '%s' "<mermaid source>" | "$CLAUDE_PROJECT_DIR"/scripts/diagram/render.sh - /tmp/<slug>.png --theme "<diagrams.theme, default 'default'>"
   ```
   `render.sh` always runs when invoked (the gate check in step 0 is what you already
   did) — a non-zero exit means invalid Mermaid syntax or a network error, not a
   disabled feature; fix the source or report the failure, don't retry blindly.
4. **Get the edit link** (no network call — pure local encode):
   ```sh
   printf '%s' "<mermaid source>" | "$CLAUDE_PROJECT_DIR"/scripts/diagram/live-link.sh -
   ```
5. **Attach the rendered file** (both providers, always do this — it's the source
   attachment the in-body image references, and on Notion it's the only embed you get):
   ```sh
   "$CLAUDE_PROJECT_DIR"/scripts/tracker/add-ticket-attachment.sh <KEY> /tmp/<slug>.png
   ```
   Note the numeric attachment id the adapter returns — step 6 needs it (Jira only).
   **Notion: stop here for the image.** Its adapter has no attachment-embed API yet —
   skip to the fenced-source + live-link fallback in step 7 as your only in-body content.
6. **Get the true in-body embed, Jira only.** A classic REST attachment id is *not*
   embeddable — Jira's ADF `media` node needs a **Media Services UUID**, a disjoint id
   space with no documented bridge field. The bridge: request the attachment's content
   endpoint and read the redirect it returns.
   ```sh
   jira_api GET "/rest/api/3/attachment/content/<attachmentId>"
   ```
   Don't follow the redirect — read its `Location:` header:
   `https://api.media.atlassian.com/file/<UUID>/binary?token=...` — the segment between
   `/file/` and `/binary` is the Media Services UUID.
7. **Splice the diagram into the raw ADF — never through the Markdown converter.**
   `md_to_adf` is the same lossy render path that eats `snake_case` underscores in plain
   text (the OFB-1952 gotcha in step 2); round-tripping a real description through it
   risks corrupting unrelated content. Instead:
   1. Fetch the current description as ADF: `jira_api GET
      "/rest/api/3/issue/<KEY>?fields=description"` → this is your last-known-good
      backup — keep it until step 8 passes.
   2. Build three ADF nodes: a `paragraph` with a `link` mark
      (`href: https://mermaid.live/edit#pako:<link from step 4>`) referencing the
      diagram, a `mediaSingle` > `media` node (`type: "file"`, `id: <UUID from step 6>`,
      `collection: ""`), and a `codeBlock` holding the raw Mermaid source.
   3. Splice those three nodes into the fetched `content` array right after the section
      the diagram illustrates (typically `Scope:` or `Reproduce steps:`) and before
      `Acceptance criteria:` — via `jq`, not by hand-editing JSON text.
   4. PUT the whole modified document back: `jira_api PUT "/rest/api/3/issue/<KEY>"`
      with body `{"fields":{"description": <spliced ADF doc>}}`. This call **replaces
      the entire description field** — there is no partial-update or simple undo via
      the API. Never construct the payload through a nested nested-quoting shell
      one-liner; write it to a temp file and pass `--argjson` from the file, so you can
      inspect the exact bytes before the PUT fires. If any pre-flight check of that
      payload shows a null/empty description, **stop — do not run the PUT** — a red
      diagnostic here means the payload is wrong, not that the check is; fix the
      construction before writing to a live ticket.
8. **Verify — both the structure and that the link actually opens.** Re-`GET` the
   description and confirm all of:
   - the node-type sequence includes your `mediaSingle` and `codeBlock` at the intended
     position, with the rest of the original content byte-identical to the step-7.1
     backup;
   - `get-ticket-attachments.sh <KEY>` lists the rendered file;
   - the posted mermaid.live link decodes locally to a non-blank diagram: base64url-
     decode + zlib-inflate the `#pako:` fragment, `json.loads` the result, then
     `json.loads(state["mermaid"])` must also parse (it's a JSON **string**, not a
     nested object — `mermaid-live-editor` calls `JSON.parse` on it directly and
     renders blank on a type mismatch) and `state["code"]` must be the full Mermaid
     source, not empty.
   None of this is optional — a diagram that's merely attached (not spliced into the
   description) or a link that renders blank both look identical to success until you
   check.

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
