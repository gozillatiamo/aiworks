#!/usr/bin/env node
// artifact-prep.mjs — make a verified write-interactive-docs .html CSP-safe so it
// renders correctly as a Claude Artifact (strict CSP: no external host — CDN
// scripts, webfont links, remote anything is blocked).
//
//   node scripts/artifact-prep.mjs <in.html> <out.html>
//
// What it does (deterministic; safe to re-run):
//   1. Strips the Google-Fonts <link>s (blocked) — the doc's CSS already declares a
//      system-font fallback stack, so Latin + Thai still render (no tofu, no silent
//      blocked-request). Inline brand fonts are an opt-in: drop a `faces.css` of
//      @font-face data-URIs at assets/artifact-fonts/faces.css and it gets inlined.
//   2. Strips every external `<script src="http…">` (Mermaid CDN, Chart.js CDN, …).
//      Mermaid is not re-added: Claude Artifacts render `<pre class="mermaid">`
//      NATIVELY, so diagrams still draw; diagram-interactions.js attaches to the
//      native-rendered SVG via its MutationObserver, so zoom/pan/click survive too.
//   3. Strips the inline `mermaid.initialize(…)` block — it throws once the CDN
//      global is gone, and the native renderer does the init itself.
//   4. If the doc builds charts (`new Chart(`), inlines the vendored Chart.js UMD
//      (assets/vendor/chart.umd.min.js) as the FIRST script so the `Chart` global
//      exists before any chart-building script runs.
//
// It does NOT touch export-engine.js, diagram-interactions.js, i18n.js,
// plan-approval.js or the tab script — those are inline, CSP-safe, and keep working.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const [, , inPath, outPath] = process.argv;
if (!inPath || !outPath) {
  console.error("usage: node artifact-prep.mjs <in.html> <out.html>");
  process.exit(2);
}

const CHART_JS = new URL("../assets/vendor/chart.umd.min.js", import.meta.url);
const FONT_CSS = new URL("../assets/artifact-fonts/faces.css", import.meta.url);

let html = readFileSync(inPath, "utf8");
const note = [];

// 1 — Google Fonts links (preconnect + the css2 stylesheet).
{
  const before = html;
  html = html.replace(
    /[ \t]*<link\b[^>]*\b(?:fonts\.googleapis\.com|fonts\.gstatic\.com)[^>]*>\s*\n?/gi,
    ""
  );
  if (html !== before) note.push("removed Google-Fonts <link>s");
}

// 1b — optional inline brand fonts (only if a vendored faces.css exists).
if (existsSync(FONT_CSS)) {
  const faces = readFileSync(FONT_CSS, "utf8").trim();
  html = html.replace(/<\/head>/i, `<style data-artifact-fonts>\n${faces}\n</style>\n</head>`);
  note.push("inlined vendored @font-face (assets/artifact-fonts/faces.css)");
} else {
  note.push("fonts: system stack (no vendored faces.css — CSS fallback used)");
}

// 2 — external <script src="http…"> (mermaid CDN, chart.js CDN, anything remote).
{
  const before = html;
  let n = 0;
  html = html.replace(
    /[ \t]*<script\b[^>]*\bsrc=["']https?:\/\/[^"']+["'][^>]*>\s*<\/script>\s*\n?/gi,
    () => {
      n++;
      return "";
    }
  );
  if (html !== before) note.push(`removed ${n} external <script src>`);
}

// 3 — inline mermaid.initialize(…) block (throws without the CDN global).
{
  const before = html;
  html = html.replace(/[ \t]*<script\b[^>]*>\s*mermaid\.initialize[\s\S]*?<\/script>\s*\n?/gi, "");
  if (html !== before) note.push("removed mermaid.initialize block");
}

// 4 — inline vendored Chart.js only when the doc actually charts.
if (/\bnew\s+Chart\s*\(/.test(html)) {
  const chart = readFileSync(CHART_JS, "utf8");
  const tag = `<script data-artifact-chartjs>\n${chart}\n</script>\n`;
  // First script in the body so `Chart` is defined before any chart-building script.
  if (/<body\b[^>]*>/i.test(html)) {
    html = html.replace(/(<body\b[^>]*>)/i, `$1\n${tag}`);
  } else {
    html = tag + html;
  }
  note.push("inlined vendored Chart.js (charts detected)");
} else {
  note.push("no charts — Chart.js not inlined");
}

// Guard: nothing external should remain (fonts links + script srcs are the CSP risk).
const leaks = [];
if (/<script\b[^>]*\bsrc=["']https?:/i.test(html)) leaks.push("external <script src> still present");
if (/<link\b[^>]*\bhref=["']https?:\/\/(?:fonts\.googleapis|fonts\.gstatic)/i.test(html))
  leaks.push("Google-Fonts <link> still present");

writeFileSync(outPath, html, "utf8");

console.log(`artifact-prep: ${inPath} -> ${outPath}`);
for (const n of note) console.log(`  · ${n}`);
if (leaks.length) {
  for (const l of leaks) console.error(`  ⚠ ${l}`);
  process.exit(1);
}
console.log("  ✓ CSP-safe (no external script/font requests)");
