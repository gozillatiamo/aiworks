# Vendored assets

**`mermaid.min.js`** — Mermaid **11.16.0**, fetched from
`https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js` (byte-identical to the build
the `write-interactive-docs` template loads). It exposes a global `mermaid`
(`globalThis["mermaid"] = …`), so `<script src>` + `mermaid.initialize(…)` works.

Vendored so the PDF pipeline has **no CDN dependency** — diagrams render offline and on a
locked-egress cloud host. `pdf.mjs` serves this file in place of the doc's own CDN
`<script>` via request interception, and the Markdown shell loads it directly.

### Updating

Keep the major in sync with the skill template's `mermaid@<major>` pin. To refresh:

```bash
curl -fsSL https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js \
  -o scripts/pdf/vendor/mermaid.min.js
```

Then update the version noted above. (Chart.js is **not** vendored yet — if a doc uses
Chart.js and the host has locked egress, add `chart.min.js` here and extend the request
interception in `pdf.mjs` the same way.)
