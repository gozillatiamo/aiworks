#!/usr/bin/env node
/*
 * verify-doc.mjs — the authoritative check for a generated interactive doc.
 *
 * Renders EVERY diagram with REAL Mermaid (the same lib the doc loads) and then
 * runs the bundled diagram-interactions engine against that real SVG, so it
 * catches the failure classes a plain DOM test cannot:
 *   1. a diagram's source is invalid Mermaid (won't render in a browser);
 *   2. the exported island `source` drifted from the visible diagram;
 *   3. a declared interactive node never matches a real SVG node (clicks /
 *      walkthrough silently do nothing — the "doesn't respond" bug);
 *   4. the page no longer exports valid JSON.
 *
 * Usage:
 *   npm i --no-save mermaid jsdom        # once, in the dir you run this from
 *   node <skill>/scripts/verify-doc.mjs path/to/your-doc.html
 *
 * Exit code 0 = all good, 1 = a check failed, 2 = deps missing.
 */
import fs from "fs";
import { createRequire } from "module";
import { pathToFileURL } from "url";

const docPath = process.argv[2];
if (!docPath) { console.error("usage: node verify-doc.mjs <doc.html>"); process.exit(2); }

const cwdReq = createRequire(pathToFileURL(process.cwd() + "/_.js"));
const selfReq = createRequire(import.meta.url);

/* 1) jsdom (CJS) — load BEFORE mermaid so the browser globals exist first */
let jsdomMod = null;
for (const r of [cwdReq, selfReq]) { try { jsdomMod = r("jsdom"); break; } catch (_) {} }
if (!jsdomMod) { console.error("Missing deps. Run:  npm i --no-save mermaid jsdom   then re-run from that dir."); process.exit(2); }
const { JSDOM, VirtualConsole } = jsdomMod;

/* 2) browser shims so Mermaid can render under node — MUST be set up before importing mermaid */
const boot = new JSDOM("<!DOCTYPE html><body></body>", { pretendToBeVisual: true });
global.window = boot.window; global.document = boot.window.document;
try { Object.defineProperty(global, "navigator", { value: boot.window.navigator, configurable: true }); } catch (_) {}
const sp = boot.window.SVGElement.prototype;
sp.getBBox = () => ({ x: 0, y: 0, width: 80, height: 30 });
sp.getComputedTextLength = function () { return (this.textContent || "").length * 8; };
sp.getPointAtLength = () => ({ x: 0, y: 0 });
global.CSSStyleSheet = boot.window.CSSStyleSheet || class { replaceSync() {} insertRule() {} };
for (const k of ["DOMParser", "XMLSerializer", "Node", "Element", "SVGElement", "getComputedStyle"])
  if (!global[k] && boot.window[k]) { try { global[k] = boot.window[k]; } catch (_) {} }
global.requestAnimationFrame = global.requestAnimationFrame || ((f) => setTimeout(f, 0));

/* 3) mermaid (ESM) — resolve from cwd or self, with a direct path fallback */
function resolveMermaid() {
  for (const r of [cwdReq, selfReq]) for (const n of ["mermaid", "mermaid/dist/mermaid.core.mjs"]) { try { return r.resolve(n); } catch (_) {} }
  const p = process.cwd() + "/node_modules/mermaid/dist/mermaid.core.mjs";
  return fs.existsSync(p) ? p : null;
}
const mmPath = resolveMermaid();
if (!mmPath) { console.error("Missing deps. Run:  npm i --no-save mermaid jsdom   then re-run from that dir."); process.exit(2); }
const mermaid = (await import(pathToFileURL(mmPath))).default;
mermaid.initialize({ startOnLoad: false, securityLevel: "loose" });

/* the bundled engine, next to this script */
const engine = fs.readFileSync(new URL("../assets/diagram-interactions.js", import.meta.url), "utf8");

let fails = 0;
const ok = (c, m) => { console.log((c ? "  ✓ " : "  ✗ FAIL ") + m); if (!c) fails++; };

