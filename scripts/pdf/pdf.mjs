#!/usr/bin/env node
// scripts/pdf/pdf.mjs
//
// Render an HTML or Markdown doc — with diagram illustrations from EITHER an image source
// (<img> / ![](…)) OR Mermaid source (```mermaid / <pre class="mermaid">) — to a PDF, using a
// headless Chromium-family browser driven by puppeteer-core.
//
//   node pdf.mjs <input.html|.md> <output.pdf> [--format A4|Letter] [--timeout ms] [--margin 14mm] [--as-is]
//   node pdf.mjs <input.html|.md> <output.png> --png [--width 1280] [--timeout ms]
//
// Invoke through render.sh, which resolves/provisions the browser and exports CHROME_PATH.
//
// TWO OUTPUT MODES, and they are deliberately opposites:
//
//   default (PDF) — a CLEAN, plain document, NOT a screenshot of the interactive page. The
//                   detail below describes this mode.
//   --png         — the exact opposite: a full-page SCREENSHOT of the page as it actually
//                   renders, chrome and all. It exists because some results ARE a rendered
//                   page — a k6 HTML run report, a coverage summary — and the point of
//                   putting one on a ticket is that a human sees what the tool drew. A
//                   paginated re-typeset of it would be a different, worse artifact. --png
//                   therefore implies --as-is (never reconstruct the content) and never
//                   paginates, so --format/--margin do not apply to it.
//
// --expand (with --png) reveals content the page keeps COLLAPSED, before capturing. A
// screenshot is one frozen state, so a tabbed page yields only its open tab: a real
// k6-reporter run report hides "Test Run Details" and "Checks & Groups" behind CSS
// radio-tabs, and the checks are the half a QA reader most wants. Best-effort by design —
// it un-hides the common collapse idioms (CSS radio-tabs, [role=tabpanel], .tab-pane,
// <details>) and cannot know a bespoke one, so it is opt-in and never silently assumed.
//
// Default (PDF) mode:
//   .md   — converted with `marked`; ```mermaid fences become <pre class="mermaid"> and the
//           result is wrapped in a minimal document shell that loads the vendored Mermaid.
//   .html from write-interactive-docs — the page carries an export engine (window.WID) that
//           reconstructs its own content as Markdown (sections, tables, callouts, and diagrams
//           as ```mermaid fences from the export islands). We run that, then render the
//           Markdown through the SAME shell. This avoids paginating the interactive layout
//           (absolute/grid/sticky sections overlap on paper) and drops all interactive chrome.
//   .html without an export engine (hand-authored) — printed as-is (its own styling); a print
//           stylesheet hides any `wid-` controls and un-clips diagram viewports. Force this for
//           any HTML with --as-is.
//
// Offline-safe: the doc's Mermaid CDN <script> is intercepted and served from
// vendor/mermaid.min.js, so no network is needed. Best-effort (Q6): a diagram that fails to
// render within --timeout is left partial and the PDF is still written; the process fails only
// on a hard error (bad args, missing browser, no input).

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import puppeteer from "puppeteer-core";
import { marked } from "marked";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const VENDOR_MERMAID = path.join(HERE, "vendor", "mermaid.min.js");
const USAGE =
  "usage: pdf.mjs <input.html|.md> <output.pdf> [--format A4|Letter] [--timeout ms] [--margin 14mm] [--as-is]\n" +
  "       pdf.mjs <input.html|.md> <output.png> --png [--width 1280] [--expand] [--timeout ms]";

const warn = (m) => process.stderr.write(`[pdf] warn: ${m}\n`);
const info = (m) => process.stderr.write(`[pdf] ${m}\n`);
const die = (m) => {
  process.stderr.write(`[pdf] error: ${m}\n`);
  process.exit(1);
};

