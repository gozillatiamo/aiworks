# Diagrams — pick the kind that fits the content

A diagram earns its place only when it shows something prose can't say cleanly:
a flow, a relationship, a structure, a change over time. The wrong *kind* of
diagram is worse than none — so match the diagram type to the **shape of the
idea**, then render it with Mermaid (loaded via CDN in the template).

## Choose by the shape of the idea

| The content is about… | Use | Mermaid type |
| --- | --- | --- |
| A process / decisions / a request path | Flowchart | `flowchart LR/TD` |
| Who talks to whom, in what order, over time | Sequence | `sequenceDiagram` |
| The states a thing moves through (lifecycle) | State | `stateDiagram-v2` |
| Data entities and their relationships | ER | `erDiagram` |
| A hierarchy / breakdown / taxonomy | Tree or mindmap | `mindmap` / `flowchart TD` |
| Modules/layers of a system (architecture) | Grouped flowchart | `flowchart` + `subgraph` |
| Tasks across a schedule | Timeline | `gantt` |
| Parts of a whole (proportions) | Pie | `pie` (or a Chart.js doughnut) |
| Quantities, trends, comparisons of numbers | **Chart, not a diagram** | Chart.js (see components.md) |
| User journey with sentiment | Journey | `journey` |
| Git/branch history | Gitgraph | `gitGraph` |

Rule of thumb: **relationships & flows → Mermaid; numbers → Chart.js; decisions
between options → the comparison component.**

## Recipes

**Flowchart** (process / architecture; group with `subgraph`):
```
flowchart LR
  U[User] --> API[API Gateway]
  subgraph Backend
    API --> SVC[Service] --> DB[(Database)]
    SVC --> Q[(Queue)] --> W[Worker]
  end
```

**Sequence** (ordered interactions over time):
```
sequenceDiagram
  participant U as User
  participant A as App
  participant S as Server
  U->>A: tap "Save"
  A->>S: POST /pets
  S-->>A: 201 Created
  A-->>U: success toast
```

**State** (lifecycle / status machine):
```
stateDiagram-v2
  [*] --> Draft
  Draft --> Submitted: submit
  Submitted --> Approved: review ok
  Submitted --> Draft: changes requested
  Approved --> [*]
```

**ER** (data model):
```
erDiagram
  OWNER ||--o{ PET : has
  PET ||--o{ RECORD : "health record"
  PET { string name; string species; date birthday }
```

**Mindmap** (hierarchy / concept breakdown):
```
mindmap
  root((Feature))
    Data
      Local cache
      Sync
    UI
      List
      Detail
```

## Theming the diagram
The template initialises Mermaid with `theme:"base"` and feeds it the page's CSS
tokens (`--color-primary`, `--color-text`, …) via `themeVariables`, so diagrams
inherit the project's palette automatically. Don't hard-code diagram colours;
let them follow the tokens. For per-node emphasis use Mermaid `classDef` mapped
to a token, e.g. `classDef hot fill:#…` only when a node truly needs to pop.

## The export island (so the diagram survives export)
Every diagram block carries its Mermaid text in the island's `source`. That's
gold for AI consumption — the Markdown export emits a real ```` ```mermaid ````
fence an LLM can re-render or reason about. Keep `source` byte-identical to the
visible `.mermaid` text (use `\n` for line breaks in the JSON string).

```html
<figure class="diagram" data-block="diagram">
  <pre class="mermaid">stateDiagram-v2
  [*] --> Draft
  Draft --> Done: ship</pre>
  <figcaption>Ticket lifecycle.</figcaption>
  <script type="application/json" class="export-data">
    {"type":"diagram","diagramType":"state","title":"Ticket lifecycle",
     "source":"stateDiagram-v2\n  [*] --> Draft\n  Draft --> Done: ship"}
  </script>
