#!/usr/bin/env node
//
// capture-url.mjs — screenshot a LIVE remote URL to PNG via headless Chrome.
//
// Sibling of pdf.mjs, and deliberately not part of it: pdf.mjs renders a local document
// (`pathToFileURL(input)`) into a clean typeset artifact, while this captures a third-party page
// exactly as it renders. Same browser, same resolution logic (resolve-browser.sh), opposite intent.
//
// Invoke through capture-url.sh, which resolves/provisions the browser and exports CHROME_PATH.
//
// The URL arrives on STDIN, never in argv, because the pages this exists for carry a
// single-use token in their query string — argv is world-readable through `ps`.
//
//   echo "$url" | node capture-url.mjs out.png [--width 1280] [--height 800]
//                                              [--wait-ms 3000] [--timeout 30000] [--full-page]
//
// Why a settle delay and not just `networkidle2`: a canvas- or chart-drawn page finishes rendering
// after its last request completes. Without the extra wait the shot is a blank stage.

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const puppeteer = require("puppeteer-core");

const CHROME = process.env.CHROME_PATH;
const die = (m) => { console.error(`error: ${m}`); process.exit(1); };
if (!CHROME) die("CHROME_PATH is not set — run through capture-url.sh");

const opt = { out: null, width: 1280, height: 800, waitMs: 3000, timeout: 30000, fullPage: false };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  const num = (name) => {
    const v = Number(argv[++i]);
    if (!Number.isFinite(v) || v < 0) die(`${name} needs a non-negative number`);
    return v;
  };
  switch (a) {
    case "--width":     opt.width  = num("--width"); break;
    case "--height":    opt.height = num("--height"); break;
    case "--wait-ms":   opt.waitMs = num("--wait-ms"); break;
    case "--timeout":   opt.timeout = num("--timeout"); break;
    case "--full-page": opt.fullPage = true; break;
    default:
      if (a.startsWith("--")) die(`unknown option: ${a}`);
      if (opt.out) die("only one output path is accepted");
      opt.out = a;
  }
}
if (!opt.out) die("an output .png path is required");
if (!opt.out.endsWith(".png")) die("output must be a .png path");

const readStdin = async () => {
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  return Buffer.concat(chunks).toString("utf8").trim();
};

const url = await readStdin();
if (!url) die("no URL on stdin");
if (!/^https?:\/\//.test(url)) die("stdin must carry an http(s) URL");

// Everything logged from here on is redacted: a query string is where the token lives.
const safeUrl = url.replace(/\?.*$/, "?<query redacted>");

const dir = path.dirname(path.resolve(opt.out));
fs.mkdirSync(dir, { recursive: true });

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: true,
  args: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--hide-scrollbars"],
});
try {
  const page = await browser.newPage();
  await page.setViewport({ width: opt.width, height: opt.height, deviceScaleFactor: 2 });
  console.error(`[capture] ${safeUrl}`);
  const res = await page
    .goto(url, { waitUntil: "networkidle2", timeout: opt.timeout })
    .catch((e) => { console.error(`[capture] load: ${e.message}`); return null; });
  // A dead round token answers 200 with an error page, so status alone proves nothing — the
  // screenshot is the evidence either way. Report the status and keep going.
  if (res) console.error(`[capture] http ${res.status()}`);
  if (opt.waitMs) await new Promise((r) => setTimeout(r, opt.waitMs));
  await page.screenshot({ path: opt.out, fullPage: opt.fullPage, type: "png" });
  const kb = (fs.statSync(opt.out).size / 1024).toFixed(1);
  console.error(`[capture] wrote ${opt.out} (${kb} KB, ${opt.width}x${opt.height}${opt.fullPage ? ", full page" : ""})`);
} finally {
  await browser.close();
}
