# PDF adapter — HTML/Markdown → PDF (image + Mermaid illustrations)

Render an HTML or Markdown document to a PDF, with diagram illustrations from **either**
an image source (`<img>` / `![](…)`) **or** Mermaid source (` ```mermaid ` /
`<pre class="mermaid">`). Built to turn a `write-interactive-docs` HTML export — or any
Markdown/HTML an agent authors — into a shareable PDF (e.g. for slack-dispatch to reply
with a file).

```bash
scripts/pdf/render.sh <input.html|.md> <output.pdf> [--format A4|Letter] [--timeout 20000] [--margin 14mm]
```

Examples:

```bash
scripts/pdf/render.sh report.md            report.pdf
scripts/pdf/render.sh interactive-doc.html doc.pdf --format A4
```

## How it works

- **Engine** — headless Chrome (Chrome-for-Testing / any Chromium-family binary) driven by
  `puppeteer-core`. Chrome runs JS, so it renders `<img>` **and** client-rendered Mermaid
  natively. `pdf.mjs` waits for every `.mermaid` block to produce an `<svg>`, then prints.
- **`.html`** is rendered as-is. Interactive chrome (toolbars, zoom/pan, export buttons, the
  language chip) is hidden by the doc's own `@media print` block — the
  `write-interactive-docs` template ships one under `<style id="wid-print">`; for a doc that
  lacks it, `pdf.mjs` injects an equivalent fallback.
- **`.md`** is converted with `marked`; ` ```mermaid ` fences become `<pre class="mermaid">`
  and the result is wrapped in a small HTML shell that loads the vendored Mermaid. Relative
  image paths (`![](./shot.png)`) resolve against the Markdown file's directory.
- **Offline** — Mermaid is served from `vendor/mermaid.min.js`, not a CDN. The doc's own
  `cdn.jsdelivr.net/npm/mermaid@…` request is intercepted and answered from that file, so
  diagrams render with no network. (Google Fonts, if a doc uses them, stay best-effort and
  fall back to system fonts.)
- **Best-effort** — a diagram that fails to render within `--timeout` (CDN unrelated: bad
  Mermaid syntax, etc.) is left partial and the PDF is **still written**. The command fails
  only on a hard error (bad args, no input, no browser).

## Browser resolution

`render.sh` resolves a browser in this order — works on a mac dev box and a headless cloud
host with no code change:

1. `CHROME_PATH` (if set and executable)
2. system Chrome/Chromium (`/Applications/Google Chrome.app`, `/Applications/Chromium.app`,
   `/usr/bin/google-chrome`, `/usr/bin/chromium`, …)
3. a **Chrome-for-Testing** auto-fetched into `.cache/` via `@puppeteer/browsers` (path
   remembered in `.cache/.chrome-path`)

Pin a concrete CfT version with `CFT_VERSION=<version> scripts/pdf/render.sh …` (default:
`stable`).

## Cloud / Docker

The auto-fetch supplies only the browser **binary**. A headless Linux host also needs OS
shared libraries and — because the workspace output language can be `th` — a **Thai font**,
or Thai text prints as tofu (▯▯▯).

```dockerfile
# Debian/Ubuntu base
RUN apt-get update && apt-get install -y --no-install-recommends \
      chromium \
      libnss3 libatk-bridge2.0-0 libatk1.0-0 libcups2 libgbm1 libasound2 \
      libpangocairo-1.0-0 libxdamage1 libxrandr2 libxcomposite1 libxfixes3 \
      fonts-liberation fonts-noto-color-emoji fonts-thai-tlwg \
 && rm -rf /var/lib/apt/lists/*
ENV CHROME_PATH=/usr/bin/chromium
```

With `chromium` installed and `CHROME_PATH` set, the auto-fetch step is skipped entirely.
If you rely on the auto-fetched CfT instead of the apt `chromium`, install the same
`lib*`/`fonts-*` packages anyway — the download does not bundle them.

## Files

| File | Role |
| --- | --- |
| `render.sh` | entry — resolves/provisions the browser, ensures deps, runs `pdf.mjs` |
| `pdf.mjs` | puppeteer-core: load → intercept Mermaid CDN → wait for render → print |
| `vendor/mermaid.min.js` | vendored Mermaid (no CDN); see `vendor/README.md` |
| `package.json` | `puppeteer-core`, `marked` (installed into `.gitignore`d `node_modules/`) |

## Notes

- Deps and the browser cache are git-ignored (`node_modules/`, `.cache/`).
- The canonical print stylesheet lives in the `write-interactive-docs` template
  (`assets/template.html`, `<style id="wid-print">`); `pdf.mjs` carries a matching fallback
  for docs that predate it or come from elsewhere. Keep the two in sync when the template's
  interactive `wid-` control classes change.
