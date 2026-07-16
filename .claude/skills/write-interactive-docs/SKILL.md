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
model: sonnet
effort: low 
---

# Write Interactive Docs

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write the plan / document prose you author — whether Markdown in agent_logs/ or the HTML page body in **Thai prose with an English spine** — titles + every section heading + labels/enum values, ALL code + identifiers + commit messages + branch names, and technical / transliterated / domain terms + proper nouns stay English (Arabic numerals always); the sentences themselves are Thai. **Code and checked-in repo docs** (`docs/`, `README`, ADRs, committed PRD/BRD files) are **never** Thai. Default **`en`** = unchanged; this block is a no-op. (This governs the page's AUTHORED prose. The optional EN／ไทย display toggle and English-only export in `references/localization.md` are a separate, orthogonal feature — do not conflate them.) Full policy: `docs/agents/language.md`.

Produce **one self-contained `.html` file** that explains something clearly: plain
words, the right visual per idea, a look that matches the project, and one-click
export of the whole page or any section to Markdown/JSON for an AI. Two modes —
**build** a new doc, or **update** an existing one (edit only what's asked, never
rebuild). Pick the mode from the request before doing anything.

## The bar
- **Plain language** — short sentences, common words a non-technical reader gets;
  explain a term on first use.
- **Two readers** — the visible page is for a **person** (plain, concise); each export
  island is for an **AI** (the full, exact version). Same facts, different voice — they
  need not read word-for-word alike. (Diagrams/charts are the exception: the visual is
  rendered *from* the island, so there they're identical.)
- **Show, don't tell** — lead each idea with the best visual (diagram / chart / table
  / tabs / callout), then prose; never a wall of text.
- **Interactive diagrams** — inlining `diagram-interactions.js` gives every diagram
  zoom/pan + hover-spotlight; declare clickable nodes (jump to a section / open a
  detail drawer / link) and an optional guided walkthrough where exploring helps.
- **Themed, never plain** — wear the project's colours/font/vibe; black-on-white is a failure.
- **Decision-ready** — when options are weighed, end with a comparison that makes the
  call obvious; in a plan awaiting approval, offer the choice as a **pick-one (radio)**
  or **pick-many (checkbox)** control whose result is written into the approved plan.
- **See UI before deciding** — for a UI/design choice, show a rendered **preview** the
  human can look at, with a **comments** box to note adjustments (both feed the plan).
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
   visual from it — the export is reconstructed from the island. Diagrams/charts are
   *rendered from* the island, so the two must match exactly; for every other block the
   visible copy stays plain for the reader while the island carries the fuller AI
   version (same facts — see **references/components.md → the export contract**).
5. **Conditionals:** add a **comparison** section when the doc weighs options (mark the
   Recommended), a **UI preview** when a choice is about UI/design (show it, don't
   describe it), and an **Implementation Plan** as the last section when something is
   to be built (ordered steps with real file targets + acceptance criteria). All are
   specified in **references/components.md**. If the doc IS a plan (it has an
   Implementation Plan), also follow **"Plans vs. documents"** below — it changes what
   you must emit and whether the human approves in-page. If the doc must be **bilingual**
   (English default + a Thai display toggle), add the language layer → **references/
   localization.md** (exports stay English-only).
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

## Plans vs. documents (the markdown contract & in-page approval)

Most docs are **explainers** — the HTML is the deliverable; you're done when it's
verified. But when the doc is a **plan** — it ends in an Implementation Plan because
something will be built from it — the HTML is *not* the thing that gets executed. A
later phase (e.g. the dev-cycle re-run with `--approve-plan`) reads a **markdown**
file, never the page. Treat that markdown as the real artifact and the HTML as the
human's reading-and-deciding surface over it. This is the **two readers** split at its
sharpest: the **page** explains the plan to a person in plain language, while the
**markdown** is the executing agent's brief and must be the *intensive, unambiguous,
step-by-step implementation plan* — exact file/component targets, the change per step,
acceptance criteria, and ordering/risks — so the agent is never left guessing *how* to
build it. The markdown is rebuilt from the plan's `steps` island, so write that island
to this bar (the visible plan may summarize; the island may not). Two rules and one
mode follow.

**1 — A plan ALWAYS has a markdown twin, even when `to_html` is on.** `to_html` adds
the HTML; it never *replaces* the markdown. So whenever you produce a plan as HTML,
make sure the plan markdown exists too: in the dev-cycle the planner already wrote it
(at `plan_path`) before you render; for a standalone plan, write the plan markdown
yourself next to the `.html` (same basename, `.md`) before handing over. The HTML's
export buttons reconstruct the same markdown, but a later phase shouldn't have to open
a browser to get it — the file must be on disk.

**2 — Downstream reads the markdown, not the HTML.** Keep the two consistent — the page
may read plainer, but the markdown must stay the full, intensive step-by-step plan —
and never point a build/approve step at the `.html`. The HTML is human-only. Make this
concrete by setting `data-plan-md` (below) to the exact markdown path the next phase
reads, so the in-page Approve writes back to that same file.

**The mode — in-page approval when `planning.auto_approve` is false.** When a human
must sign off before the plan is built, turn the plan doc into an approval surface so
their decisions reach the markdown (otherwise edits made in the HTML are silently lost
at build time). Set three attributes on the page root and inline
`assets/plan-approval.js` after `export-engine.js`:
```html
<main data-doc data-doc-title="…"
      data-plan-approval="pending"
      data-plan-md="agent_logs/development-planner/FM-12-app-plan.md"   <!-- the markdown the next phase reads -->
      data-plan-cmd="/dev-cycle FM-12 --approve-plan">                  <!-- the command to re-run, shown to the human -->
```
With that, the engine (no extra authoring): gives every section a **Decision** control
(accept / pick an option — pick-one radios or pick-many checkboxes / write a
modification — options auto-derived from a comparison in the section, or a
`decision-data` island you author; a section with a UI **preview** gets a **comments**
box instead), writes each change **live** into the Implementation Plan
(its `decisions` island + a visible "Human decisions" block — yes, real-time, it's all
one page), and adds an **✅ Approve & download plan** button to the plan section. On
approve it serializes the current plan (decisions included) to markdown and downloads
it under the `data-plan-md` basename, then tells the human to **replace `data-plan-md`
with the download and re-run `data-plan-cmd`** (a browser can't overwrite a file on
disk, so this hand-off is one explicit step). Full schema → **references/components.md
→ "Plan-approval mode"**.

When `auto_approve` is **on** (or the doc is a plain explainer), omit the three
attributes and don't inline the engine — the plan renders read-only.

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
responsive, readable contrast. **If it's a plan:** the markdown twin exists on disk
(see "Plans vs. documents"); and in approval mode (`data-plan-approval` set) the page
shows per-section Decision controls + an Approve button, `data-plan-md` points at that
markdown, and `plan-approval.js` is inlined — the verifier checks this wiring. **If it's
bilingual** (`data-i18n` set): the 🌐 chip appears, English is the default, switching to
Thai renders Thai, and an export taken while Thai is displayed contains **zero Thai** —
the verifier checks this contract. Save as `<topic>.html` (kebab-case — alongside the
source repo's `docs/` when documenting code, else where the user asked). Tell the user
the path and the export buttons (page toolbar top-right; per-section on hover) — and, for
a plan in approval mode, that approving downloads the markdown to drop over
`data-plan-md`.

## Bundled resources
- **assets/template.html** — scaffold to copy; documents the DOM contract.
- **assets/export-engine.js** — inline it; reusable MD/JSON export (page + per-section). Don't reinvent.
- **assets/diagram-interactions.js** — inline it; zoom/pan + hover + clickable nodes + walkthrough; self-injects its CSS. Don't reinvent.
- **assets/plan-approval.js** — inline it (after export-engine.js) **only for a plan awaiting approval**; adds per-section Decision controls, a live "Human decisions" mirror, and the Approve→markdown download. Self-injects its CSS; inert unless `data-plan-approval` is set. Don't reinvent.
- **assets/i18n.js** — inline it (after export-engine.js) **only for a bilingual doc**; adds the floating 🌐 EN／ไทย chip and swaps the visible page to Thai while keeping every export English. Self-injects its CSS; inert unless `data-i18n` is set. Don't reinvent.
- **scripts/verify-doc.mjs** — authoritative runtime check (real Mermaid + the engine, plus a real-mouse-click gate in headless Chrome via puppeteer-core when available). Run before handing over.
- **references/components.md** — every block, its HTML + export island; comparison + Implementation Plan rules.
- **references/diagrams.md** — pick the diagram kind; Mermaid recipes; make it interactive; the two gotchas.
- **references/theming.md** — detect or generate the project's palette.
- **references/editing.md** — the partial-update playbook (Mode B).
- **references/localization.md** — the English+Thai display toggle (opt-in; exports stay English).

## Guardrails
- **Single file, CDN allowed.** Mermaid/Chart.js load from a CDN (needs internet to
  render); the file itself is one shareable `.html`. For full offline, inline static
  SVG/table fallbacks and say so.
- **Accuracy first.** When documenting code, verify against the real source — a pretty
  doc that's wrong is worse than plain notes.
- **Restraint.** Components and colour must carry meaning; a plain paragraph is right
  when it's the clearest way to say something.
