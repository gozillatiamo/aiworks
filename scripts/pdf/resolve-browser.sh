#!/usr/bin/env bash
# scripts/pdf/resolve-browser.sh — shared headless-browser plumbing for this adapter.
#
# Sourced, never executed:
#
#   source "<…>/scripts/pdf/resolve-browser.sh"
#   pdf_ensure_node_deps        # installs puppeteer-core + marked once, into scripts/pdf/node_modules
#   pdf_resolve_browser         # exports CHROME_PATH, fetching Chrome for Testing if nothing local
#
# Both `render.sh` (doc → PDF/PNG) and `capture-url.sh` (live URL → PNG) go through here, so the
# browser is resolved and cached ONCE for the adapter — a box that has already rendered a PDF
# captures a URL with no second download.
#
# Resolution order, so the same call works on a mac dev box and a headless cloud host:
#   CHROME_PATH  >  system Chrome/Chromium  >  a Chrome-for-Testing auto-fetched into .cache/
#
# The auto-fetch supplies only the browser BINARY. OS shared libraries and a Thai font (policy
# `th`) must come from the image — see README.md → Cloud / Docker.

PDF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDF_CACHE="$PDF_DIR/.cache"
CFT_VERSION="${CFT_VERSION:-stable}"   # pin a concrete version here for full reproducibility

pdf_die() { echo "error: $*" >&2; exit 1; }

# Install the adapter's node deps once. puppeteer-core carries no browser download of its own.
pdf_ensure_node_deps() {
  command -v node >/dev/null || pdf_die "node is required"
  [[ -d "$PDF_DIR/node_modules/puppeteer-core" && -d "$PDF_DIR/node_modules/marked" ]] && return 0
  command -v npm >/dev/null || pdf_die "npm is required (to install puppeteer-core + marked)"
  echo "[pdf] installing node deps…" >&2
  ( cd "$PDF_DIR" && npm install --no-audit --no-fund --loglevel=error )
}

_pdf_find_browser() {
  local c
  for c in "${CHROME_PATH:-}" \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    /usr/bin/google-chrome /usr/bin/google-chrome-stable \
    /usr/bin/chromium /usr/bin/chromium-browser; do
    [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  if [[ -f "$PDF_CACHE/.chrome-path" ]]; then
    c="$(cat "$PDF_CACHE/.chrome-path")"
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  fi
  return 1
}

# Export CHROME_PATH, fetching Chrome for Testing into .cache/ when the box has no browser.
pdf_resolve_browser() {
  local chrome_bin out
  if ! chrome_bin="$(_pdf_find_browser)"; then
    command -v npx >/dev/null \
      || pdf_die "no browser found and npx unavailable — set CHROME_PATH or apt install chromium (see README Cloud/Docker)"
    echo "[pdf] no system browser — fetching Chrome for Testing ($CFT_VERSION) into .cache/…" >&2
    mkdir -p "$PDF_CACHE"
    # `install` prints "<buildId> <executable-path>"; the path may contain spaces (mac CfT .app).
    out="$(cd "$PDF_DIR" && npx --yes @puppeteer/browsers install "chrome@${CFT_VERSION}" --path "$PDF_CACHE" 2>/dev/null | tail -n1)"
    chrome_bin="$(printf '%s' "$out" | sed 's/^[^ ]* //')"
    [[ -n "$chrome_bin" && -x "$chrome_bin" ]] \
      || pdf_die "Chrome-for-Testing auto-fetch failed (got: '$out'). Install a browser and set CHROME_PATH, or apt install chromium (see README Cloud/Docker)."
    printf '%s' "$chrome_bin" > "$PDF_CACHE/.chrome-path"
  fi
  export CHROME_PATH="$chrome_bin"
}