const PD = new JSDOM(fs.readFileSync(docPath, "utf8")).window.document;
const figures = [...PD.querySelectorAll("figure.diagram, .wid-diagram, [data-block='diagram']")];
console.log(`\nVerifying ${docPath}\nDiagrams: ${figures.length}\n`);

const rendered = [];
for (let i = 0; i < figures.length; i++) {
  const fig = figures[i];
  const pre = fig.querySelector("pre.mermaid, .mermaid");
  const visible = (pre ? pre.textContent : "").trim();
  const isl = fig.querySelector("script.export-data");
  const island = isl ? JSON.parse(isl.textContent) : {};
  const title = island.title || `diagram ${i}`;
  let svg = null;
  try { svg = (await mermaid.render("v" + i, visible)).svg; ok(true, `${title}: renders`); }
  catch (e) { ok(false, `${title}: renders — ${e.message.split("\n")[0]}`); }
  try { await mermaid.render("s" + i, island.source || ""); ok(true, `${title}: exported source is valid Mermaid`); }
  catch (e) { ok(false, `${title}: exported source INVALID — ${e.message.split("\n")[0]}`); }
  ok(visible === (island.source || "").trim(), `${title}: visible source matches exported source (no drift)`);
  if (svg) rendered.push({ i, svg, island, title });
}

/* run the engine on the real SVGs; every declared node must wire */
const anchors = [...PD.querySelectorAll("[data-section-id]")].map((s) => `<section data-section-id="${s.getAttribute("data-section-id")}"></section>`).join("");
const figHtml = rendered.map((r) =>
  `<figure id="f${r.i}" class="diagram" data-block="diagram"><div class="mermaid">${r.svg}</div>`
  + `<script type="application/json" class="export-data">${JSON.stringify(r.island)}<\/script></figure>`).join("");
const win = new JSDOM(`<!DOCTYPE html><html><body><main data-doc>${anchors}${figHtml}</main></body></html>`, { runScripts: "outside-only" }).window;
global.window = win; global.document = win.document;
win.eval(engine);
await new Promise((r) => setTimeout(r, 400));
ok(typeof win.widGo === "function", "diagram engine initialises on real Mermaid output");
for (const r of rendered) {
  const fig = win.document.getElementById("f" + r.i);
  const declared = Object.keys(r.island.nodes || {});
  if (!declared.length) continue;
  const wired = fig.querySelectorAll("g.node.wid-act").length;
  ok(wired === declared.length, `${r.title}: ${wired}/${declared.length} interactive nodes resolve to real SVG nodes`);
  const next = fig.querySelector('.wid-dgm-walk button[title^="Next"]');
  if (next) { next.click(); ok(fig.querySelectorAll("g.node.wid-hot, g.node.wid-sel").length >= 1, `${r.title}: walkthrough highlights a node`); }
}

/* whole-page JSON export must be valid (run export-engine via the real doc) */
try {
  const stripped = fs.readFileSync(docPath, "utf8")
    .replace(/<script src="https:\/\/cdn[^>]*><\/script>/g, "")
    .replace(/mermaid\.initialize\([\s\S]*?\}\);/, "");
  const w2 = new JSDOM(stripped, { runScripts: "dangerously", virtualConsole: new VirtualConsole() }).window;
  await new Promise((r) => setTimeout(r, 300));
  ok(w2.WID && !!JSON.parse(JSON.stringify(w2.WID.pageModel())), "page exports valid JSON");
} catch (e) { ok(false, "page exports valid JSON — " + e.message.split("\n")[0]); }

/* REAL-BROWSER gate — the only check that catches bugs jsdom + synthetic events can't:
 *   • load-order/timing (CDN Mermaid async render + subtree replacement → 0 wired), and
 *   • REAL-click failures (e.g. pointer-capture swallowing the click) where nodes carry
 *     the wid-act class yet a genuine mouse click never fires the handler.
 * Best tier: puppeteer-core drives a real mouse click and asserts the response. Fallback:
 * the Chrome binary + --dump-dom confirms wiring only. Skipped with a note if neither. */
