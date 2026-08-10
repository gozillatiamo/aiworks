#!/usr/bin/env bash
# scripts/pdf/render.sh — render an HTML or Markdown doc (image + Mermaid diagram
# illustrations) to a PDF, or to a full-page PNG screenshot, via headless Chrome.
#
#   ./render.sh <input.html|.md> <output.pdf> [--format A4|Letter] [--timeout ms] [--margin 14mm]
#   ./render.sh <input.html|.md> <output.png> --png [--width 1280] [--expand] [--timeout ms]
#
# The PDF is a clean re-typeset document; --png is a screenshot of the page as it renders
# (for results that ARE a rendered page — a k6 run report, a coverage summary); add --expand
# to reveal collapsed tabs first, or the shot carries only the open one. See pdf.mjs.
#
# Resolves a Chromium-family browser in this order, so it runs on a mac dev box AND a
# headless cloud host with no code change:
#   CHROME_PATH  >  system Chrome/Chromium  >  a Chrome-for-Testing auto-fetched into .cache/
#
# Mermaid is served from vendor/mermaid.min.js (NOT a CDN), so diagrams render offline / on a
# locked-egress host. On cloud the auto-fetch supplies only the browser BINARY — the OS shared
# libraries and a Thai font (policy `th`) must come from the image; see README.md → Cloud / Docker.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# node deps + browser resolution live in resolve-browser.sh, shared with capture-url.sh.
# shellcheck source=resolve-browser.sh
source "$DIR/resolve-browser.sh"
pdf_ensure_node_deps
pdf_resolve_browser

exec node "$DIR/pdf.mjs" "$@"
