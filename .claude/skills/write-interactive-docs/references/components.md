# Component library

The doc is built by **composing** these blocks — pick the one that explains each
idea best, never a wall of text. Every component below shows its HTML and, where
it's a *rich* block, the `export-data` island that makes it exportable.

## The export contract (read this once)

Every doc has **two readers**: a **person** reads the visible page, an **AI** reads
the export. They want different things — a person wants plain, short, non-technical
copy; an AI wants the full, exact version. So the visible text and the exported
Markdown **need not be identical**. Write the page for the human; let the export carry
the depth.

The export engine reconstructs Markdown/JSON from the page. Two paths:

1. **Plain HTML** (`p`, `h2`, `ul`, `table`, `pre`, `blockquote`, `hr`, links,
   `strong`/`em`/`code`) is converted **automatically** — here the visible text *is*
   the export. Fine when the plain wording already suits both readers.
2. **Rich blocks** (diagram, chart, comparison, tabs, callout, steps, kpis, preview)
   can't be read from pixels, so each carries a hidden
   `<script type="application/json" class="export-data">…</script>` child whose
   parent has `data-block="<type>"`. That island is the **single source of
   truth** for export. To decouple a plain paragraph too (simple on the page, fuller
   for the AI), give it a `prose` island (see [Prose](#prose)).

**Author the island, then build the visual from it.** For blocks the browser *renders
from* the island — **diagram** and **chart** — the two must match exactly (the verifier
enforces it for diagrams). For every other block the island and the visual carry the
**same facts** but may differ in wording: keep them consistent, not word-identical. A
rich block with no island won't export cleanly.

A section is `<section class="doc-section" data-section data-section-title="…"
data-section-id="…">`. Section id/title power both the on-page export buttons
and the in-document anchors.

---

## Table of contents
- [Prose](#prose) — plain visible copy, optional fuller AI copy
- [Callout](#callout) — info / tip / warning / danger / success
- [KPI row](#kpi-row) — headline numbers
- [Table](#table) — plain auto-exporting tabular data
- [Tabs](#tabs) — platform / variant switches (iOS vs Android, etc.)
- [Comparison](#comparison) — options weighed → a recommendation
- [UI preview](#ui-preview) — a rendered mockup for a design decision
- [Diagram](#diagram) — see also references/diagrams.md
- [Chart](#chart) — quantitative data (Chart.js)
- [Steps / Implementation Plan](#steps--implementation-plan)
- [Plan-approval mode (decisions + approve)](#plan-approval-mode)
- [Accordion / details](#accordion)

---

<a id="prose"></a>
## Prose
Normal paragraphs need nothing — write `<p>…</p>` and they export as-is. Reach for a
prose **island** only when the two readers want different depth: keep the visible
sentence plain and short for a person, and carry the fuller, technical version for the
AI in the island. Same meaning, two voices.
```html
<div data-block="prose">
  <p>Saving is instant — you never wait for the server.</p>
  <script type="application/json" class="export-data">
    {"type":"prose","md":"Writes are enqueued client-side and acknowledged optimistically; the worker persists them asynchronously, so the UI never blocks on the DB round-trip."}
  </script>
</div>
```
The visible `<p>` is what people read; the island `md` is what the Markdown/JSON export
(and any AI reading it) gets.

## Callout
Use for asides: a tip, a gotcha, a danger. Variant sets the colour + icon.
```html
<div class="callout" data-variant="warning" data-block="callout">
  <div class="callout-title">⚠️ Idempotency</div>
  <div>Workers may get the same message twice. Make handlers idempotent.</div>
  <script type="application/json" class="export-data">
    {"type":"callout","variant":"warning","md":"**Idempotency** — Workers may get the same message twice. Make handlers idempotent."}
  </script>
</div>
```
Variants: `info` · `tip` · `warning` · `danger` · `success`.

## KPI row
Headline numbers a reader grasps in one glance.
```html
<div class="kpis" data-block="kpis">
  <div class="kpi"><div class="v">3</div><div class="l">services</div></div>
  <div class="kpi"><div class="v">~80ms</div><div class="l">p50 latency</div></div>
  <script type="application/json" class="export-data">
    {"type":"kpis","items":[{"value":"3","label":"services"},{"value":"~80ms","label":"p50 latency"}]}
  </script>
</div>
```

## Table
Plain `<table>` — no island needed, it exports automatically. Use the styled
`thead`/`tbody` from the template. Reach for a table when data has 2+ dimensions
the reader will scan or compare.

## Tabs
Switch between parallel variants (iOS/Android, before/after, REST/GraphQL).
```html
<div class="tabs" data-block="tabs">
  <div class="tabs-nav">
    <button aria-selected="true">iOS</button>
    <button aria-selected="false">Android</button>
  </div>
  <div class="tab-panel"><p>Swift / SwiftUI notes…</p></div>
  <div class="tab-panel" hidden><p>Kotlin / Compose notes…</p></div>
  <script type="application/json" class="export-data">
    {"type":"tabs","tabs":[
      {"label":"iOS","md":"Swift / SwiftUI notes…"},
      {"label":"Android","md":"Kotlin / Compose notes…"}]}
  </script>
</div>
```
(The template's tab script handles the switching.)

## Comparison
**Include whenever the doc weighs options and the reader must decide.** Show
side-by-side cards (mark the winner `is-recommended` + a `Recommended` badge),
and let the island also carry a decision matrix so the Markdown export becomes a
clean criterion×option table ending in `✅ Recommended: …`.
```html
<section class="doc-section" data-section data-section-title="Options compared"
         data-section-id="compare" data-block="comparison">
  <h2>Options compared</h2>
  <div class="compare">
    <div class="compare-card is-recommended">
      <span class="badge">Recommended</span>
      <h4>Queue-based</h4>
      <ul class="pros"><li>Absorbs spikes</li></ul>
      <ul class="cons"><li>Eventual consistency</li></ul>
    </div>
    <div class="compare-card">
      <h4>Synchronous</h4>
      <ul class="pros"><li>Simple</li></ul>
      <ul class="cons"><li>Fragile under load</li></ul>
    </div>
  </div>
  <script type="application/json" class="export-data">
    {"type":"comparison","title":"Options compared","options":["Queue-based","Synchronous"],
     "criteria":[{"name":"Handles spikes","values":["Yes","No"]},
                 {"name":"Complexity","values":["Medium","Low"]}],
     "recommended":"Queue-based","rationale":"Resilience under load outweighs eventual consistency here."}
  </script>
</section>
```

<a id="ui-preview"></a>
## UI preview
**Include whenever the decision is about UI or design.** Don't describe a screen in
words and ask the human to imagine it — *show* it, so they can look and decide. Render
the mockup in a sandboxed `<iframe srcdoc>` (its CSS can't leak into the doc); the
island carries the same markup as `html` so an AI reading the export can rebuild it.
```html
<figure class="preview" data-block="preview">
  <div class="preview-bar"><span class="dot"></span><span class="dot"></span><span class="dot"></span></div>
  <iframe class="preview-frame" title="UI preview"
    srcdoc="&lt;div style='padding:24px'&gt;&lt;button class='cta'&gt;Pay now&lt;/button&gt;&lt;/div&gt;"></iframe>
  <figcaption>Primary CTA above the fold. Look and decide, or comment below.</figcaption>
  <script type="application/json" class="export-data">
    {"type":"preview","title":"Checkout CTA","description":"Primary action moved above the fold; single-column form.",
     "html":"<button class=\"cta\">Pay now</button>"}
  </script>
</figure>
```
- **HTML-escape** the `srcdoc` markup (`&lt; &gt; &amp; &quot;`) — it's an attribute.
  Use `image` instead of `html` in the island to preview a static asset (`![…](src)`).
- In **[plan-approval mode](#plan-approval-mode)** a section with a preview gets a
  **comments** box (not a decision picker) so the human can note adjustments — spacing,
  copy, colour — and those comments flow into the approved plan.

## Diagram
The workhorse — see **references/diagrams.md** for choosing the right kind and
the Mermaid recipes. Skeleton:
```html
<figure class="diagram" data-block="diagram">
  <pre class="mermaid">flowchart LR
  A[Start] --> B{Decision}</pre>
  <figcaption>What the reader should take away.</figcaption>
  <script type="application/json" class="export-data">
    {"type":"diagram","diagramType":"flowchart","title":"…","source":"flowchart LR\n  A[Start] --> B{Decision}"}
  </script>
</figure>
```
The island's `source` is the **Mermaid text** — an LLM reads it perfectly, so the
Markdown export carries the diagram as a ```` ```mermaid ```` fence.

**Make it interactive.** Inline `assets/diagram-interactions.js` and every diagram
gets zoom/pan + hover-spotlight for free; add a `nodes` map (and optional
`walkthrough`) to the island to make nodes clickable — jump to a section, open a
detail drawer, or open a link. Full schema + example in **references/diagrams.md →
"Make the diagram interactive"**.

## Chart
For quantitative data (counts, latencies, trends, splits). Add the Chart.js CDN
tag (see template) only when you actually use one.
```html
<figure class="chart" data-block="chart">
  <canvas id="c1" height="160"></canvas>
  <figcaption>p50 latency by service (ms).</figcaption>
  <script type="application/json" class="export-data">
    {"type":"chart","chartType":"bar","title":"p50 latency by service (ms)",
     "labels":["api","worker","db"],"datasets":[{"label":"p50","data":[40,80,12]}]}
  </script>
</figure>
<script>
  // Build the visual from the SAME island data so they never drift:
  (function(){
    const d = JSON.parse(document.querySelector('#c1').closest('figure').querySelector('.export-data').textContent);
    new Chart(document.getElementById('c1'), {
      type: d.chartType,
      data: { labels: d.labels, datasets: d.datasets.map(s => ({...s,
        backgroundColor: getComputedStyle(document.documentElement).getPropertyValue('--color-primary').trim()})) },
      options: { plugins:{legend:{display:d.datasets.length>1}} }
    });
  })();
</script>
```
The Markdown export renders a chart as a data table (labels × series) — readable
by both humans and LLMs.

## Steps / Implementation Plan
Ordered, actionable steps. **Include an "Implementation Plan" as the doc's last
section whenever it proposes something to be built** (a change, feature, or solution
an agent/engineer will execute); skip it for pure explainers.

The [two-readers](#the-export-contract-read-this-once) split matters most **here**. The
visible `.plan` list may read as a short, human-friendly summary — but the **`steps`
island is the authoritative implementation plan**, and it must be the *intensive,
step-by-step brief an AI executes with zero ambiguity*: every step names the concrete
**file/component target** (be specific — `lib/infra/queue.dart`, not "the backend"),
the **exact change** to make there, the **acceptance criteria** that prove it's done,
and any **ordering/risk** notes. The approved plan markdown is rebuilt from this island
(SKILL.md → "Plans vs. documents"), so a thin island leaves the executing agent
guessing — never let it be less detailed than the plan the next phase needs. JSON
becomes a hand-off task list; Markdown a paste-ready implementation prompt.
```html
<div class="plan" data-block="steps">
  <ol>
    <li><strong>Add the queue client.</strong>
        <span class="target">lib/infra/queue.dart</span> — typed <code>enqueue()</code>.</li>
    <li><strong>Acceptance:</strong> duplicate delivery → one DB write.</li>
  </ol>
  <script type="application/json" class="export-data">
    {"type":"steps","title":"Implementation Plan","steps":[
      {"title":"Add the queue client","md":"`lib/infra/queue.dart` — typed `enqueue()`."},
      {"title":"Acceptance","md":"Duplicate delivery → one DB write."}]}
  </script>
</div>
```

<a id="plan-approval-mode"></a>
## Plan-approval mode (decisions + approve)

A doc is a **plan** (not a plain explainer) when it ends in an Implementation Plan.
When that plan still needs a human's sign-off — i.e. `planning.auto_approve` is
**false** — turn on *plan-approval mode* so the human can decide *in the page* and
have those decisions reach the markdown a later phase executes. Why it matters: the
HTML is for reading only; `--approve-plan` and every downstream step read the
**markdown**, never the page. Without this loop, a human's edits in the HTML are
silently dropped at build time.

**Turn it on** by setting three attributes on the page root and inlining
`assets/plan-approval.js` (after `export-engine.js`):
```html
<main data-doc data-doc-title="…"
      data-plan-approval="pending"
      data-plan-md="agent_logs/development-planner/FM-12-app-plan.md"
      data-plan-cmd="/dev-cycle FM-12 --approve-plan">
```
- `data-plan-md` is the **authoritative markdown** the next phase reads — the Approve
  download is named to replace exactly this file.
- `data-plan-cmd` is the command shown to the human to re-run once approved.
- Omit all three (and don't inline the engine) for a plain explainer, or when
  `auto_approve` is on — the plan then renders read-only.

**What the engine does, with no extra authoring:**
- Adds a collapsible **Decision** control to every section — *accept as proposed*,
  *pick an option*, or *write a modification* for the implementer. Options are
  auto-derived from a [comparison](#comparison) in that section (its `options`,
  defaulting to `recommended`), so a "weigh the options" section becomes a real
  choose-one (radio) control for free.
- A section with a [UI preview](#ui-preview) instead gets a **comments** box, so the
  human can note what to adjust in the design — those comments join the approved plan.
- Writes each change **live** into the plan island's `decisions` array (the export
  source of truth) and mirrors it in a "Human decisions" block inside the plan — so
  the plan reflects the human's intent in real time.
- Renders an **✅ Approve & download plan** button in the plan section. It serializes
  the current plan (decisions included) to Markdown via the export engine and
  downloads it under the `data-plan-md` basename, then tells the human to drop it over
  `data-plan-md` and re-run `data-plan-cmd`.

The exported `steps` block leads with the approved decisions, then the original steps:
```markdown
**🧑‍⚖️ Human decisions (approved):**
- **Options compared** — chose **Synchronous** — start simple; revisit if load grows
- **Data model** — modified — keep meals and meds in one table for v1
1. **Add the queue client** `lib/infra/queue.dart` — typed `enqueue()`.
…
```

**Pose a specific question** (optional) by adding a `decision-data` island to a section
— it overrides the auto-derived control. Set `"type":"multi"` for a **pick-many
(checkbox)** control; omit it (or `"single"`) for **pick-one (radio)**. `default` is
the pre-checked value — an array for `multi`.
```html
<section class="doc-section" data-section data-section-title="Write path" data-section-id="write-path">
  …
  <!-- pick-one -->
  <script type="application/json" class="decision-data">
    {"question":"Which write path for v1?","options":["Queue-based","Synchronous"],"default":"Queue-based"}
  </script>
</section>

<section class="doc-section" data-section data-section-title="Launch platforms" data-section-id="platforms">
  …
  <!-- pick-many -->
  <script type="application/json" class="decision-data">
    {"question":"Which platforms ship in v1?","type":"multi",
     "options":["iOS","Android","Web"],"default":["iOS","Android"]}
  </script>
</section>
```
The human's picks land in the approved plan's `decisions` — pick-one as `choice`,
pick-many as `choices`, any note as `note`:
```markdown
- **Write path** — chose **Synchronous** — start simple; revisit if load grows
- **Launch platforms** — chose **iOS**, **Web**
- **New save button** — commented — nudge it 8px down; use the accent colour
```
Decision controls are pure UI (`div`/`label`/`input`/`textarea`/`button`) the export
engine ignores, so they never leak into the Markdown — only the island's `decisions`
field does.

## Accordion
Use the native `<details>` element for "deep dive on demand" — it exports as a
heading + body automatically; no island needed.
```html
<details>
  <summary>Why eventual consistency is acceptable here</summary>
  <p>…</p>
</details>
```

---

## Composition rules of thumb
- One idea per section. If a section sprawls, split it.
- Lead with the picture (diagram/chart/KPIs), then the prose explains it — not
  the other way around.
- Prefer a table over 5 parallel sentences; a diagram over a paragraph that
  describes a flow; tabs over repeating the same structure per platform.
- Don't decorate for its own sake — every colour and component should carry
  meaning (status, category, recommendation).