// -- args ---------------------------------------------------------------------
const argv = process.argv.slice(2);
let input, output;
const opt = { format: "A4", timeout: 20000, margin: "14mm", asis: false, png: false, width: 1280, expand: false };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--format") opt.format = argv[++i];
  else if (a === "--timeout") opt.timeout = parseInt(argv[++i], 10) || opt.timeout;
  else if (a === "--margin") opt.margin = argv[++i];
  else if (a === "--as-is") opt.asis = true;
  else if (a === "--png") opt.png = true;
  else if (a === "--width") opt.width = parseInt(argv[++i], 10) || opt.width;
  else if (a === "--expand") opt.expand = true;
  else if (a === "-h" || a === "--help") { process.stdout.write(USAGE + "\n"); process.exit(0); }
  else if (a.startsWith("--")) die(`unknown option: ${a}\n${USAGE}`);
  else if (!input) input = a;
  else if (!output) output = a;
  else die(`unexpected argument: ${a}\n${USAGE}`);
}
if (!input || !output) die(USAGE);
if (!fs.existsSync(input)) die(`no such input: ${input}`);
// A screenshot of a re-typeset document would defeat the purpose of asking for one.
if (opt.png) opt.asis = true;
if (opt.png && !/\.png$/i.test(output)) die(`--png writes a PNG, but the output is '${output}'`);
if (!opt.png && /\.png$/i.test(output)) die(`output '${output}' looks like a PNG — pass --png`);

const CHROME = process.env.CHROME_PATH;
if (!CHROME || !fs.existsSync(CHROME))
  die(`CHROME_PATH not set or missing (${CHROME || "unset"}) — run via render.sh, which resolves or provisions a browser`);

const ext = path.extname(input).toLowerCase();
const isMd = ext === ".md" || ext === ".markdown";
const isHtml = ext === ".html" || ext === ".htm";
if (!isMd && !isHtml) die(`unsupported input extension '${ext}' (use .html/.htm or .md/.markdown)`);

const MERMAID_JS = fs.readFileSync(VENDOR_MERMAID); // served in place of the CDN request

// Fallback print stylesheet — for the as-is HTML path only (a clean shell needs none). Mirrors
// the write-interactive-docs template's canonical <style id="wid-print"> block.
const PRINT_CSS =
  "@media print{" +
  ".wid-toolbar,.wid-toolbar-label,.wid-section-tools,.wid-btn,.wid-toast," +
  ".wid-dgm-tools,.wid-dgm-walk,.wid-dgm-hint,.wid-dgm-scrim,.wid-dgm-panel," +
  ".wid-lang,.wid-approve-btn,.wid-plan-approve,.wid-decision,.wid-plan-decisions{display:none!important}" +
  ".wid-dgm-viewport{overflow:visible!important;max-height:none!important;height:auto!important}" +
  "html .wid-dgm-viewport>.mermaid>svg{transform:none!important;max-width:100%!important;height:auto!important}" +
  "figure.diagram,.mermaid,.mermaid svg,img{max-width:100%!important;height:auto!important}" +
  "body{background:#fff}}";

const tmpFiles = [];
function writeShellFile(md, baseHref, title) {
  const body = String(marked.parse(md)).replace(
    /<pre><code class="language-mermaid">([\s\S]*?)<\/code><\/pre>/g,
    (_, code) => `<pre class="mermaid">${code}</pre>`,
  );
  const file = path.join(os.tmpdir(), `aiworks-pdf-${process.pid}-${tmpFiles.length}-${Date.now()}.html`);
  fs.writeFileSync(file, mdShell({ body, baseHref, mermaidHref: pathToFileURL(VENDOR_MERMAID).href, title }));
  tmpFiles.push(file);
  return pathToFileURL(file).href;
}

