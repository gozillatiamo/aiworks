---
name: write-interactive-docs
description: >-
  Write a self-contained, interactive HTML document that explains something to a
  human in plain language — using diagrams, tables, tabs, charts, callouts and
  comparison sections instead of a wall of text — themed to match the project it
  came from, with one-click export of the whole page or any single section to
  Markdown or JSON for feeding to an AI. Use this whenever the user wants to
  DOCUMENT, EXPLAIN, WRITE UP, or VISUALIZE something for people to read:
  architecture/system/codebase explainers, design docs, ADRs, RFCs, "how does X
  work" write-ups, solution proposals, option/trade-off comparisons, onboarding
  guides, runbooks, research summaries, or turning a PRD/README/markdown into a
  rich readable page. Trigger it for phrasings like "make a doc/page", "write
  this up", "explain this visually", "create an interactive explainer", "turn
  this into HTML docs", "document this so the team gets it", or a shareable
  single-file HTML explainer — even if they don't say "interactive". ALSO use it
  to UPDATE or MODIFY an existing interactive doc — partial edits like "tweak this
  section", "restyle it", "fix that diagram", "make the diagram interactive", or
  "add a section" — editing just the requested part instead of rebuilding. Prefer
  this over a plain Markdown reply whenever the user wants something polished,
  visual, or shareable.
model: sonnet[1m]
effort: low 
---

# Write Interactive Docs

Produce **one self-contained `.html` file** that explains something clearly: plain
words, the right visual per idea, a look that matches the project, and one-click
export of the whole page or any section to Markdown/JSON for an AI. Two modes —
**build** a new doc, or **update** an existing one (edit only what's asked, never
rebuild). Pick the mode from the request before doing anything.

## The bar
- **Plain language** — short sentences, common words; explain a term on first use.
- **Show, don't tell** — lead each idea with the best visual (diagram / chart / table
  / tabs / callout), then prose; never a wall of text.
- **Interactive diagrams** — inlining `diagram-interactions.js` gives every diagram
  zoom/pan + hover-spotlight; declare clickable nodes (jump to a section / open a
  detail drawer / link) and an optional guided walkthrough where exploring helps.
- **Themed, never plain** — wear the project's colours/font/vibe; black-on-white is a failure.
- **Decision-ready** — when options are weighed, end with a comparison that makes the call obvious.
- **AI-friendly exports** — every section + the whole page → clean MD/JSON, download or copy.

## Mode A — build a new doc
1. **Understand** the input (a codebase → explore via codegraph / read it first; a
   topic; an existing markdown/PRD/README; or this conversation). Fix the **audience**
   and the one thing the reader should leave knowing — everything serves that.
2. **Outline** the sections and pick the *shape* of each idea (don't default to
   paragraphs). → **references/components.md** (blocks + the export contract),
   **references/diagrams.md** (which diagram fits + how to make it interactive).
3. **Theme** from the project's design tokens / brand; if none exist, generate a
   palette fitting the content's domain + mood. → **references/theming.md**.
4. **Assemble** from **assets/template.html**; inline both engines into their marked
   `<script>` slots (`export-engine.js`, `diagram-interactions.js`) so it stays one
   file. For each rich block, write its `export-data` **island first**, then build the
   visual from the same data — the export is reconstructed from the island, so they
   must stay in sync.
5. **Conditionals:** add a **comparison** section when the doc weighs options (mark the
   Recommended), and an **Implementation Plan** as the last section when something is
   to be built (ordered steps with real file targets + acceptance criteria). Both are
   specified in **references/components.md**.
6. **Verify, then hand over** — see below.

## Mode B — update an existing doc
When the user asks to change a doc that already exists — tweak a section, fix wording,
restyle, swap/fix a diagram, make one diagram interactive, add or drop a section —
**edit that file in place; do not regenerate it.** Rebuilding discards their tweaks,
reshuffles content, and risks breaking what already worked. Make the **smallest change
that satisfies the request**, leave everything else (theme tokens, other sections, the
inlined engines) untouched, keep each changed block's visual and its `export-data`
island in sync, then verify. The step-by-step playbook — locating sections, editing a
block + island together, adding/removing a section, re-theming, adding interactivity to
one diagram, refreshing an engine — is in **references/editing.md**. Read it first.

## Verify & hand over
**Run the verifier — it's the authoritative check.** A doc can look right in source yet
be broken at runtime: a diagram's Mermaid is subtly invalid, the exported `source`
drifted from the visible diagram, or a clickable node's key doesn't match the real SVG
node so clicks/walkthrough do nothing. The verifier renders every diagram with real
Mermaid and exercises the engine — and, when Chrome/Chromium + puppeteer-core are present,
drives a REAL mouse click in a headless browser to confirm clicks actually fire. That last
gate is the only thing that catches load-order/timing bugs AND real-click failures (e.g.
pointer-capture swallowing the click) that synthetic events and the source can't reveal:
```
npm i --no-save mermaid jsdom puppeteer-core   # once; Chrome auto-detected (set CHROME_PATH if needed)
node <skill>/scripts/verify-doc.mjs path/to/doc.html   # fix flags, re-run to ALL PASS
```
(If node/npm isn't available, say the verifier was skipped and eyeball instead.) Then
sanity-check: plain language; right visual per idea; theme not black-and-white;
comparison present iff options are weighed; Implementation Plan present iff something's
to be built; exports work (click "↓ JSON" → a structured tree); single file,
responsive, readable contrast. Save as `<topic>.html` (kebab-case — alongside the
source repo's `docs/` when documenting code, else where the user asked). Tell the user
the path and the export buttons (page toolbar top-right; per-section on hover).

## Bundled resources
- **assets/template.html** — scaffold to copy; documents the DOM contract.
- **assets/export-engine.js** — inline it; reusable MD/JSON export (page + per-section). Don't reinvent.
- **assets/diagram-interactions.js** — inline it; zoom/pan + hover + clickable nodes + walkthrough; self-injects its CSS. Don't reinvent.
- **scripts/verify-doc.mjs** — authoritative runtime check (real Mermaid + the engine, plus a real-mouse-click gate in headless Chrome via puppeteer-core when available). Run before handing over.
- **references/components.md** — every block, its HTML + export island; comparison + Implementation Plan rules.
- **references/diagrams.md** — pick the diagram kind; Mermaid recipes; make it interactive; the two gotchas.
- **references/theming.md** — detect or generate the project's palette.
- **references/editing.md** — the partial-update playbook (Mode B).

## Guardrails
- **Single file, CDN allowed.** Mermaid/Chart.js load from a CDN (needs internet to
  render); the file itself is one shareable `.html`. For full offline, inline static
  SVG/table fallbacks and say so.
- **Accuracy first.** When documenting code, verify against the real source — a pretty
  doc that's wrong is worse than plain notes.
- **Restraint.** Components and colour must carry meaning; a plain paragraph is right
  when it's the clearest way to say something.