const url = "file://" + (docPath.startsWith("/") ? docPath : process.cwd() + "/" + docPath);
const declaredTotal = rendered.reduce((n, r) => n + Object.keys(r.island.nodes || {}).length, 0);
function findChrome() {
  const c = [process.env.CHROME_PATH,
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser"].filter(Boolean);
  return c.find((p) => { try { return fs.existsSync(p); } catch (_) { return false; } });
}
let puppeteer = null;
for (const r of [cwdReq, selfReq]) { try { puppeteer = r("puppeteer-core"); break; } catch (_) {} }
const chrome = findChrome();

if (declaredTotal === 0) {
  console.log("  · real-browser check skipped (no interactive nodes declared)");
} else if (puppeteer && chrome) {
  // GOLD: real mouse click. Find a detail node and a zoom button; click for real; assert.
  let detailKey = null;
  for (const r of rendered) for (const k of Object.keys(r.island.nodes || {})) if (r.island.nodes[k].detail && !r.island.nodes[k].section && !r.island.nodes[k].url) { detailKey = k; break; }
  let browser;
  try {
    browser = await puppeteer.launch({ executablePath: chrome, headless: "new", args: ["--no-sandbox", "--window-size=1440,1100"] });
    const page = await browser.newPage();
    await page.setViewport({ width: 1440, height: 1100 });
    await page.goto(url, { waitUntil: "networkidle0", timeout: 30000 });
    await page.waitForFunction((n) => document.querySelectorAll("g.node.wid-act").length >= n, { timeout: 15000 }, declaredTotal);
    const wired = await page.evaluate(() => document.querySelectorAll("g.node.wid-act").length);
    ok(wired >= declaredTotal, `real browser: ${wired}/${declaredTotal} interactive nodes wired on natural load`);
    // a real mouse click on a detail node must open the drawer
    let clickWorks = "no detail node to test";
    if (detailKey) {
      const re = new RegExp("-" + detailKey.replace(/[^A-Za-z0-9_]/g, "") + "-");
      const h = await page.evaluateHandle((rs) => {
        const rx = new RegExp(rs);
        return [...document.querySelectorAll("g.node.wid-act")].find((g) => rx.test(g.id)) || null;
      }, re.source);
      const el = h.asElement && h.asElement();
      if (el) { try { await el.click(); } catch (_) {} await new Promise((r) => setTimeout(r, 150)); }
      clickWorks = await page.evaluate(() => !!document.querySelector(".wid-dgm-panel.is-open"));
      ok(clickWorks === true, `real browser: a genuine mouse click on a node fires its action (not swallowed)`);
    }
  } catch (e) { ok(false, "real-browser click test errored — " + String(e.message || e).split("\n")[0]); }
  finally { if (browser) try { await browser.close(); } catch (_) {} }
} else if (chrome) {
  try {
    const { execFileSync } = await import("node:child_process");
    const dom = execFileSync(chrome, ["--headless=new", "--disable-gpu", "--no-sandbox", "--virtual-time-budget=15000", "--dump-dom", url], { maxBuffer: 64 * 1024 * 1024, timeout: 45000 }).toString();
    const wired = (dom.match(/class="node[^"]*\bwid-act\b/g) || []).length;
    ok(wired === declaredTotal, `real browser (wiring only): ${wired}/${declaredTotal} nodes wired — install puppeteer-core to also test real clicks`);
  } catch (e) { console.log("  · real-browser check errored (skipped): " + String(e.message || e).split("\n")[0]); }
} else {
  console.log("  · real-browser check SKIPPED (no Chrome/Chromium; set CHROME_PATH, and `npm i --no-save puppeteer-core` for the real-click test)");
}

console.log("\n" + (fails === 0 ? "ALL PASS ✅" : fails + " FAILURE(S) ✗"));
process.exit(fails ? 1 : 0);
