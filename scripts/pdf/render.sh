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
CACHE="$DIR/.cache"
CFT_VERSION="${CFT_VERSION:-stable}"   # pin a concrete version here for full reproducibility

die() { echo "error: $*" >&2; exit 1; }
command -v node >/dev/null || die "node is required"

# 1. node deps (puppeteer-core, marked) — install once. puppeteer-core has no browser download.
if [[ ! -d "$DIR/node_modules/puppeteer-core" || ! -d "$DIR/node_modules/marked" ]]; then
  command -v npm >/dev/null || die "npm is required (to install puppeteer-core + marked)"
  echo "[pdf] installing node deps…" >&2
  ( cd "$DIR" && npm install --no-audit --no-fund --loglevel=error )
fi

# 2. browser resolution.
resolve_browser() {
  local c
  for c in "${CHROME_PATH:-}" \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    /usr/bin/google-chrome /usr/bin/google-chrome-stable \
    /usr/bin/chromium /usr/bin/chromium-browser; do
    [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  if [[ -f "$CACHE/.chrome-path" ]]; then
    c="$(cat "$CACHE/.chrome-path")"
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  fi
  return 1
}

if ! CHROME_BIN="$(resolve_browser)"; then
  command -v npx >/dev/null || die "no browser found and npx unavailable — set CHROME_PATH or apt install chromium (see README Cloud/Docker)"
  echo "[pdf] no system browser — fetching Chrome for Testing ($CFT_VERSION) into .cache/…" >&2
  mkdir -p "$CACHE"
  # `install` prints "<buildId> <executable-path>"; the path may contain spaces (mac CfT .app).
  out="$(cd "$DIR" && npx --yes @puppeteer/browsers install "chrome@${CFT_VERSION}" --path "$CACHE" 2>/dev/null | tail -n1)"
  CHROME_BIN="$(printf '%s' "$out" | sed 's/^[^ ]* //')"
  [[ -n "$CHROME_BIN" && -x "$CHROME_BIN" ]] \
    || die "Chrome-for-Testing auto-fetch failed (got: '$out'). Install a browser and set CHROME_PATH, or apt install chromium (see README Cloud/Docker)."
  printf '%s' "$CHROME_BIN" > "$CACHE/.chrome-path"
fi

export CHROME_PATH="$CHROME_BIN"
exec node "$DIR/pdf.mjs" "$@"
