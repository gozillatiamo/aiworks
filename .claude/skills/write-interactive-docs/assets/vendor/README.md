# Vendored assets

**`chart.umd.min.js`** — Chart.js **4.5.1** (UMD build), fetched from
`https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js`. Loaded as a plain
`<script>` it exposes the `Chart` global, so a doc's `new Chart(...)` builders work
unchanged.

Vendored so a doc published as a **Claude Artifact** renders its charts: the Artifact
CSP blocks the Chart.js CDN, so `scripts/artifact-prep.mjs` inlines this file in its
place (only when the doc actually charts). A local `.html` still loads Chart.js from the
CDN as before — this copy is used only on the Artifact path.

### Updating

Keep the major in sync with the doc's `chart.js@<major>` CDN pin. To refresh:

```bash
curl -fsSL https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js \
  -o .claude/skills/write-interactive-docs/assets/vendor/chart.umd.min.js
```

Then update the version noted above.