</figure>
```

## Make the diagram interactive

A diagram a reader can *explore* teaches far more than a static picture. Inline
**assets/diagram-interactions.js** (after the Mermaid script — it injects its own
CSS and waits for Mermaid to finish) and every diagram instantly gains, with zero
extra authoring:

- **zoom & pan + reset + fullscreen** — the +/- buttons zoom about the diagram's
  centre (so it stays put); fullscreen fits the diagram to the screen and centres it;
  drag to pan. On a Mac trackpad a **pinch** zooms the diagram (about the cursor) while a
  plain **two-finger up/down swipe scrolls the page** — the engine tells them apart by the
  `ctrlKey` flag the browser sets on a pinch's wheel event, intercepting *only* the pinch
  and leaving ordinary scroll completely untouched (claiming the plain wheel was the old
  "scroll doesn't work" bug);
- **hover spotlight** — hovering a node dims the rest so a path stands out;
- **click to select** — clicking a node gives it a persistent highlight that follows
  your clicks (and the walkthrough); the detail drawer is *non-modal*, so you can click
  node→node and the highlight + info just follow along. Clicking empty space or closing
  the drawer clears it;
- **keyboard-reachable nodes** — focusable, Enter/Space activates.

Then make nodes *do* something by adding an optional **`nodes`** map to the
island, keyed by each node's **visible label** (simplest) or its id. Per node:

| field | click does | use it for |
| --- | --- | --- |
| `section` | scrolls to `[data-section-id="…"]` and pulses it | "this box is explained in §X" |
| `detail` | opens a side drawer rendering this markdown | a definition, a why, a gotcha |
| `url` | opens the link in a new tab | external docs / source |
| `label` | (not a click) friendly title for the drawer + export | nicer names |

Add **`walkthrough`** — an ordered list of node keys — and the toolbar grows a
◀ ▶ guided tour that spotlights each node in turn and opens its detail. Perfect
for "let me walk you through this flow" diagrams.

```html
<figure class="diagram" data-block="diagram">
  <pre class="mermaid">flowchart LR
  U[Pet owner] --> A[App] --> DB[(Local DB)]</pre>
  <figcaption>How a saved meal reaches the device.</figcaption>
  <script type="application/json" class="export-data">
    {"type":"diagram","diagramType":"flowchart","title":"Save flow",
     "source":"flowchart LR\n  U[Pet owner] --> A[App] --> DB[(Local DB)]",
     "nodes":{
       "Pet owner":{"detail":"The person logging a meal."},
       "App":{"section":"architecture","detail":"The offline-first Flutter client."},
       "Local DB":{"url":"https://isar.dev","label":"Isar","detail":"On-device store."}
     },
     "walkthrough":["Pet owner","App","Local DB"]}
  </script>
</figure>
```

Why keep this in the island rather than in raw Mermaid `click` directives? Because
the island is the single source of truth — the export engine reads the same
`nodes`/`detail` into the Markdown/JSON export, so a reader who clicks and a model
who reads the export see the *same* information. (The Mermaid-native path still
works for power users: set `securityLevel:"loose"` and write
`click X call widGo("section-id")` or `click X "https://…"`.)

Reach for interactivity when it genuinely helps — an architecture map whose boxes
each open a detail, a flow you want to walk through. A tiny 3-node diagram is
already clear; don't gild it.

### Don't let it break — the two rules that bite

These are the failures that make a diagram *look* fine but not respond. The
verifier (`scripts/verify-doc.mjs`) checks both; understand them so you avoid them:

1. **The island `source` must be byte-identical to the visible `<pre class="mermaid">`
   text, and must be valid Mermaid on its own.** The browser renders the `<pre>`; the
   export ships the island `source`. If they drift, the exported diagram is wrong; if
   the `source` isn't valid Mermaid (e.g. `BRD[/brd]` is read as a *parallelogram*
   shape — quote it: `BRD["/brd"]`; and a bare `&` is Mermaid's chaining operator —
   put labels with `&`, `/`, `(`, `:` inside `"quotes"`), it won't render at all.
   Easiest path: write the source once, paste the *same* text into both places.

2. **A `nodes`/`walkthrough` key must match a node that exists in the rendered SVG.**
   The engine matches by the Mermaid **node id** (the identifier left of the `[label]`,
   e.g. `A` in `A["App"]`) *or* the **visible label text** — it reads the id back out
   of Mermaid's SVG (`<g id="…-flowchart-A-0">`). So keep node ids simple
   (`[A-Za-z0-9_]`, no spaces/dashes) or key by the exact visible label. A key that
   matches neither silently wires nothing — clicks and the walkthrough do nothing,
   which reads as "the diagram is broken." The verifier reports `N/N nodes resolve`,
   so a mismatch shows up as `2/5`.

## Keep diagrams legible
- ≤ ~12 nodes per diagram; split a big one into two focused ones. (Zoom/pan makes
  a denser diagram survivable, but clarity still beats cramming.)
- Label edges with the verb/condition (`submit`, `on error`), not just arrows.
- Pick one direction (`LR` for pipelines, `TD` for hierarchies) and stick to it.
- Put the takeaway in the `<figcaption>` — what should the reader conclude?
