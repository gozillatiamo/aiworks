# Component library

The doc is built by **composing** these blocks — pick the one that explains each
idea best, never a wall of text. Every component below shows its HTML and, where
it's a *rich* block, the `export-data` island that makes it exportable.

## The export contract (read this once)

The export engine reconstructs Markdown/JSON from the page. Two paths:

1. **Plain HTML** (`p`, `h2`, `ul`, `table`, `pre`, `blockquote`, `hr`, links,
   `strong`/`em`/`code`) is converted **automatically**. Write normal HTML.
2. **Rich blocks** (diagram, chart, comparison, tabs, callout, steps, kpis)
   can't be read from pixels, so each carries a hidden
   `<script type="application/json" class="export-data">…</script>` child whose
   parent has `data-block="<type>"`. That island is the **single source of
   truth** for export.

**Author the island first, then build the visual from the same data** so they
never drift. If a rich block has no island, it won't export cleanly.

A section is `<section class="doc-section" data-section data-section-title="…"
data-section-id="…">`. Section id/title power both the on-page export buttons
and the in-document anchors.

---

## Table of contents
- [Callout](#callout) — info / tip / warning / danger / success
- [KPI row](#kpi-row) — headline numbers
- [Table](#table) — plain auto-exporting tabular data
- [Tabs](#tabs) — platform / variant switches (iOS vs Android, etc.)
- [Comparison](#comparison) — options weighed → a recommendation
- [Diagram](#diagram) — see also references/diagrams.md
- [Chart](#chart) — quantitative data (Chart.js)
- [Steps / Implementation Plan](#steps--implementation-plan)
- [Plan-approval mode (decisions + approve)](#plan-approval-mode)
- [Accordion / details](#accordion)

---

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
an agent/engineer will execute); skip it for pure explainers. Write it *for an AI to
preview and execute*: each step names the concrete **file/component target** to touch
and what to change there (be specific — `lib/infra/queue.dart`, not "the backend"),
plus the **acceptance criteria** that prove it's done and any risky/ordering notes.
The `steps` block exports cleanly — JSON becomes a hand-off task list, Markdown a
paste-ready prompt.
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
  choose-one control for free.
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
— it overrides the auto-derived control:
```html
<section class="doc-section" data-section data-section-title="Write path" data-section-id="write-path">
  …
  <script type="application/json" class="decision-data">
    {"question":"Which write path for v1?","options":["Queue-based","Synchronous"],"default":"Queue-based"}
  </script>
</section>
```
Decision controls are pure UI (`div`/`label`/`select`/`textarea`/`button`) the export
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
