# Localization — English + Thai (display-only)

An optional bilingual view: a floating **🌐 EN／ไทย** chip lets a reader switch the
visible page between **English (default)** and **Thai**. It's opt-in — plain docs stay
English-only with no chip.

**The one rule that shapes everything: Thai is display-only. English is canonical.**
Every export **island stays English**, and the engine forces English while any export
runs, so the exported **Markdown/JSON is always English** — Thai never reaches the file
an AI reads. You get a third audience (a Thai reader) without touching the AI's copy.

## Turn it on
1. Add `data-i18n="en,th"` to the page root: `<main data-doc data-i18n="en,th" …>`.
2. Inline `assets/i18n.js` at the bottom, **after** `export-engine.js` (it wraps
   `window.WID` to keep exports English). It self-injects its CSS and the chip.
3. Translate the readable text (below).
4. For best Thai glyphs, add `&family=Noto+Sans+Thai:wght@400;500;600;700` to the font
   `<link>` — the `--font-thai` token already prefers it, falling back to a system face.

## Translate: `data-th` on leaf elements
Give each **leaf readable element** a `data-th="<thai text>"`. The English content stays
the element's normal text (and the export source); the engine swaps to Thai on toggle.
```html
<h2 data-th="ภาพรวม">Overview</h2>
<p data-th="การบันทึกเกิดขึ้นทันที คุณไม่ต้องรอเซิร์ฟเวอร์">Saving is instant — you never wait for the server.</p>
```
**Scope — what to translate:** headings, prose, list items, figure captions, table
cells (`th`/`td`), callout title + text, KPI labels (`.kpi .l`), tab button labels, and
comparison card headings/pros/cons. **Leave English** (both views): code blocks,
diagram/chart **source** and their node/axis labels (they're the export source and
technical), and any numeric KPI values.

**Three constraints, or the swap misbehaves:**
- **Leaf elements only.** Never put `data-th` on a container, on an element that holds a
  `<script class="export-data">` island, or on injected UI (decision controls, the
  toolbar) — the swap replaces the element's content.
- **Inline markup:** the English side keeps its `<strong>`/`<code>` (restored from a
  snapshot); the Thai side is plain text. For emphasis in Thai, split into child spans
  each carrying its own `data-th`.
- **No `data-th` = stays English** in the Thai view. Partial translation degrades
  gracefully — translate what matters, skip the rest.

## What the reader/agent gets
- **Reader:** a chip bottom-left; English by default, one click to Thai and back. The
  choice is per-view only (not persisted).
- **AI / downstream:** unchanged — every `↓ MD` / `↓ JSON` / per-section export, and a
  plan's **Approve** download, serialize the English islands and English DOM even if
  Thai is on screen at the click.

## Limits (say them if they bite)
- Free-text a human types into a **decision note** is verbatim — if they write Thai, it
  lands in the plan as Thai. For strict English-only output, ask reviewers to note in
  English. Everything the *doc* authored stays English in the export regardless.
- Only `en` + `th`. More languages would need a different mechanism.

## Verify
The verifier gates a localized doc: chip/engine initialises, default is English, a
switch to Thai actually renders Thai, and — the contract — **an export taken while Thai
is displayed contains zero Thai characters**. See SKILL.md → Verify.