(async () => {
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true, // new headless (real Chrome-for-Testing render fidelity)
    args: [
      "--no-sandbox",
      "--disable-gpu",
      "--disable-dev-shm-usage", // small /dev/shm in containers
      "--allow-file-access-from-files", // file:// page may load the vendored file:// mermaid + local images
      "--hide-scrollbars",
    ],
  });
  try {
    const page = await browser.newPage();
    // A screenshot has no paper size to fall back on, so the viewport IS the layout: fix the
    // width and let fullPage grow the height to whatever the document turns out to be. The
    // starting height is deliberately short — fullPage captures max(content, viewport), so a
    // tall default would pad a small report with blank space.
    if (opt.png) await page.setViewport({ width: opt.width, height: 400, deviceScaleFactor: 2 });

    // Offline-safe Mermaid: serve the vendored bundle for the doc's own CDN <script>.
    await page.setRequestInterception(true);
    page.on("request", (req) => {
      if (/^https?:\/\/cdn\.jsdelivr\.net\/npm\/mermaid@/.test(req.url())) {
        req.respond({ status: 200, contentType: "application/javascript; charset=utf-8", body: MERMAID_JS });
      } else {
        req.continue();
      }
    });

    // Decide the render target: a clean shell (from .md, or from an interactive-doc's own
    // exported Markdown), or the original HTML printed as-is.
    let renderUrl;
    let mode; // "clean" | "asis"
    const inputUrl = pathToFileURL(path.resolve(input)).href;
    const inputDirBase = pathToFileURL(path.resolve(path.dirname(input)) + path.sep).href;

    if (isMd) {
      renderUrl = writeShellFile(fs.readFileSync(input, "utf8"), inputDirBase, path.basename(input));
      mode = "clean";
    } else if (opt.asis) {
      renderUrl = inputUrl;
      mode = "asis";
      info("HTML rendered as-is (--as-is)");
    } else {
      // Load the HTML so its export engine (window.WID) runs, then pull the page's Markdown.
      await page.goto(inputUrl, { waitUntil: "domcontentloaded", timeout: opt.timeout }).catch((e) => warn(`load: ${e.message}`));
      await page.waitForFunction(() => !!window.WID, { timeout: 3000 }).catch(() => {});
      const [md, title] = await page.evaluate(() => {
        try {
          if (window.WID && typeof window.WID.pageMd === "function") {
            return [window.WID.pageMd(window.WID.pageModel()), document.title || ""];
          }
        } catch (e) {
          return [null, String(e && e.message)];
        }
        return [null, ""];
      });
      if (md && md.trim()) {
        renderUrl = writeShellFile(md, inputDirBase, title || path.basename(input));
        mode = "clean";
        info("interactive-doc detected — rendering its content as a clean document");
      } else {
        renderUrl = inputUrl;
        mode = "asis";
        info("no export engine (window.WID) — printing the HTML as-is");
      }
    }

    await page
      .goto(renderUrl, { waitUntil: "domcontentloaded", timeout: opt.timeout })
      .catch((e) => warn(`render load: ${e.message}`));

    // The clean shell carries its own print styles; the as-is HTML path ALWAYS gets the
    // fallback appended (last in <head> so its !important wins), regardless of whether the doc
    // ships an id="wid-print" block — that block may be stale/foreign and miss a control class.
    // Not for --png: PRINT_CSS is a PRINT stylesheet (it strips controls and unclips
    // viewports for paper). A screenshot is supposed to show the page as it really is.
    if (mode === "asis" && !opt.png) {
      await page
        .evaluate((css) => {
          const s = document.createElement("style");
          s.setAttribute("data-pdf-print", "");
          s.textContent = css;
          document.head.appendChild(s);
        }, PRINT_CSS)
        .catch((e) => warn(`inject print css: ${e.message}`));
    }

    // Best-effort settle: fonts (capped), then every Mermaid block has produced an <svg>.
    await page
      .evaluate(() =>
        Promise.race([
          (document.fonts && document.fonts.ready) || Promise.resolve(),
          new Promise((r) => setTimeout(r, 8000)),
        ]),
      )
      .catch(() => {});
    await page
      .waitForFunction(
        () => Array.from(document.querySelectorAll(".mermaid")).every((m) => m.querySelector("svg")),
        { timeout: opt.timeout, polling: 200 },
      )
      .catch(() => warn("render wait timed out — printing partial (some diagrams may be blank)"));

    if (opt.png) {
      if (opt.expand) {
        await page
          .evaluate((css) => {
            const s = document.createElement("style");
            s.setAttribute("data-pdf-expand", "");
            s.textContent = css;
            document.head.appendChild(s);
            for (const d of document.querySelectorAll("details")) d.open = true;
          }, EXPAND_CSS)
          .catch((e) => warn(`expand: ${e.message}`));
        // Reflow + any lazy content the reveal triggers.
        await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))).catch(() => {});
      }
      await page.screenshot({ path: output, fullPage: true, type: "png" });
    } else {
      await page.pdf({
        path: output,
        format: opt.format,
        printBackground: true,
        preferCSSPageSize: true,
        margin: { top: opt.margin, bottom: opt.margin, left: opt.margin, right: opt.margin },
      });
    }
    process.stdout.write(`wrote: ${output}\n`);
  } finally {
    await browser.close().catch(() => {});
    for (const f of tmpFiles) fs.rmSync(f, { force: true });
  }
})().catch((e) => die(e.stack || String(e)));

// -- Markdown document shell (plain, print-friendly) --------------------------

function mdShell({ body, baseHref, mermaidHref, title }) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<base href="${baseHref}">
<title>${escapeHtml(title)}</title>
<style>
:root{--fg:#1a1d24;--muted:#5b6472;--border:#dfe3ea;--code:#f4f5f8;--accent:#2563eb}
*{box-sizing:border-box}
body{font-family:-apple-system,"Segoe UI","Noto Sans Thai",system-ui,sans-serif;color:var(--fg);line-height:1.6;max-width:780px;margin:0 auto;padding:8px 24px;font-size:15px}
h1,h2,h3,h4{line-height:1.25;margin:1.5em 0 .5em;break-after:avoid}
h1{font-size:1.85rem;border-bottom:2px solid var(--border);padding-bottom:.3em}
h2{font-size:1.4rem;margin-top:1.8em}
h3{font-size:1.15rem}
p,li{font-size:1rem}
a{color:var(--accent);word-break:break-word}
em{color:var(--muted)}
code{background:var(--code);padding:.15em .4em;border-radius:4px;font-family:ui-monospace,Menlo,monospace;font-size:.88em}
pre{background:var(--code);padding:14px 16px;border-radius:8px;overflow:auto;break-inside:avoid}
pre code{background:none;padding:0}
pre.mermaid{background:none;display:flex;justify-content:center;break-inside:avoid}
img{max-width:100%;height:auto}
figure{break-inside:avoid;margin:1em 0}
table{border-collapse:collapse;width:100%;margin:1em 0;break-inside:avoid;font-size:.95rem}
th,td{border:1px solid var(--border);padding:8px 12px;text-align:left}
th{background:var(--code)}
blockquote{border-left:3px solid var(--accent);margin:1em 0;padding:.4em 1em;color:var(--muted);background:var(--code);border-radius:0 6px 6px 0;break-inside:avoid}
hr{border:none;border-top:1px solid var(--border);margin:2em 0}
</style>
<style id="wid-print">@media print{pre,figure,table,blockquote,.mermaid{break-inside:avoid}img,.mermaid svg{max-width:100%!important;height:auto!important}body{background:#fff}}</style>
</head><body>
<article class="md">${body}</article>
<script src="${mermaidHref}"></script>
<script>try{mermaid.initialize({startOnLoad:true,theme:"default"})}catch(e){}</script>
</body></html>`;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );
}

// --expand: reveal content the page keeps collapsed, so one screenshot carries the whole
// report instead of whichever tab happened to be open. Covers the idioms that actually
// occur in tool-generated reports:
//   .tabs .tab / .tab-pane / [role=tabpanel]  — a tabbed report (k6-reporter, mochawesome)
//   [hidden] on a panel                        — the same thing, done with the attribute
// <details> is opened imperatively (a DOM property, not styling). Deliberately narrow:
// a blanket `display:block !important` would also unfold menus, modals and tooltips and
// produce a longer, worse picture than the one it replaced.
const EXPAND_CSS = `
  .tabs > .tab, .tab-pane, [role="tabpanel"] { display: block !important; }
  .tab-pane[hidden], [role="tabpanel"][hidden] { display: block !important; }
  .tabs > .tab { border-radius: 0 !important; }
`;
